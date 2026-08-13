using PipeWire
using Test

struct CountProcess
    count::Base.RefValue{Int}
end

(callback::CountProcess)(::Stream) = (callback.count[] += 1)

function invoke_process_callback(stream)
    GC.@preserve stream PipeWire._stream_process(pointer_from_objref(stream))
    return nothing
end

function callback_allocations(stream)
    invoke_process_callback(stream)
    return @allocated invoke_process_callback(stream)
end

function dequeue_allocations(buffer, stream)
    dequeue_buffer!(buffer, stream)
    return @allocated dequeue_buffer!(buffer, stream)
end

@testset "Clang.jl-generated C bindings" begin
    raw_version = PipeWire.LibPipeWire.pw_get_library_version()
    @test raw_version != C_NULL
    @test VersionNumber(unsafe_string(raw_version)) == library_version()
    @test isbitstype(PipeWire.LibPipeWire.spa_hook)
    @test isbitstype(PipeWire.LibPipeWire.pw_core_events)
    @test isbitstype(PipeWire.LibPipeWire.pw_registry_events)
end

@testset "PipeWire" begin
    @test library_version() >= v"1.6"

    loop = MainLoop()
    @test isopen(loop)
    close(loop)
    @test !isopen(loop)
    close(loop)

    @test_throws InvalidStateException run!(loop)
    @test_throws InvalidStateException quit!(loop)

    result = with_main_loop() do scoped_loop
        @test isopen(scoped_loop)
        return :ok
    end
    @test result === :ok

    # Julia 1.10 and 1.11 cannot mark the blocking generated @ccall as GC-safe.
    if VERSION >= v"1.12" && Threads.nthreads() > 1
        threaded_loop = MainLoop()
        runner = Threads.@spawn run!(threaded_loop)
        started = () -> lock(getfield(threaded_loop, :state_lock)) do
            getfield(threaded_loop, :running)
        end
        @test Base.timedwait(started, 5) === :ok
        quit!(threaded_loop)
        @test fetch(runner) === nothing
        close(threaded_loop)
    end
end

@testset "managed core and registry" begin
    loop = MainLoop()
    context = Context(loop)
    @test isopen(context)
    @test main_loop(context) === loop
    @test_throws InvalidStateException close(loop)

    core_infos = CoreInfo[]
    done_events = Tuple{UInt32,Cint}[]
    core = CoreConnection(
        context;
        self=true,
        on_info=(core, info) -> push!(core_infos, info),
        on_done=(core, id, sequence) -> push!(done_events, (id, sequence)),
    )
    @test isopen(core)
    @test isconcretetype(typeof(core))
    @test all(isconcretetype, fieldtypes(typeof(core)))
    @test main_loop(core) === loop
    @test_throws InvalidStateException close(context)

    registry = Registry(core)
    @test isopen(registry)
    @test isconcretetype(typeof(registry))
    @test all(isconcretetype, fieldtypes(typeof(registry)))
    @test_throws InvalidStateException close(core)

    roundtrip(registry)
    @test length(core_infos) == 1
    @test core_infos[1].id == 0
    @test !isempty(core_infos[1].version)
    @test length(done_events) == 1
    first_snapshot = globals(registry)
    @test !isempty(first_snapshot)
    @test issorted(first_snapshot; by=global_object -> global_object.id)
    @test any(global_object -> global_object.type == "PipeWire:Interface:Core", first_snapshot)

    roundtrip(registry)
    second_snapshot = globals(registry)
    @test map(global_object -> global_object.id, second_snapshot) ==
          map(global_object -> global_object.id, first_snapshot)

    if !isempty(first_snapshot[1].properties)
        key = first(keys(first_snapshot[1].properties))
        first_snapshot[1].properties[key] = "changed only in the snapshot"
        @test globals(registry)[1].properties[key] != "changed only in the snapshot"
    end

    close(registry)
    @test !isopen(registry)
    close(core)
    @test !isopen(core)
    close(context)
    @test !isopen(context)
    close(loop)
    @test !isopen(loop)

    copied_globals = with_registry(self=true) do scoped_registry
        roundtrip(scoped_registry)
        globals(scoped_registry)
    end
    @test !isempty(copied_globals)
end

@testset "properties" begin
    properties = Properties(Dict("media.type" => "Audio", "node.name" => "julia-test"))
    @test isopen(properties)
    @test length(properties) == 2
    @test properties["media.type"] == "Audio"
    @test get(properties, "missing", "fallback") == "fallback"
    @test haskey(properties, "node.name")

    properties["application.name"] = "PipeWire.jl tests"
    delete!(properties, "media.type")
    @test Dict(properties) == Dict(
        "application.name" => "PipeWire.jl tests",
        "node.name" => "julia-test",
    )

    copied = copy(properties)
    empty!(properties)
    @test isempty(properties)
    @test length(copied) == 2
    close(properties)
    @test !isopen(properties)
    @test_throws InvalidStateException length(properties)
    close(copied)

    @test_throws ArgumentError Properties(Dict("bad\0key" => "value"))
end

@testset "managed proxy" begin
    context = Context()
    core = CoreConnection(context; self=true)
    registry = Registry(core)
    roundtrip(registry)
    factory = first(global_object for global_object in globals(registry) if
                    global_object.type == "PipeWire:Interface:Factory")
    bound = UInt32[]
    proxy = bind(registry, factory; on_bound=(proxy, id) -> push!(bound, id))

    @test isopen(proxy)
    @test isconcretetype(typeof(proxy))
    @test all(isconcretetype, fieldtypes(typeof(proxy)))
    @test interface_type(proxy) == factory.type
    @test proxy_id(proxy) != typemax(UInt32)
    @test_throws InvalidStateException close(registry)
    roundtrip(proxy)
    @test bound_id(proxy) == factory.id
    @test bound == [factory.id]

    close(proxy)
    @test !isopen(proxy)
    close(proxy)
    close(registry)
    close(core)
    close(context)
end

@testset "typed PipeWire objects" begin
    context = Context()
    core = CoreConnection(context; self=true)
    registry = Registry(core)
    roundtrip(registry)

    metadata_global = only(
        global_object for global_object in globals(registry) if
        global_object.type == "PipeWire:Interface:Metadata"
    )
    property_events = Tuple{
        UInt32,
        Union{Nothing,String},
        Union{Nothing,String},
        Union{Nothing,String},
    }[]
    metadata = bind(
        registry,
        metadata_global,
        Metadata;
        on_property=(metadata, subject, key, type, value) ->
            push!(property_events, (subject, key, type, value)),
    )

    @test isopen(metadata)
    @test isconcretetype(typeof(metadata))
    @test all(isconcretetype, fieldtypes(typeof(metadata)))
    @test interface_type(metadata) == metadata_global.type
    @test_throws InvalidStateException close(registry)

    roundtrip(metadata)
    initial_event_count = length(property_events)
    set_property!(
        metadata,
        0,
        "pipewire.jl.test";
        type="Spa:String:JSON",
        value="true",
    )
    roundtrip(metadata)
    @test length(property_events) == initial_event_count + 1
    @test property_events[end] ==
          (UInt32(0), "pipewire.jl.test", "Spa:String:JSON", "true")

    set_property!(metadata, 0, "pipewire.jl.test")
    roundtrip(metadata)
    @test property_events[end] == (UInt32(0), "pipewire.jl.test", nothing, nothing)
    @test_throws ArgumentError set_property!(metadata, 0, "bad\0key"; value="x")
    @test_throws ArgumentError bind(registry, metadata_global, Node)
    @test_throws ArgumentError destroy_object!(core, metadata)
    @test isopen(metadata)

    close(metadata)
    @test !isopen(metadata)

    created_properties = Properties(Dict("metadata.name" => "pipewire.jl.created"))
    created = create_object(core, "metadata", Metadata; properties=created_properties)
    @test isopen(created_properties)
    @test isconcretetype(typeof(created))
    @test all(isconcretetype, fieldtypes(typeof(created)))
    @test getfield(getfield(created, :proxy), :parent) === core
    @test_throws InvalidStateException close(core)
    roundtrip(registry)
    created_id = bound_id(created)
    @test any(global_object -> global_object.id == created_id, globals(registry))

    @test destroy_object!(core, created) === core
    @test !isopen(created)
    roundtrip(registry)
    @test !any(global_object -> global_object.id == created_id, globals(registry))
    close(created_properties)
    @test_throws ArgumentError create_object(core, "bad\0factory", Metadata)

    close(registry)
    close(core)
    close(context)

    node_error = "node failed"
    node_native = Ref(
        PipeWire.LibPipeWire.pw_node_info(
            UInt32(42),
            UInt32(8),
            UInt32(9),
            UInt64(31),
            UInt32(2),
            UInt32(3),
            PipeWire.LibPipeWire.PW_NODE_STATE_ERROR,
            pointer(node_error),
            C_NULL,
            C_NULL,
            UInt32(0),
        ),
    )
    info = GC.@preserve node_error node_native PipeWire._copy_node_info(
        Base.unsafe_convert(Ptr{PipeWire.LibPipeWire.pw_node_info}, node_native),
    )
    @test info.id == 42
    @test info.max_input_ports == 8
    @test info.max_output_ports == 9
    @test info.n_input_ports == 2
    @test info.n_output_ports == 3
    @test info.state == PipeWire.NODE_STATE_ERROR
    @test info.error == "node failed"
    @test isempty(info.properties)
    @test isempty(info.params)
end

@testset "managed stream" begin
    context = Context()
    connection_properties = Properties(Dict("application.name" => "PipeWire.jl tests"))
    core = CoreConnection(context; self=true, properties=connection_properties)
    @test isopen(connection_properties)

    stream_properties = Properties(Dict("media.type" => "Audio"))
    state_changes = Tuple{Int32,Int32,Union{Nothing,String}}[]
    process_count = Ref(0)
    stream = Stream(
        core,
        "julia-test";
        properties=stream_properties,
        on_state_changed=(stream, old, current, detail) ->
            push!(state_changes, (old, current, detail)),
        on_process=CountProcess(process_count),
    )
    @test isopen(stream_properties)
    @test isopen(stream)
    @test main_loop(stream) === main_loop(core)
    @test isconcretetype(typeof(stream))
    @test all(isconcretetype, fieldtypes(typeof(stream)))
    @test callback_allocations(stream) == 0
    @test process_count[] == 2
    @test stream_state(stream) == PipeWire.LibPipeWire.PW_STREAM_STATE_UNCONNECTED
    @test_throws InvalidStateException close(core)
    @test_throws ArgumentError connect!(
        stream,
        :output;
        flags=PipeWire.LibPipeWire.PW_STREAM_FLAG_RT_PROCESS,
    )
    @test_throws ArgumentError connect!(stream, :sideways)
    @test dequeue_buffer(stream) === nothing
    reusable_buffer = StreamBuffer()
    @test dequeue_allocations(reusable_buffer, stream) == 0
    @test reusable_buffer.handle == C_NULL

    format = audio_format()
    @test sizeof(format) == 168
    @test pod_type(format) == PipeWire.LibPipeWire.SPA_TYPE_Object
    @test_throws ArgumentError audio_format(channels=2, position=[Audio.MONO])
    connect!(stream, :output; params=[format])
    @test stream_state(stream) == PipeWire.LibPipeWire.PW_STREAM_STATE_CONNECTING
    @test state_changes == [
        (
            PipeWire.LibPipeWire.PW_STREAM_STATE_UNCONNECTED,
            PipeWire.LibPipeWire.PW_STREAM_STATE_CONNECTING,
            nothing,
        ),
    ]
    disconnect!(stream)

    storage = collect(UInt8(1):UInt8(16))
    chunk = Ref(PipeWire.LibPipeWire.spa_chunk(UInt32(2), UInt32(4), Int32(2), Int32(0)))
    native_data = Ref(
        PipeWire.LibPipeWire.spa_data(
            PipeWire.LibPipeWire.SPA_DATA_MemPtr,
            UInt32(0),
            Int64(-1),
            UInt32(0),
            UInt32(length(storage)),
            pointer(storage),
            Base.unsafe_convert(Ptr{PipeWire.LibPipeWire.spa_chunk}, chunk),
        ),
    )
    spa_buffer = Ref(
        PipeWire.LibPipeWire.spa_buffer(
            UInt32(0),
            UInt32(1),
            C_NULL,
            Base.unsafe_convert(Ptr{PipeWire.LibPipeWire.spa_data}, native_data),
        ),
    )
    native_buffer = Ref(
        PipeWire.LibPipeWire.pw_buffer(
            Base.unsafe_convert(Ptr{PipeWire.LibPipeWire.spa_buffer}, spa_buffer),
            C_NULL,
            UInt64(0),
            UInt64(0),
            UInt64(0),
        ),
    )
    GC.@preserve storage chunk native_data spa_buffer native_buffer begin
        borrowed = StreamBuffer(
            Base.unsafe_convert(Ptr{PipeWire.LibPipeWire.pw_buffer}, native_buffer),
        )
        data = buffer_data(borrowed)
        @test capacity(data) == 16
        @test data_pointer(data) == pointer(storage)
        @test bytes(data) == UInt8[3, 4, 5, 6]
        set_chunk!(data; offset=0, size=8, stride=4)
        @test length(bytes(data)) == 8
        @test writable_bytes(data) == storage
    end

    close(stream)
    @test !isopen(stream)
    close(stream)
    close(stream_properties)
    close(connection_properties)
    close(core)
    close(context)
end
