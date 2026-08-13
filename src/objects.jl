const _NODE_INTERFACE = "PipeWire:Interface:Node"
const _PORT_INTERFACE = "PipeWire:Interface:Port"
const _DEVICE_INTERFACE = "PipeWire:Interface:Device"
const _LINK_INTERFACE = "PipeWire:Interface:Link"
const _METADATA_INTERFACE = "PipeWire:Interface:Metadata"
const _OBJECT_INTERFACE_VERSION = UInt32(3)

"The input or output direction of a PipeWire port."
@enum Direction::UInt32 begin
    DIRECTION_INPUT = LibPipeWire.SPA_DIRECTION_INPUT
    DIRECTION_OUTPUT = LibPipeWire.SPA_DIRECTION_OUTPUT
end

"The current state reported for a PipeWire node."
@enum NodeState::Int32 begin
    NODE_STATE_ERROR = LibPipeWire.PW_NODE_STATE_ERROR
    NODE_STATE_CREATING = LibPipeWire.PW_NODE_STATE_CREATING
    NODE_STATE_SUSPENDED = LibPipeWire.PW_NODE_STATE_SUSPENDED
    NODE_STATE_IDLE = LibPipeWire.PW_NODE_STATE_IDLE
    NODE_STATE_RUNNING = LibPipeWire.PW_NODE_STATE_RUNNING
end

"The current negotiation or streaming state of a PipeWire link."
@enum LinkState::Int32 begin
    LINK_STATE_ERROR = LibPipeWire.PW_LINK_STATE_ERROR
    LINK_STATE_UNLINKED = LibPipeWire.PW_LINK_STATE_UNLINKED
    LINK_STATE_INIT = LibPipeWire.PW_LINK_STATE_INIT
    LINK_STATE_NEGOTIATING = LibPipeWire.PW_LINK_STATE_NEGOTIATING
    LINK_STATE_ALLOCATING = LibPipeWire.PW_LINK_STATE_ALLOCATING
    LINK_STATE_PAUSED = LibPipeWire.PW_LINK_STATE_PAUSED
    LINK_STATE_ACTIVE = LibPipeWire.PW_LINK_STATE_ACTIVE
end

"A copied SPA parameter descriptor from a PipeWire object info event."
struct ParamInfo
    id::UInt32
    flags::UInt32
    user::UInt32
    sequence::Int32
end

"A copied node information snapshot."
struct NodeInfo
    id::UInt32
    max_input_ports::UInt32
    max_output_ports::UInt32
    change_mask::UInt64
    n_input_ports::UInt32
    n_output_ports::UInt32
    state::NodeState
    error::Union{Nothing,String}
    properties::Dict{String,String}
    params::Vector{ParamInfo}
end

"A copied port information snapshot."
struct PortInfo
    id::UInt32
    direction::Direction
    change_mask::UInt64
    properties::Dict{String,String}
    params::Vector{ParamInfo}
end

"A copied device information snapshot."
struct DeviceInfo
    id::UInt32
    change_mask::UInt64
    properties::Dict{String,String}
    params::Vector{ParamInfo}
end

"A copied link information snapshot."
struct LinkInfo
    id::UInt32
    output_node_id::UInt32
    output_port_id::UInt32
    input_node_id::UInt32
    input_port_id::UInt32
    change_mask::UInt64
    state::LinkState
    error::Union{Nothing,String}
    format::Union{Nothing,Pod}
    properties::Dict{String,String}
end

function _copy_param_infos(pointer::Ptr{LibPipeWire.spa_param_info}, count::UInt32)
    result = Vector{ParamInfo}(undef, count)
    for index in eachindex(result)
        info = unsafe_load(pointer, index)
        result[index] = ParamInfo(info.id, info.flags, info.user, info.seq)
    end
    return result
end

function _copy_node_info(pointer::Ptr{LibPipeWire.pw_node_info})
    pointer == C_NULL && throw(ArgumentError("the node info pointer is null"))
    info = unsafe_load(pointer)
    return NodeInfo(
        info.id,
        info.max_input_ports,
        info.max_output_ports,
        info.change_mask,
        info.n_input_ports,
        info.n_output_ports,
        NodeState(info.state),
        info.error == C_NULL ? nothing : unsafe_string(info.error),
        _copy_properties(info.props),
        _copy_param_infos(info.params, info.n_params),
    )
end

function _copy_port_info(pointer::Ptr{LibPipeWire.pw_port_info})
    pointer == C_NULL && throw(ArgumentError("the port info pointer is null"))
    info = unsafe_load(pointer)
    return PortInfo(
        info.id,
        Direction(info.direction),
        info.change_mask,
        _copy_properties(info.props),
        _copy_param_infos(info.params, info.n_params),
    )
end


function _copy_device_info(pointer::Ptr{LibPipeWire.pw_device_info})
    pointer == C_NULL && throw(ArgumentError("the device info pointer is null"))
    info = unsafe_load(pointer)
    return DeviceInfo(
        info.id,
        info.change_mask,
        _copy_properties(info.props),
        _copy_param_infos(info.params, info.n_params),
    )
end

function _copy_link_info(pointer::Ptr{LibPipeWire.pw_link_info})
    pointer == C_NULL && throw(ArgumentError("the link info pointer is null"))
    info = unsafe_load(pointer)
    return LinkInfo(
        info.id,
        info.output_node_id,
        info.output_port_id,
        info.input_node_id,
        info.input_port_id,
        info.change_mask,
        LinkState(info.state),
        info.error == C_NULL ? nothing : unsafe_string(info.error),
        _copy_pod(info.format),
        _copy_properties(info.props),
    )
end

for (name, event_type) in (
    (:Node, :(LibPipeWire.pw_node_events)),
    (:Port, :(LibPipeWire.pw_port_events)),
    (:Device, :(LibPipeWire.pw_device_events)),
    (:Link, :(LibPipeWire.pw_link_events)),
    (:Metadata, :(LibPipeWire.pw_metadata_events)),
)
    @eval begin
        mutable struct $name{ProxyType<:Proxy,Callbacks}
            proxy::ProxyType
            callback_lock::ReentrantLock
            listener::Base.RefValue{LibPipeWire.spa_hook}
            events::Base.RefValue{$event_type}
            callbacks::Callbacks
            callback_error::Base.RefValue{Any}
            callbacks_active::Bool
        end
    end
end

"""
    Node

An owning typed proxy for a PipeWire node. Construct one with
`bind(registry, global_object, Node; callbacks...)`.
"""
Node

"""
    Port

An owning typed proxy for a PipeWire port. Construct one with
`bind(registry, global_object, Port; callbacks...)`.
"""
Port

"""
    Device

An owning typed proxy for a PipeWire device. Construct one with
`bind(registry, global_object, Device; callbacks...)`.
"""
Device

"""
    Link

An owning typed proxy for a PipeWire link. Construct one with
`bind(registry, global_object, Link; callbacks...)`.
"""
Link

"""
    Metadata

An owning typed proxy for a PipeWire metadata store. Construct one with
`bind(registry, global_object, Metadata; callbacks...)`.
"""
Metadata

const ManagedObject = Union{Node,Port,Device,Link,Metadata}

function _invoke_object_callback(object::ManagedObject, ::Val{Field}, args...) where {Field}
    lock(object.callback_lock)
    if !object.callbacks_active
        unlock(object.callback_lock)
        return nothing
    end
    callback = getfield(object.callbacks, Field)
    unlock(object.callback_lock)
    callback === nothing && return nothing
    try
        callback(object, args...)
    catch error
        lock(object.callback_lock) do
            object.callback_error[] === nothing && (object.callback_error[] = error)
        end
        _stop_after_callback(object.proxy.registry.core.callback_state, error)
    end
    return nothing
end

function _require_open(object::ManagedObject)
    error = lock(object.callback_lock) do
        object.callback_error[]
    end
    error === nothing || throw(error)
    return _require_open(object.proxy)
end

Base.isopen(object::ManagedObject) = isopen(object.proxy)

function Base.close(object::ManagedObject)
    lock(object.callback_lock) do
        object.callbacks_active = false
    end
    close(object.proxy)
    return nothing
end

interface_type(object::ManagedObject) = interface_type(object.proxy)
proxy_id(object::ManagedObject) = proxy_id(object.proxy)
bound_id(object::ManagedObject) = bound_id(object.proxy)

function roundtrip(object::ManagedObject)
    roundtrip(object.proxy)
    _require_open(object)
    return nothing
end

function _typed_proxy(
    registry::Registry,
    global_object::Global,
    expected_type::String,
    version::Integer;
    proxy_callbacks...,
)
    global_object.type == expected_type || throw(
        ArgumentError("the global does not implement $expected_type"),
    )
    maximum = min(global_object.version, _OBJECT_INTERFACE_VERSION)
    0 <= version <= maximum || throw(
        ArgumentError("the requested interface version exceeds the supported version"),
    )
    return bind(registry, global_object; version=version, proxy_callbacks...)
end

function _with_object_handle(call, object::ManagedObject, ::Type{T}) where {T}
    error = lock(object.callback_lock) do
        object.callback_error[]
    end
    error === nothing || throw(error)
    return lock(object.proxy.state_lock) do
        call(Ptr{T}(_require_open(object.proxy)))
    end
end

function _node_info(data::Ptr{Cvoid}, info::Ptr{LibPipeWire.pw_node_info})::Cvoid
    object = _callback_state(data, Node)
    try
        _invoke_object_callback(object, Val(:on_info), _copy_node_info(info))
    catch error
        _record_object_callback_error(object, error)
    end
    return nothing
end

function _port_info(data::Ptr{Cvoid}, info::Ptr{LibPipeWire.pw_port_info})::Cvoid
    object = _callback_state(data, Port)
    try
        _invoke_object_callback(object, Val(:on_info), _copy_port_info(info))
    catch error
        _record_object_callback_error(object, error)
    end
    return nothing
end

function _device_info(data::Ptr{Cvoid}, info::Ptr{LibPipeWire.pw_device_info})::Cvoid
    object = _callback_state(data, Device)
    try
        _invoke_object_callback(object, Val(:on_info), _copy_device_info(info))
    catch error
        _record_object_callback_error(object, error)
    end
    return nothing
end

function _link_info(data::Ptr{Cvoid}, info::Ptr{LibPipeWire.pw_link_info})::Cvoid
    object = _callback_state(data, Link)
    try
        _invoke_object_callback(object, Val(:on_info), _copy_link_info(info))
    catch error
        _record_object_callback_error(object, error)
    end
    return nothing
end

function _record_object_callback_error(object::ManagedObject, error)
    lock(object.callback_lock) do
        object.callback_error[] === nothing && (object.callback_error[] = error)
    end
    _stop_after_callback(object.proxy.registry.core.callback_state, error)
    return nothing
end

function _object_param(
    object::Union{Node,Port,Device},
    sequence::Cint,
    id::UInt32,
    index::UInt32,
    next::UInt32,
    param::Ptr{LibPipeWire.spa_pod},
)
    try
        _invoke_object_callback(
            object,
            Val(:on_param),
            sequence,
            id,
            index,
            next,
            _copy_pod(param),
        )
    catch error
        _record_object_callback_error(object, error)
    end
    return nothing
end

function _node_param(data::Ptr{Cvoid}, seq::Cint, id::UInt32, index::UInt32, next::UInt32, param::Ptr{LibPipeWire.spa_pod})::Cvoid
    _object_param(_callback_state(data, Node), seq, id, index, next, param)
end

function _port_param(data::Ptr{Cvoid}, seq::Cint, id::UInt32, index::UInt32, next::UInt32, param::Ptr{LibPipeWire.spa_pod})::Cvoid
    _object_param(_callback_state(data, Port), seq, id, index, next, param)
end

function _device_param(data::Ptr{Cvoid}, seq::Cint, id::UInt32, index::UInt32, next::UInt32, param::Ptr{LibPipeWire.spa_pod})::Cvoid
    _object_param(_callback_state(data, Device), seq, id, index, next, param)
end

function _metadata_property(
    data::Ptr{Cvoid},
    subject::UInt32,
    key::Cstring,
    type::Cstring,
    value::Cstring,
)::Cint
    object = _callback_state(data, Metadata)
    try
        _invoke_object_callback(
            object,
            Val(:on_property),
            subject,
            key == C_NULL ? nothing : unsafe_string(key),
            type == C_NULL ? nothing : unsafe_string(type),
            value == C_NULL ? nothing : unsafe_string(value),
        )
    catch error
        _record_object_callback_error(object, error)
    end
    return Cint(0)
end

const _NODE_INFO = Ref{Ptr{Cvoid}}(C_NULL)
const _NODE_PARAM = Ref{Ptr{Cvoid}}(C_NULL)
const _PORT_INFO = Ref{Ptr{Cvoid}}(C_NULL)
const _PORT_PARAM = Ref{Ptr{Cvoid}}(C_NULL)
const _DEVICE_INFO = Ref{Ptr{Cvoid}}(C_NULL)
const _DEVICE_PARAM = Ref{Ptr{Cvoid}}(C_NULL)
const _LINK_INFO = Ref{Ptr{Cvoid}}(C_NULL)
const _METADATA_PROPERTY = Ref{Ptr{Cvoid}}(C_NULL)

function _initialize_object_callbacks!()
    _NODE_INFO[] = @cfunction(_node_info, Cvoid, (Ptr{Cvoid}, Ptr{LibPipeWire.pw_node_info}))
    _NODE_PARAM[] = @cfunction(_node_param, Cvoid, (Ptr{Cvoid}, Cint, UInt32, UInt32, UInt32, Ptr{LibPipeWire.spa_pod}))
    _PORT_INFO[] = @cfunction(_port_info, Cvoid, (Ptr{Cvoid}, Ptr{LibPipeWire.pw_port_info}))
    _PORT_PARAM[] = @cfunction(_port_param, Cvoid, (Ptr{Cvoid}, Cint, UInt32, UInt32, UInt32, Ptr{LibPipeWire.spa_pod}))
    _DEVICE_INFO[] = @cfunction(_device_info, Cvoid, (Ptr{Cvoid}, Ptr{LibPipeWire.pw_device_info}))
    _DEVICE_PARAM[] = @cfunction(_device_param, Cvoid, (Ptr{Cvoid}, Cint, UInt32, UInt32, UInt32, Ptr{LibPipeWire.spa_pod}))
    _LINK_INFO[] = @cfunction(_link_info, Cvoid, (Ptr{Cvoid}, Ptr{LibPipeWire.pw_link_info}))
    _METADATA_PROPERTY[] = @cfunction(_metadata_property, Cint, (Ptr{Cvoid}, UInt32, Cstring, Cstring, Cstring))
    return nothing
end

function _proxy_callback_keywords(on_bound, on_removed, on_done, on_error, on_bound_properties)
    return (
        on_bound=on_bound,
        on_removed=on_removed,
        on_done=on_done,
        on_error=on_error,
        on_bound_properties=on_bound_properties,
    )
end

"""
    bind(registry, global_object, Node; callbacks...) -> Node

Bind a node global and install copied `on_info` and `on_param` event callbacks.
The base proxy callbacks are also accepted. Close the node before its registry.
"""
function Base.bind(
    registry::Registry,
    global_object::Global,
    ::Type{Node};
    version::Integer=min(global_object.version, _OBJECT_INTERFACE_VERSION),
    on_info=nothing,
    on_param=nothing,
    on_bound=nothing,
    on_removed=nothing,
    on_done=nothing,
    on_error=nothing,
    on_bound_properties=nothing,
)
    proxy_callbacks = _proxy_callback_keywords(on_bound, on_removed, on_done, on_error, on_bound_properties)
    proxy = _typed_proxy(registry, global_object, _NODE_INTERFACE, version; proxy_callbacks...)
    listener = Ref(_zero_hook())
    events = Ref(LibPipeWire.pw_node_events(UInt32(0), _NODE_INFO[], _NODE_PARAM[]))
    callbacks = (on_info=on_info, on_param=on_param)
    object = Node(proxy, ReentrantLock(), listener, events, callbacks, Ref{Any}(nothing), true)
    result = GC.@preserve object listener events LibPipeWire.pw_node_add_listener(
        Ptr{LibPipeWire.pw_node}(proxy.handle),
        Base.unsafe_convert(Ptr{LibPipeWire.spa_hook}, listener),
        Base.unsafe_convert(Ptr{LibPipeWire.pw_node_events}, events),
        pointer_from_objref(object),
    )
    result < 0 && (close(object); throw(PipeWireError(:pw_node_add_listener, result)))
    finalizer(close, object)
    return object
end


"""
    bind(registry, global_object, Port; callbacks...) -> Port

Bind a port global and install copied `on_info` and `on_param` event callbacks.
The base proxy callbacks are also accepted. Close the port before its registry.
"""
function Base.bind(
    registry::Registry,
    global_object::Global,
    ::Type{Port};
    version::Integer=min(global_object.version, _OBJECT_INTERFACE_VERSION),
    on_info=nothing,
    on_param=nothing,
    on_bound=nothing,
    on_removed=nothing,
    on_done=nothing,
    on_error=nothing,
    on_bound_properties=nothing,
)
    proxy_callbacks = _proxy_callback_keywords(on_bound, on_removed, on_done, on_error, on_bound_properties)
    proxy = _typed_proxy(registry, global_object, _PORT_INTERFACE, version; proxy_callbacks...)
    listener = Ref(_zero_hook())
    events = Ref(LibPipeWire.pw_port_events(UInt32(0), _PORT_INFO[], _PORT_PARAM[]))
    callbacks = (on_info=on_info, on_param=on_param)
    object = Port(proxy, ReentrantLock(), listener, events, callbacks, Ref{Any}(nothing), true)
    result = GC.@preserve object listener events LibPipeWire.pw_port_add_listener(
        Ptr{LibPipeWire.pw_port}(proxy.handle),
        Base.unsafe_convert(Ptr{LibPipeWire.spa_hook}, listener),
        Base.unsafe_convert(Ptr{LibPipeWire.pw_port_events}, events),
        pointer_from_objref(object),
    )
    result < 0 && (close(object); throw(PipeWireError(:pw_port_add_listener, result)))
    finalizer(close, object)
    return object
end

"""
    bind(registry, global_object, Device; callbacks...) -> Device

Bind a device global and install copied `on_info` and `on_param` event callbacks.
The base proxy callbacks are also accepted. Close the device before its registry.
"""
function Base.bind(
    registry::Registry,
    global_object::Global,
    ::Type{Device};
    version::Integer=min(global_object.version, _OBJECT_INTERFACE_VERSION),
    on_info=nothing,
    on_param=nothing,
    on_bound=nothing,
    on_removed=nothing,
    on_done=nothing,
    on_error=nothing,
    on_bound_properties=nothing,
)
    proxy_callbacks = _proxy_callback_keywords(on_bound, on_removed, on_done, on_error, on_bound_properties)
    proxy = _typed_proxy(registry, global_object, _DEVICE_INTERFACE, version; proxy_callbacks...)
    listener = Ref(_zero_hook())
    events = Ref(LibPipeWire.pw_device_events(UInt32(0), _DEVICE_INFO[], _DEVICE_PARAM[]))
    callbacks = (on_info=on_info, on_param=on_param)
    object = Device(proxy, ReentrantLock(), listener, events, callbacks, Ref{Any}(nothing), true)
    result = GC.@preserve object listener events LibPipeWire.pw_device_add_listener(
        Ptr{LibPipeWire.pw_device}(proxy.handle),
        Base.unsafe_convert(Ptr{LibPipeWire.spa_hook}, listener),
        Base.unsafe_convert(Ptr{LibPipeWire.pw_device_events}, events),
        pointer_from_objref(object),
    )
    result < 0 && (close(object); throw(PipeWireError(:pw_device_add_listener, result)))
    finalizer(close, object)
    return object
end

"""
    bind(registry, global_object, Link; callbacks...) -> Link

Bind a link global and install a copied `on_info` event callback. The base
proxy callbacks are also accepted. Close the link before its registry.
"""
function Base.bind(
    registry::Registry,
    global_object::Global,
    ::Type{Link};
    version::Integer=min(global_object.version, _OBJECT_INTERFACE_VERSION),
    on_info=nothing,
    on_bound=nothing,
    on_removed=nothing,
    on_done=nothing,
    on_error=nothing,
    on_bound_properties=nothing,
)
    proxy_callbacks = _proxy_callback_keywords(on_bound, on_removed, on_done, on_error, on_bound_properties)
    proxy = _typed_proxy(registry, global_object, _LINK_INTERFACE, version; proxy_callbacks...)
    listener = Ref(_zero_hook())
    events = Ref(LibPipeWire.pw_link_events(UInt32(0), _LINK_INFO[]))
    callbacks = (on_info=on_info,)
    object = Link(proxy, ReentrantLock(), listener, events, callbacks, Ref{Any}(nothing), true)
    result = GC.@preserve object listener events LibPipeWire.pw_link_add_listener(
        Ptr{LibPipeWire.pw_link}(proxy.handle),
        Base.unsafe_convert(Ptr{LibPipeWire.spa_hook}, listener),
        Base.unsafe_convert(Ptr{LibPipeWire.pw_link_events}, events),
        pointer_from_objref(object),
    )
    result < 0 && (close(object); throw(PipeWireError(:pw_link_add_listener, result)))
    finalizer(close, object)
    return object
end

function _with_metadata_method(call, object::Metadata, field::Symbol)
    return _with_object_handle(object, LibPipeWire.pw_metadata) do handle
        interface = unsafe_load(Ptr{LibPipeWire.spa_interface}(handle))
        interface.cb.funcs == C_NULL && throw(
            PipeWireError(Symbol("pw_metadata_", field), -Base.Libc.ENOTSUP),
        )
        methods = unsafe_load(Ptr{LibPipeWire.pw_metadata_methods}(interface.cb.funcs))
        method = getfield(methods, field)
        method == C_NULL && throw(
            PipeWireError(Symbol("pw_metadata_", field), -Base.Libc.ENOTSUP),
        )
        call(interface.cb.data, method)
    end
end

"""
    bind(registry, global_object, Metadata; callbacks...) -> Metadata

Bind a metadata global and install `on_property`. Property strings are copied
before the callback runs. The base proxy callbacks are also accepted.
"""
function Base.bind(
    registry::Registry,
    global_object::Global,
    ::Type{Metadata};
    version::Integer=min(global_object.version, _OBJECT_INTERFACE_VERSION),
    on_property=nothing,
    on_bound=nothing,
    on_removed=nothing,
    on_done=nothing,
    on_error=nothing,
    on_bound_properties=nothing,
)
    proxy_callbacks = _proxy_callback_keywords(on_bound, on_removed, on_done, on_error, on_bound_properties)
    proxy = _typed_proxy(registry, global_object, _METADATA_INTERFACE, version; proxy_callbacks...)
    listener = Ref(_zero_hook())
    events = Ref(LibPipeWire.pw_metadata_events(UInt32(0), _METADATA_PROPERTY[]))
    callbacks = (on_property=on_property,)
    object = Metadata(proxy, ReentrantLock(), listener, events, callbacks, Ref{Any}(nothing), true)
    result = _with_metadata_method(object, :add_listener) do data, method
        GC.@preserve object listener events @ccall $method(
            data::Ptr{Cvoid},
            Base.unsafe_convert(Ptr{LibPipeWire.spa_hook}, listener)::Ptr{LibPipeWire.spa_hook},
            Base.unsafe_convert(Ptr{LibPipeWire.pw_metadata_events}, events)::Ptr{LibPipeWire.pw_metadata_events},
            pointer_from_objref(object)::Ptr{Cvoid},
        )::Cint
    end
    result < 0 && (close(object); throw(PipeWireError(:pw_metadata_add_listener, result)))
    finalizer(close, object)
    return object
end

function _parameter_ids(ids)
    return UInt32[UInt32(id) for id in ids]
end

"""
    subscribe_params!(object, ids)

Subscribe a node, port, or device to changes for the given SPA parameter IDs.
Return `object`.
"""
function subscribe_params!(object::Node, ids)
    values = _parameter_ids(ids)
    result = GC.@preserve values _with_object_handle(object, LibPipeWire.pw_node) do handle
        LibPipeWire.pw_node_subscribe_params(handle, pointer(values), UInt32(length(values)))
    end
    _check_result(:pw_node_subscribe_params, result)
    return object
end

function subscribe_params!(object::Port, ids)
    values = _parameter_ids(ids)
    result = GC.@preserve values _with_object_handle(object, LibPipeWire.pw_port) do handle
        LibPipeWire.pw_port_subscribe_params(handle, pointer(values), UInt32(length(values)))
    end
    _check_result(:pw_port_subscribe_params, result)
    return object
end

function subscribe_params!(object::Device, ids)
    values = _parameter_ids(ids)
    result = GC.@preserve values _with_object_handle(object, LibPipeWire.pw_device) do handle
        LibPipeWire.pw_device_subscribe_params(handle, pointer(values), UInt32(length(values)))
    end
    _check_result(:pw_device_subscribe_params, result)
    return object
end

function _enum_params(function_name::Symbol, call, object, object_type, id, sequence, start, count, filter)
    sequence isa Integer && typemin(Cint) <= sequence <= typemax(Cint) || throw(ArgumentError("sequence is outside Cint range"))
    filter_pointer = filter === nothing ? Ptr{LibPipeWire.spa_pod}(C_NULL) : _pod_pointer(filter)
    result = GC.@preserve filter _with_object_handle(object, object_type) do handle
        call(
            handle,
            Cint(sequence),
            UInt32(id),
            UInt32(start),
            UInt32(count),
            filter_pointer,
        )
    end
    _check_result(function_name, result)
    return nothing
end

"""
    enum_params!(object, id; sequence=0, start=0, count=typemax(UInt32), filter=nothing)

Request parameter enumeration on a node, port, or device. Results arrive
through the object's `on_param` callback. Return `object`.
"""
function enum_params!(object::Node, id::Integer; sequence::Integer=0, start::Integer=0, count::Integer=typemax(UInt32), filter::Union{Nothing,Pod}=nothing)
    _enum_params(:pw_node_enum_params, LibPipeWire.pw_node_enum_params, object, LibPipeWire.pw_node, id, sequence, start, count, filter)
    return object
end


function enum_params!(object::Port, id::Integer; sequence::Integer=0, start::Integer=0, count::Integer=typemax(UInt32), filter::Union{Nothing,Pod}=nothing)
    _enum_params(:pw_port_enum_params, LibPipeWire.pw_port_enum_params, object, LibPipeWire.pw_port, id, sequence, start, count, filter)
    return object
end

function enum_params!(object::Device, id::Integer; sequence::Integer=0, start::Integer=0, count::Integer=typemax(UInt32), filter::Union{Nothing,Pod}=nothing)
    _enum_params(:pw_device_enum_params, LibPipeWire.pw_device_enum_params, object, LibPipeWire.pw_device, id, sequence, start, count, filter)
    return object
end

"""
    set_param!(object, id, param; flags=0)

Set a SPA parameter on a node or device and return `object`.
"""
function set_param!(object::Union{Node,Device}, id::Integer, param::Pod; flags::Integer=0)
    pointer = _pod_pointer(param)
    result = GC.@preserve param if object isa Node
        _with_object_handle(object, LibPipeWire.pw_node) do handle
            LibPipeWire.pw_node_set_param(handle, UInt32(id), UInt32(flags), pointer)
        end
    else
        _with_object_handle(object, LibPipeWire.pw_device) do handle
            LibPipeWire.pw_device_set_param(handle, UInt32(id), UInt32(flags), pointer)
        end
    end
    _check_result(object isa Node ? :pw_node_set_param : :pw_device_set_param, result)
    return object
end

"""
    send_command!(node, command)

Send an owned SPA command POD to a node and return the node.
"""
function send_command!(object::Node, command::Pod)
    result = GC.@preserve command _with_object_handle(object, LibPipeWire.pw_node) do handle
        LibPipeWire.pw_node_send_command(
            handle,
            Ptr{LibPipeWire.spa_command}(_pod_pointer(command)),
        )
    end
    _check_result(:pw_node_send_command, result)
    return object
end

function _metadata_string(value, kind)
    value === nothing && return nothing
    return _validate_property_string(String(value), kind)
end

"""
    set_property!(metadata, subject, key; type=nothing, value=nothing)

Set a metadata property and return `metadata`. Pass `value=nothing` to remove
the key, or `key=nothing` to remove every property associated with `subject`.
"""
function set_property!(
    object::Metadata,
    subject::Integer,
    key;
    type=nothing,
    value=nothing,
)
    subject < 0 && throw(ArgumentError("metadata subject must be nonnegative"))
    owned_key = _metadata_string(key, "metadata key")
    owned_type = _metadata_string(type, "metadata type")
    owned_value = _metadata_string(value, "metadata value")
    result = _with_metadata_method(object, :set_property) do data, method
        GC.@preserve owned_key owned_type owned_value @ccall $method(
            data::Ptr{Cvoid},
            UInt32(subject)::UInt32,
            (owned_key === nothing ? C_NULL : pointer(owned_key))::Cstring,
            (owned_type === nothing ? C_NULL : pointer(owned_type))::Cstring,
            (owned_value === nothing ? C_NULL : pointer(owned_value))::Cstring,
        )::Cint
    end
    _check_result(:pw_metadata_set_property, result)
    return object
end

"""
    clear!(metadata)

Clear all entries from a PipeWire metadata store and return `metadata`.
"""
function clear!(object::Metadata)
    result = _with_metadata_method(object, :clear) do data, method
        @ccall $method(data::Ptr{Cvoid})::Cint
    end
    _check_result(:pw_metadata_clear, result)
    return object
end
