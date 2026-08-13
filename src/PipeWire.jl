module PipeWire

export CoreConnection,
    CoreInfo,
    Context,
    Client,
    ClientInfo,
    Device,
    DeviceInfo,
    Direction,
    Factory,
    FactoryInfo,
    Global,
    Link,
    LinkInfo,
    LinkState,
    MainLoop,
    Metadata,
    ModuleInfo,
    Node,
    NodeInfo,
    NodeState,
    ParamInfo,
    Permission,
    PipeWireError,
    PipeWireModule,
    Pod,
    Properties,
    Proxy,
    Port,
    PortInfo,
    Registry,
    Stream,
    StreamBuffer,
    StreamData,
    STREAM_AUTOCONNECT,
    STREAM_DRIVER,
    STREAM_EXCLUSIVE,
    STREAM_INACTIVE,
    STREAM_MAP_BUFFERS,
    STREAM_NO_CONVERT,
    STREAM_TRIGGER,
    Audio,
    audio_format,
    buffer_data,
    bytes,
    capacity,
    connect!,
    create_object,
    data_pointer,
    dequeue_buffer,
    dequeue_buffer!,
    disconnect!,
    destroy_global!,
    destroy_object!,
    enum_params!,
    flush!,
    globals,
    get_permissions!,
    bound_id,
    interface_type,
    library_version,
    main_loop,
    node_id,
    pod_type,
    proxy_id,
    queue_buffer!,
    return_buffer!,
    quit!,
    roundtrip,
    run!,
    set_active!,
    set_chunk!,
    set_param!,
    set_property!,
    send_command!,
    stream_state,
    subscribe_params!,
    trigger_process!,
    update_permissions!,
    update_properties!,
    clear!,
    writable_bytes,
    with_main_loop,
    with_registry

include("generated/LibPipeWire.jl")
include("main_loop.jl")
include("properties.jl")
include("core.jl")
include("proxy.jl")
include("spa.jl")
include("objects.jl")
include("stream.jl")

"""
    library_version() -> VersionNumber

Return the version of the loaded PipeWire client library.
"""
library_version() = VersionNumber(unsafe_string(LibPipeWire.pw_get_library_version()))

function __init__()
    _initialize_callbacks!()
    _initialize_proxy_callbacks!()
    _initialize_object_callbacks!()
    _initialize_stream_callbacks!()
    return nothing
end

end # module PipeWire
