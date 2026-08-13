using PipeWire
using Test

struct CountProcess
    count::Base.RefValue{Int}
end

(callback::CountProcess)(::Stream) = (callback.count[] += 1)

struct PingRecorder
    value::Base.RefValue{Tuple{UInt32,Cint}}
end

(callback::PingRecorder)(::CoreConnection, id::UInt32, sequence::Cint) =
    (callback.value[] = (id, sequence); nothing)

struct IdRecorder
    value::Base.RefValue{UInt32}
end

(callback::IdRecorder)(::CoreConnection, id::UInt32) =
    (callback.value[] = id; nothing)

struct BoundIdRecorder
    value::Base.RefValue{Tuple{UInt32,UInt32}}
end

(callback::BoundIdRecorder)(::CoreConnection, id::UInt32, global_id::UInt32) =
    (callback.value[] = (id, global_id); nothing)

struct MemoryRecorder
    value::Base.RefValue{CoreMemory}
end

(callback::MemoryRecorder)(::CoreConnection, memory::CoreMemory) =
    (callback.value[] = memory; nothing)

struct BoundPropertiesRecorder
    value::Base.RefValue{Tuple{UInt32,UInt32,Dict{String,String}}}
end

function (callback::BoundPropertiesRecorder)(
    ::CoreConnection,
    id::UInt32,
    global_id::UInt32,
    properties::Dict{String,String},
)
    callback.value[] = (id, global_id, properties)
    return nothing
end

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

function invoke_core_scalar_callbacks(core)
    GC.@preserve core begin
        data = pointer_from_objref(core)
        PipeWire._core_ping(data, UInt32(11), Cint(12))
        PipeWire._core_remove_id(data, UInt32(13))
        PipeWire._core_bound_id(data, UInt32(14), UInt32(15))
        PipeWire._core_add_memory(
            data,
            UInt32(16),
            PipeWire.LibPipeWire.SPA_DATA_MemFd,
            Cint(17),
            UInt32(18),
        )
        PipeWire._core_remove_memory(data, UInt32(16))
    end
    return nothing
end

function core_scalar_callback_allocations(core)
    invoke_core_scalar_callbacks(core)
    return @allocated invoke_core_scalar_callbacks(core)
end

function pod_value_allocations(::Type{T}, pod) where {T}
    pod_value(T, pod)
    return @allocated pod_value(T, pod)
end

@testset "Clang.jl-generated C bindings" begin
    raw_version = PipeWire.LibPipeWire.pw_get_library_version()
    @test raw_version != C_NULL
    @test VersionNumber(unsafe_string(raw_version)) == library_version()
    @test isbitstype(PipeWire.LibPipeWire.spa_hook)
    @test isbitstype(PipeWire.LibPipeWire.pw_core_events)
    @test isbitstype(PipeWire.LibPipeWire.pw_registry_events)
end

@testset "core protocol" begin
    context = Context()
    ping_event = Ref((UInt32(0), Cint(0)))
    removed_id = Ref(UInt32(0))
    bound_event = Ref((UInt32(0), UInt32(0)))
    memory_event = Ref(CoreMemory(UInt32(0), UInt32(0), Cint(-1), UInt32(0)))
    removed_memory = Ref(UInt32(0))
    bound_properties = Ref((UInt32(0), UInt32(0), Dict{String,String}()))
    core_infos = CoreInfo[]
    done_events = Tuple{UInt32,Cint}[]
    core = CoreConnection(
        context;
        self=true,
        on_info=(core, info) -> push!(core_infos, info),
        on_done=(core, id, sequence) -> push!(done_events, (id, sequence)),
        on_ping=PingRecorder(ping_event),
        on_remove_id=IdRecorder(removed_id),
        on_bound_id=BoundIdRecorder(bound_event),
        on_add_memory=MemoryRecorder(memory_event),
        on_remove_memory=IdRecorder(removed_memory),
        on_bound_properties=BoundPropertiesRecorder(bound_properties),
    )

    @test isconcretetype(typeof(core))
    @test all(isconcretetype, fieldtypes(typeof(core)))
    @test isbitstype(CoreMemory)
    @test core_scalar_callback_allocations(core) == 0
    @test ping_event[] == (UInt32(11), Cint(12))
    @test removed_id[] == 13
    @test bound_event[] == (UInt32(14), UInt32(15))
    @test memory_event[] == CoreMemory(
        UInt32(16),
        PipeWire.LibPipeWire.SPA_DATA_MemFd,
        Cint(17),
        UInt32(18),
    )
    @test removed_memory[] == 16

    PipeWire._with_properties_dict(Dict("object.path" => "test.core.bound")) do dictionary
        GC.@preserve core PipeWire._core_bound_properties(
            pointer_from_objref(core),
            UInt32(19),
            UInt32(20),
            dictionary,
        )
    end
    @test bound_properties[] == (
        UInt32(19),
        UInt32(20),
        Dict("object.path" => "test.core.bound"),
    )

    initial_properties = core_properties(core)
    @test update_properties!(core, Dict("application.name" => "PipeWire.jl protocol test")) ===
          core
    updated_properties = core_properties(core)
    @test updated_properties["application.name"] == "PipeWire.jl protocol test"
    updated_properties["application.name"] = "snapshot only"
    @test core_properties(core)["application.name"] == "PipeWire.jl protocol test"
    @test initial_properties isa Dict{String,String}

    sequence = sync!(core, 41)
    @test sequence isa Cint
    roundtrip(core)
    @test any(event -> event == (UInt32(0), sequence), done_events)

    previous_info_count = length(core_infos)
    @test hello!(core) === core
    roundtrip(core)
    @test length(core_infos) > previous_info_count

    @test_throws ArgumentError sync!(core, -1; id=-1)
    @test_throws ArgumentError sync!(core, big(typemax(Cint)) + 1)
    @test_throws ArgumentError pong!(core, 0, big(typemax(Cint)) + 1)
    @test_throws ArgumentError report_error!(core, 0, 0, -1, "bad\0message")
    @test_throws ArgumentError hello!(core; version=5)

    close(core)
    close(context)
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
    @test_throws InvalidStateException hello!(core)

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

    factory_global = first(
        global_object for global_object in globals(registry) if
        global_object.type == "PipeWire:Interface:Factory"
    )
    module_global = first(
        global_object for global_object in globals(registry) if
        global_object.type == "PipeWire:Interface:Module"
    )
    client_global = only(
        global_object for global_object in globals(registry) if
        global_object.type == "PipeWire:Interface:Client"
    )
    factory_infos = FactoryInfo[]
    module_infos = ModuleInfo[]
    client_infos = ClientInfo[]
    permission_events = Tuple{UInt32,Vector{Permission}}[]
    factory = bind(
        registry,
        factory_global,
        Factory;
        on_info=(factory, info) -> push!(factory_infos, info),
    )
    module_object = bind(
        registry,
        module_global,
        PipeWireModule;
        on_info=(module_object, info) -> push!(module_infos, info),
    )
    client = bind(
        registry,
        client_global,
        Client;
        on_info=(client, info) -> push!(client_infos, info),
        on_permissions=(client, index, permissions) ->
            push!(permission_events, (index, permissions)),
    )
    @test all(isconcretetype, fieldtypes(typeof(factory)))
    @test all(isconcretetype, fieldtypes(typeof(module_object)))
    @test all(isconcretetype, fieldtypes(typeof(client)))
    roundtrip(registry)
    @test only(factory_infos).id == factory_global.id
    @test !isempty(only(factory_infos).name)
    @test only(module_infos).id == module_global.id
    @test !isempty(only(module_infos).name)
    @test only(client_infos).id == client_global.id
    get_permissions!(client)
    roundtrip(registry)
    @test !isempty(permission_events)
    @test first(permission_events)[1] == 0
    close(client)
    close(module_object)
    close(factory)

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

@testset "scalar SPA POD values" begin
    scalar_values = (
        (Nothing, nothing, PipeWire.LibPipeWire.SPA_TYPE_None),
        (Bool, true, PipeWire.LibPipeWire.SPA_TYPE_Bool),
        (Bool, false, PipeWire.LibPipeWire.SPA_TYPE_Bool),
        (SPA.Id, SPA.Id(17), PipeWire.LibPipeWire.SPA_TYPE_Id),
        (Int32, Int32(-123), PipeWire.LibPipeWire.SPA_TYPE_Int),
        (Int64, Int64(1) << 40, PipeWire.LibPipeWire.SPA_TYPE_Long),
        (Float32, 1.25f0, PipeWire.LibPipeWire.SPA_TYPE_Float),
        (Float64, -2.5, PipeWire.LibPipeWire.SPA_TYPE_Double),
        (String, "PipeWire ✓", PipeWire.LibPipeWire.SPA_TYPE_String),
        (SPA.Bytes, SPA.Bytes(UInt8[0x00, 0x7f, 0xff]), PipeWire.LibPipeWire.SPA_TYPE_Bytes),
        (SPA.Fd, SPA.Fd(-1), PipeWire.LibPipeWire.SPA_TYPE_Fd),
        (
            SPA.Rectangle,
            SPA.Rectangle(1_920, 1_080),
            PipeWire.LibPipeWire.SPA_TYPE_Rectangle,
        ),
        (
            SPA.Fraction,
            SPA.Fraction(30_000, 1_001),
            PipeWire.LibPipeWire.SPA_TYPE_Fraction,
        ),
    )

    for (value_type, value, wire_type) in scalar_values
        pod = Pod(value)
        @test pod_type(pod) == wire_type
        @test pod_value(value_type, pod) == value
        @test pod_value(pod) == value
    end

    for value_type in (SPA.Id, SPA.Fd, SPA.Bytes, SPA.Rectangle, SPA.Fraction)
        @test isconcretetype(value_type)
        @test all(isconcretetype, fieldtypes(value_type))
    end
    @test all(isbitstype, (SPA.Id, SPA.Fd, SPA.Rectangle, SPA.Fraction))

    bytes_source = UInt8[1, 2, 3]
    bytes_value = SPA.Bytes(bytes_source)
    bytes_source[1] = 9
    @test bytes_value == SPA.Bytes(UInt8[1, 2, 3])
    @test isequal(bytes_value, SPA.Bytes(UInt8[1, 2, 3]))
    @test hash(bytes_value) == hash(SPA.Bytes(UInt8[1, 2, 3]))

    int_pod = Pod(Int32(-7))
    rectangle_pod = Pod(SPA.Rectangle(640, 480))
    @test @inferred(pod_value(Int32, int_pod)) == -7
    @test @inferred(pod_value(SPA.Rectangle, rectangle_pod)) == SPA.Rectangle(640, 480)
    @test pod_value_allocations(Int32, int_pod) == 0
    @test pod_value_allocations(SPA.Rectangle, rectangle_pod) == 0

    @test_throws ArgumentError pod_value(Int32, Pod(true))
    @test_throws ArgumentError SPA.Id(-1)
    @test_throws ArgumentError SPA.Id(big(typemax(UInt32)) + 1)
    @test_throws ArgumentError SPA.Fd(big(typemax(Int64)) + 1)
    @test_throws ArgumentError SPA.Rectangle(-1, 1)
    @test_throws ArgumentError SPA.Fraction(1, -1)
    @test_throws ArgumentError Pod("embedded\0null")

    malformed_string = PipeWire._pod_from_body(
        UInt32(PipeWire.LibPipeWire.SPA_TYPE_String),
        UInt8[0x61],
    )
    embedded_null = PipeWire._pod_from_body(
        UInt32(PipeWire.LibPipeWire.SPA_TYPE_String),
        UInt8[0x61, 0x00, 0x62, 0x00],
    )
    malformed_bool = PipeWire._pod_from_body(
        UInt32(PipeWire.LibPipeWire.SPA_TYPE_Bool),
        UInt8[0x01],
    )
    @test_throws ArgumentError pod_value(String, malformed_string)
    @test_throws ArgumentError pod_value(String, embedded_null)
    @test_throws ArgumentError pod_value(Bool, malformed_bool)
    @test_throws ArgumentError pod_value(audio_format())
end

@testset "container SPA POD values" begin
    arrays = (
        SPA.Array(Bool[true, false, true]),
        SPA.Array(SPA.Id[SPA.Id(1), SPA.Id(7)]),
        SPA.Array(Int32[-1, 0, 1]),
        SPA.Array(Int64[-(Int64(1) << 40), Int64(1) << 40]),
        SPA.Array(Float32[-1.5, 2.25]),
        SPA.Array(Float64[-3.5, 4.75]),
        SPA.Array([SPA.Rectangle(640, 480), SPA.Rectangle(1_920, 1_080)]),
        SPA.Array([SPA.Fraction(24, 1), SPA.Fraction(30_000, 1_001)]),
        SPA.Array([SPA.Fd(-1), SPA.Fd(9)]),
        SPA.Array(Int32[]),
    )

    for array in arrays
        pod = Pod(array)
        @test pod_type(pod) == PipeWire.LibPipeWire.SPA_TYPE_Array
        @test pod_value(typeof(array), pod) == array
        @test pod_value(pod) == array
        @test isconcretetype(typeof(array))
        @test all(isconcretetype, fieldtypes(typeof(array)))
    end

    source = Int32[1, 2, 3]
    array = SPA.Array(source)
    source[1] = 9
    @test array.values == Int32[1, 2, 3]

    int_array_pod = Pod(SPA.Array(Int32[4, 5, 6]))
    @test @inferred(pod_value(SPA.Array{Int32}, int_array_pod)) ==
          SPA.Array(Int32[4, 5, 6])
    @test_throws ArgumentError pod_value(SPA.Array{Int64}, int_array_pod)
    @test_throws ArgumentError SPA.Array(Real[1, 2])
    @test_throws ArgumentError Pod(SPA.Array(["not", "fixed-size"]))

    children = [Pod(Int32(7)), Pod("hello"), Pod(SPA.Array(Int64[8, 9]))]
    value = SPA.Struct(children)
    children[1] = Pod(Int32(99))
    pod = Pod(value)
    @test pod_type(pod) == PipeWire.LibPipeWire.SPA_TYPE_Struct
    decoded = @inferred pod_value(SPA.Struct, pod)
    @test decoded == value
    @test pod_value(pod) == value
    @test isconcretetype(typeof(decoded))
    @test all(isconcretetype, fieldtypes(typeof(decoded)))
    @test pod_value(Int32, decoded.values[1]) == 7
    @test pod_value(String, decoded.values[2]) == "hello"
    @test pod_value(decoded.values[3]) == SPA.Array(Int64[8, 9])

    partial_array_body = UInt8[]
    PipeWire._append_bits!(partial_array_body, UInt32(sizeof(Int32)))
    PipeWire._append_bits!(partial_array_body, UInt32(PipeWire.LibPipeWire.SPA_TYPE_Int))
    append!(partial_array_body, UInt8[1, 2, 3])
    partial_array = PipeWire._pod_from_body(
        UInt32(PipeWire.LibPipeWire.SPA_TYPE_Array),
        partial_array_body,
    )
    missing_array_header = PipeWire._pod_from_body(
        UInt32(PipeWire.LibPipeWire.SPA_TYPE_Array),
        UInt8[],
    )
    @test_throws ArgumentError pod_value(SPA.Array{Int32}, partial_array)
    @test_throws ArgumentError pod_value(SPA.Array, missing_array_header)

    unpadded_struct = PipeWire._pod_from_body(
        UInt32(PipeWire.LibPipeWire.SPA_TYPE_Struct),
        Pod(Int32(1)).data,
    )
    partial_struct = PipeWire._pod_from_body(
        UInt32(PipeWire.LibPipeWire.SPA_TYPE_Struct),
        UInt8[0x01],
    )
    @test_throws ArgumentError pod_value(SPA.Struct, unpadded_struct)
    @test_throws ArgumentError pod_value(SPA.Struct, partial_struct)

    oversized_header = UInt8[]
    PipeWire._append_bits!(oversized_header, UInt32(1 << 20))
    PipeWire._append_bits!(oversized_header, UInt32(PipeWire.LibPipeWire.SPA_TYPE_Bytes))
    @test_throws ArgumentError Pod(oversized_header)
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
