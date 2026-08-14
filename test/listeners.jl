using PipeWire
using Test

struct ListenerInfoCounter
    count::Base.RefValue{Int}
end

(callback::ListenerInfoCounter)(::CoreConnection, ::CoreInfo) =
    (callback.count[] += 1; nothing)

struct ListenerGlobalCounter
    count::Base.RefValue{Int}
end

(callback::ListenerGlobalCounter)(::Registry, ::Global) =
    (callback.count[] += 1; nothing)

function invoke_listener_ping(listener::T) where {T<:ManagedListener}
    ccall(
        getfield(listener, :events)[].ping,
        Cvoid,
        (Ref{T}, UInt32, Cint),
        listener,
        UInt32(31),
        Cint(32),
    )
    return nothing
end

function listener_ping_allocations(listener)
    invoke_listener_ping(listener)
    return @allocated invoke_listener_ping(listener)
end

function invoke_listener_stream_process(listener::T) where {T<:ManagedListener}
    ccall(getfield(listener, :events)[].process, Cvoid, (Ref{T},), listener)
    return nothing
end

function listener_stream_allocations(listener)
    invoke_listener_stream_process(listener)
    return @allocated invoke_listener_stream_process(listener)
end

function invoke_listener_filter_process(listener::T) where {T<:ManagedListener}
    ccall(
        getfield(listener, :events)[].process,
        Cvoid,
        (Ref{T}, Ptr{PipeWire.LibPipeWire.spa_io_position}),
        listener,
        C_NULL,
    )
    return nothing
end

function listener_filter_allocations(listener)
    invoke_listener_filter_process(listener)
    return @allocated invoke_listener_filter_process(listener)
end

function invoke_listener_bound(listener::T, id::UInt32) where {T<:ManagedListener}
    ccall(
        getfield(listener, :events)[].bound,
        Cvoid,
        (Ref{T}, UInt32),
        listener,
        id,
    )
    return nothing
end

function invoke_listener_profile(listener::T, profile::Pod) where {T<:ManagedListener}
    GC.@preserve listener profile ccall(
        getfield(listener, :events)[].profile,
        Cvoid,
        (Ref{T}, Ptr{PipeWire.LibPipeWire.spa_pod}),
        listener,
        PipeWire._pod_pointer(profile),
    )
    return nothing
end

@testset "composable managed listeners" begin
    context = Context()
    enable_profiler!(context)
    primary_infos = Ref(0)
    core = CoreConnection(
        context;
        self=true,
        on_info=(core, info) -> (primary_infos[] += 1),
    )
    roundtrip(core)
    primary_infos[] = 0

    first_infos = Ref(0)
    second_infos = Ref(0)
    ping = Ref((UInt32(0), Cint(0)))
    first_listener = add_listener!(
        core;
        on_info=ListenerInfoCounter(first_infos),
        on_ping=PingRecorder(ping),
    )
    second_listener = add_listener!(core; on_info=ListenerInfoCounter(second_infos))
    @test isconcretetype(typeof(first_listener))
    @test all(isconcretetype, fieldtypes(typeof(first_listener)))
    @test isopen(first_listener)
    @test listener_ping_allocations(first_listener) == 0
    @test ping[] == (UInt32(31), Cint(32))

    hello!(core)
    roundtrip(core)
    @test primary_infos[] == 1
    @test first_infos[] == 1
    @test second_infos[] == 1

    close(first_listener)
    @test !isopen(first_listener)
    close(first_listener)
    hello!(core)
    roundtrip(core)
    @test primary_infos[] == 2
    @test first_infos[] == 1
    @test second_infos[] == 2

    registry_events = Ref(0)
    registry = Registry(core)
    registry_listener = add_listener!(
        registry;
        on_global_added=ListenerGlobalCounter(registry_events),
    )
    roundtrip(registry)
    @test registry_events[] > 0
    @test isconcretetype(typeof(registry_listener))
    @test all(isconcretetype, fieldtypes(typeof(registry_listener)))

    factory_global = first(
        global_object for global_object in globals(registry) if
        global_object.type == "PipeWire:Interface:Factory"
    )
    proxy = bind(registry, factory_global)
    bound = Ref(UInt32(0))
    proxy_listener = add_listener!(proxy; on_bound=(proxy, id) -> (bound[] = id))
    invoke_listener_bound(proxy_listener, factory_global.id)
    @test bound[] == factory_global.id
    close(proxy_listener)
    close(proxy)

    metadata_global = only(
        global_object for global_object in globals(registry) if
        global_object.type == "PipeWire:Interface:Metadata"
    )
    metadata = bind(registry, metadata_global, Metadata)
    properties = Tuple{UInt32,Union{Nothing,String},Union{Nothing,String},Union{Nothing,String}}[]
    metadata_listener = add_listener!(
        metadata;
        on_property=(metadata, subject, key, type, value) ->
            push!(properties, (subject, key, type, value)),
    )
    set_property!(
        metadata,
        0,
        "pipewire.jl.listener";
        type="Spa:String:JSON",
        value="true",
    )
    roundtrip(metadata)
    @test properties[end] ==
          (UInt32(0), "pipewire.jl.listener", "Spa:String:JSON", "true")
    close(metadata_listener)
    set_property!(metadata, 0, "pipewire.jl.listener")
    roundtrip(metadata)
    @test properties[end] ==
          (UInt32(0), "pipewire.jl.listener", "Spa:String:JSON", "true")
    close(metadata)

    profiler_global = only(
        global_object for global_object in globals(registry) if
        global_object.type == "PipeWire:Interface:Profiler"
    )
    profiler = bind(registry, profiler_global, Profiler)
    profiles = Pod[]
    profiler_listener = add_listener!(
        profiler;
        on_profile=(profiler, profile) -> push!(profiles, profile),
    )
    sample_profile = Pod(Int64(73))
    invoke_listener_profile(profiler_listener, sample_profile)
    @test pod_value(Int64, only(profiles)) == 73
    close(profiler_listener)
    close(profiler)

    stream_processes = Ref(0)
    stream_destroyed = Ref(0)
    stream = Stream(core, "listener stream")
    stream_listener = add_listener!(
        stream;
        on_process=CountProcess(stream_processes),
        on_destroyed=stream -> (stream_destroyed[] += 1),
    )
    @test listener_stream_allocations(stream_listener) == 0
    @test stream_processes[] == 2
    close(stream)
    @test stream_destroyed[] == 1
    @test !isopen(stream_listener)
    close(stream_listener)

    filter_processes = Ref(0)
    filter_destroyed = Ref(0)
    filter = Filter(core, "listener filter")
    filter_listener = add_listener!(
        filter;
        on_process=FilterProcessRecorder(filter_processes),
        on_destroyed=filter -> (filter_destroyed[] += 1),
    )
    @test listener_filter_allocations(filter_listener) == 0
    @test filter_processes[] == 4
    close(filter)
    @test filter_destroyed[] == 1
    @test !isopen(filter_listener)
    close(filter_listener)

    close(registry_listener)
    close(registry)
    close(second_listener)
    close(core)
    close(context)
end
