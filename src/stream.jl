"Automatically connect a stream to a compatible target."
const STREAM_AUTOCONNECT = LibPipeWire.PW_STREAM_FLAG_AUTOCONNECT
"Create a stream in the inactive state."
const STREAM_INACTIVE = LibPipeWire.PW_STREAM_FLAG_INACTIVE
"Request memory-mapped stream buffers."
const STREAM_MAP_BUFFERS = LibPipeWire.PW_STREAM_FLAG_MAP_BUFFERS
"Make a stream a graph driver when permitted."
const STREAM_DRIVER = LibPipeWire.PW_STREAM_FLAG_DRIVER
"Disable format conversion for a stream."
const STREAM_NO_CONVERT = LibPipeWire.PW_STREAM_FLAG_NO_CONVERT
"Require exclusive access to the stream target."
const STREAM_EXCLUSIVE = LibPipeWire.PW_STREAM_FLAG_EXCLUSIVE
"Do not reconnect automatically when the target disappears."
const STREAM_DONT_RECONNECT = LibPipeWire.PW_STREAM_FLAG_DONT_RECONNECT
"Let the application allocate stream-buffer memory."
const STREAM_ALLOC_BUFFERS = LibPipeWire.PW_STREAM_FLAG_ALLOC_BUFFERS
"Enable explicit stream processing triggers."
const STREAM_TRIGGER = LibPipeWire.PW_STREAM_FLAG_TRIGGER
"Dequeue and queue buffers outside the real-time process callback."
const STREAM_ASYNC = LibPipeWire.PW_STREAM_FLAG_ASYNC
"Request process callbacks as soon as playback buffers are available."
const STREAM_EARLY_PROCESS = LibPipeWire.PW_STREAM_FLAG_EARLY_PROCESS
const _PW_ID_ANY = typemax(UInt32)

"A copied snapshot of a PipeWire stream control."
struct StreamControl
    name::String
    flags::UInt32
    default::Float32
    minimum::Float32
    maximum::Float32
    values::Vector{Float32}
    max_values::UInt32
end

Base.:(==)(left::StreamControl, right::StreamControl) =
    left.name == right.name &&
    left.flags == right.flags &&
    left.default == right.default &&
    left.minimum == right.minimum &&
    left.maximum == right.maximum &&
    left.values == right.values &&
    left.max_values == right.max_values
Base.isequal(left::StreamControl, right::StreamControl) =
    isequal(left.name, right.name) &&
    isequal(left.flags, right.flags) &&
    isequal(left.default, right.default) &&
    isequal(left.minimum, right.minimum) &&
    isequal(left.maximum, right.maximum) &&
    isequal(left.values, right.values) &&
    isequal(left.max_values, right.max_values)
Base.hash(value::StreamControl, seed::UInt) = hash(
    (
        value.name,
        value.flags,
        value.default,
        value.minimum,
        value.maximum,
        value.values,
        value.max_values,
    ),
    seed,
)

"A borrowed I/O area reported by a stream I/O-change callback."
struct StreamIO
    id::UInt32
    area::Ptr{Cvoid}
    size::UInt32
end

"A concrete snapshot of PipeWire stream timing and queue state."
struct StreamTime
    now::Int64
    rate::SPA.Fraction
    ticks::UInt64
    delay::Int64
    queued::UInt64
    buffered::UInt64
    queued_buffers::UInt32
    available_buffers::UInt32
    size::UInt64
end

function _copy_stream_control(pointer::Ptr{LibPipeWire.pw_stream_control})
    pointer == C_NULL && return nothing
    native = unsafe_load(pointer)
    name = native.name == C_NULL ? "" : unsafe_string(native.name)
    values = if native.values == C_NULL || native.n_values == 0
        Float32[]
    else
        copy(unsafe_wrap(Vector{Float32}, native.values, Int(native.n_values); own=false))
    end
    return StreamControl(
        name,
        native.flags,
        native.def,
        native.min,
        native.max,
        values,
        native.max_values,
    )
end

"""
    Stream(core, name; properties=nothing, on_state_changed=nothing,
           on_control_info=nothing, on_io_changed=nothing,
           on_param_changed=nothing, on_process=nothing,
           on_buffer_added=nothing, on_buffer_removed=nothing,
           on_drained=nothing, on_command=nothing, on_trigger_done=nothing)

Create an owning PipeWire stream. Callback functions run on the thread that
dispatches the PipeWire loop. They are suitable for ordinary Julia client code,
but are not hard-real-time safe and must not be used with PipeWire's
`RT_PROCESS` stream flag.

`properties` may be a [`Properties`](@ref) value or any iterable of string
pairs. A `Properties` argument is copied and remains open. Callback types are
part of the concrete `Stream` type. After warmup, dispatching `on_process`
allocates zero bytes when the callback itself does not allocate. Callback error
paths and the owned POD copy passed to `on_param_changed` are outside that
steady-state allocation contract.
"""
mutable struct Stream{CoreType<:CoreConnection,Callbacks}
    handle::Ptr{LibPipeWire.pw_stream}
    core::CoreType
    state_lock::ReentrantLock
    callback_lock::ReentrantLock
    listener::Base.RefValue{LibPipeWire.spa_hook}
    events::Base.RefValue{LibPipeWire.pw_stream_events}
    callbacks::Callbacks
    callback_error::Base.RefValue{Any}
    callbacks_active::Bool
    connected::Bool
end

function _stream_control_info(
    stream::Stream,
    id::UInt32,
    control::Ptr{LibPipeWire.pw_stream_control},
)::Cvoid
    try
        _invoke_stream_callback(stream, Val(:on_control_info), id, _copy_stream_control(control))
    catch error
        lock(stream.callback_lock) do
            stream.callback_error[] === nothing && (stream.callback_error[] = error)
        end
        _stop_after_callback(stream.core.callback_state, error)
    end
    return nothing
end

function _stream_io_changed(
    stream::Stream,
    id::UInt32,
    area::Ptr{Cvoid},
    size::UInt32,
)::Cvoid
    _invoke_stream_callback(stream, Val(:on_io_changed), StreamIO(id, area, size))
    return nothing
end

function _invoke_stream_callback(stream::Stream, ::Val{Field}, args...) where {Field}
    lock(stream.callback_lock)
    if !stream.callbacks_active
        unlock(stream.callback_lock)
        return nothing
    end
    callback = getfield(stream.callbacks, Field)
    unlock(stream.callback_lock)
    callback === nothing && return nothing
    try
        callback(stream, args...)
    catch error
        lock(stream.callback_lock) do
            stream.callback_error[] === nothing && (stream.callback_error[] = error)
        end
        _stop_after_callback(stream.core.callback_state, error)
    end
    return nothing
end

function _stream_state_changed(
    stream::Stream,
    old::Int32,
    current::Int32,
    message::Cstring,
)::Cvoid
    detail = message == C_NULL ? nothing : unsafe_string(message)
    _invoke_stream_callback(stream, Val(:on_state_changed), old, current, detail)
    return nothing
end

function _stream_param_changed(
    stream::Stream,
    id::UInt32,
    param::Ptr{LibPipeWire.spa_pod},
)::Cvoid
    try
        _invoke_stream_callback(stream, Val(:on_param_changed), id, _copy_pod(param))
    catch error
        lock(stream.callback_lock) do
            stream.callback_error[] === nothing && (stream.callback_error[] = error)
        end
        _stop_after_callback(stream.core.callback_state, error)
    end
    return nothing
end

function _stream_process(stream::Stream)::Cvoid
    _invoke_stream_callback(stream, Val(:on_process))
    return nothing
end

function _stream_buffer_added(
    stream::Stream,
    buffer::Ptr{LibPipeWire.pw_buffer},
)::Cvoid
    _invoke_stream_callback(stream, Val(:on_buffer_added), buffer)
    return nothing
end

function _stream_buffer_removed(
    stream::Stream,
    buffer::Ptr{LibPipeWire.pw_buffer},
)::Cvoid
    _invoke_stream_callback(stream, Val(:on_buffer_removed), buffer)
    return nothing
end

function _stream_drained(stream::Stream)::Cvoid
    _invoke_stream_callback(stream, Val(:on_drained))
    return nothing
end

function _stream_command(
    stream::Stream,
    command::Ptr{LibPipeWire.spa_command},
)::Cvoid
    try
        _invoke_stream_callback(
            stream,
            Val(:on_command),
            _copy_pod(Ptr{LibPipeWire.spa_pod}(command)),
        )
    catch error
        lock(stream.callback_lock) do
            stream.callback_error[] === nothing && (stream.callback_error[] = error)
        end
        _stop_after_callback(stream.core.callback_state, error)
    end
    return nothing
end

function _stream_trigger_done(stream::Stream)::Cvoid
    _invoke_stream_callback(stream, Val(:on_trigger_done))
    return nothing
end

function _stream_events(::T) where {T<:Stream}
    state_changed = @cfunction(
        _stream_state_changed,
        Cvoid,
        (Ref{T}, Int32, Int32, Cstring),
    )
    control_info = @cfunction(
        _stream_control_info,
        Cvoid,
        (Ref{T}, UInt32, Ptr{LibPipeWire.pw_stream_control}),
    )
    io_changed = @cfunction(
        _stream_io_changed,
        Cvoid,
        (Ref{T}, UInt32, Ptr{Cvoid}, UInt32),
    )
    param_changed = @cfunction(
        _stream_param_changed,
        Cvoid,
        (Ref{T}, UInt32, Ptr{LibPipeWire.spa_pod}),
    )
    process = @cfunction(_stream_process, Cvoid, (Ref{T},))
    buffer_added = @cfunction(
        _stream_buffer_added,
        Cvoid,
        (Ref{T}, Ptr{LibPipeWire.pw_buffer}),
    )
    buffer_removed = @cfunction(
        _stream_buffer_removed,
        Cvoid,
        (Ref{T}, Ptr{LibPipeWire.pw_buffer}),
    )
    drained = @cfunction(_stream_drained, Cvoid, (Ref{T},))
    command = @cfunction(
        _stream_command,
        Cvoid,
        (Ref{T}, Ptr{LibPipeWire.spa_command}),
    )
    trigger_done = @cfunction(_stream_trigger_done, Cvoid, (Ref{T},))
    return LibPipeWire.pw_stream_events(
        UInt32(2),
        _NULL_CALLBACK,
        state_changed,
        control_info,
        io_changed,
        param_changed,
        buffer_added,
        buffer_removed,
        process,
        drained,
        command,
        trigger_done,
    )
end

function Stream(
    core::CoreConnection,
    name::AbstractString;
    properties=nothing,
    on_state_changed=nothing,
    on_control_info=nothing,
    on_io_changed=nothing,
    on_param_changed=nothing,
    on_process=nothing,
    on_buffer_added=nothing,
    on_buffer_removed=nothing,
    on_drained=nothing,
    on_command=nothing,
    on_trigger_done=nothing,
)
    name_string = String(name)
    contains(name_string, '\0') && throw(ArgumentError("a PipeWire stream name cannot contain NUL"))
    core_handle = _retain_stream(core)
    native_properties = try
        _owned_native_properties(properties)
    catch
        _release_stream(core)
        rethrow()
    end
    handle = GC.@preserve name_string LibPipeWire.pw_stream_new(
        core_handle,
        pointer(name_string),
        native_properties,
    )
    if handle == C_NULL
        _release_stream(core)
        throw(PipeWireError(:pw_stream_new, -Base.Libc.errno()))
    end

    callbacks = (
        on_state_changed=on_state_changed,
        on_control_info=on_control_info,
        on_io_changed=on_io_changed,
        on_param_changed=on_param_changed,
        on_process=on_process,
        on_buffer_added=on_buffer_added,
        on_buffer_removed=on_buffer_removed,
        on_drained=on_drained,
        on_command=on_command,
        on_trigger_done=on_trigger_done,
    )
    listener = Ref(_zero_hook())
    events = Ref{LibPipeWire.pw_stream_events}()
    stream = Stream(
        handle,
        core,
        ReentrantLock(),
        ReentrantLock(),
        listener,
        events,
        callbacks,
        Ref{Any}(nothing),
        true,
        false,
    )
    try
        events[] = _stream_events(stream)
    catch
        close(stream)
        rethrow()
    end
    GC.@preserve stream listener events begin
        LibPipeWire.pw_stream_add_listener(
            handle,
            Base.unsafe_convert(Ptr{LibPipeWire.spa_hook}, listener),
            Base.unsafe_convert(Ptr{LibPipeWire.pw_stream_events}, events),
            pointer_from_objref(stream),
        )
    end
    finalizer(close, stream)
    return stream
end

main_loop(stream::Stream) = main_loop(stream.core)

function _require_open(stream::Stream)
    stream.handle == C_NULL &&
        throw(InvalidStateException("the PipeWire stream is closed", :closed))
    return stream.handle
end

function _check_callback_error(stream::Stream)
    error = lock(stream.callback_lock) do
        stream.callback_error[]
    end
    error === nothing || throw(error)
    return nothing
end

function Base.isopen(stream::Stream)
    return lock(stream.state_lock) do
        stream.handle != C_NULL
    end
end

function Base.close(stream::Stream)
    handle = lock(stream.state_lock) do
        stream.handle == C_NULL && return C_NULL
        handle = stream.handle
        stream.handle = Ptr{LibPipeWire.pw_stream}(C_NULL)
        stream.connected = false
        return handle
    end
    handle == C_NULL && return nothing
    lock(stream.callback_lock) do
        stream.callbacks_active = false
    end
    LibPipeWire.pw_stream_destroy(handle)
    _release_stream(stream.core)
    return nothing
end

"Return the current native state of `stream`, throwing a reported stream error."
function stream_state(stream::Stream)
    _check_callback_error(stream)
    error_pointer = Ref{Cstring}(C_NULL)
    value = lock(stream.state_lock) do
        LibPipeWire.pw_stream_get_state(_require_open(stream), error_pointer)
    end
    if value == LibPipeWire.PW_STREAM_STATE_ERROR
        detail = error_pointer[] == C_NULL ? nothing : unsafe_string(error_pointer[])
        throw(PipeWireError(:pw_stream, Cint(-Base.Libc.errno()), detail))
    end
    return value
end

"Return the bound PipeWire node ID for `stream`."
function node_id(stream::Stream)
    _check_callback_error(stream)
    return lock(stream.state_lock) do
        LibPipeWire.pw_stream_get_node_id(_require_open(stream))
    end
end

"Return the stream's native name as an owned Julia string."
function stream_name(stream::Stream)
    _check_callback_error(stream)
    return lock(stream.state_lock) do
        pointer = LibPipeWire.pw_stream_get_name(_require_open(stream))
        return pointer == C_NULL ? "" : unsafe_string(pointer)
    end
end

"Return a copied property snapshot for `stream`."
function stream_properties(stream::Stream)
    _check_callback_error(stream)
    return lock(stream.state_lock) do
        pointer = LibPipeWire.pw_stream_get_properties(_require_open(stream))
        pointer == C_NULL && return Dict{String,String}()
        native = unsafe_load(pointer)
        dictionary = Ref(native.dict)
        return GC.@preserve dictionary _copy_properties(
            Base.unsafe_convert(Ptr{LibPipeWire.spa_dict}, dictionary),
        )
    end
end

"Update stream properties and return `stream`."
function update_properties!(stream::Stream, properties)
    _check_callback_error(stream)
    _with_properties_dict(properties) do dictionary
        result = lock(stream.state_lock) do
            LibPipeWire.pw_stream_update_properties(_require_open(stream), dictionary)
        end
        _check_result(:pw_stream_update_properties, result)
    end
    return stream
end

function _stream_params(params)
    native = Pod[pod for pod in params]
    length(native) <= typemax(UInt32) ||
        throw(ArgumentError("stream has too many parameters"))
    pointers = Ptr{LibPipeWire.spa_pod}[_pod_pointer(pod) for pod in native]
    return native, pointers
end

"Update the parameters exposed by `stream` and return it."
function update_params!(stream::Stream, params)
    _check_callback_error(stream)
    native, pointers = _stream_params(params)
    result = GC.@preserve native pointers lock(stream.state_lock) do
        LibPipeWire.pw_stream_update_params(
            _require_open(stream),
            isempty(pointers) ? C_NULL : pointer(pointers),
            UInt32(length(pointers)),
        )
    end
    _check_result(:pw_stream_update_params, result)
    return stream
end

"Set one stream parameter, or clear it with `param=nothing`."
function set_param!(stream::Stream, id::Integer, param::Union{Nothing,Pod})
    _check_callback_error(stream)
    parameter_id = _core_uint32(id, "parameter ID")
    result = if param === nothing
        lock(stream.state_lock) do
            LibPipeWire.pw_stream_set_param(_require_open(stream), parameter_id, C_NULL)
        end
    else
        GC.@preserve param lock(stream.state_lock) do
            LibPipeWire.pw_stream_set_param(
                _require_open(stream),
                parameter_id,
                _pod_pointer(param),
            )
        end
    end
    _check_result(:pw_stream_set_param, result)
    return stream
end

"Return a copied stream-control snapshot, or `nothing` when it is unavailable."
function stream_control(stream::Stream, id::Integer)
    _check_callback_error(stream)
    control_id = _core_uint32(id, "control ID")
    return lock(stream.state_lock) do
        pointer = LibPipeWire.pw_stream_get_control(_require_open(stream), control_id)
        return _copy_stream_control(pointer)
    end
end

"Set the floating-point values for a stream control and return `stream`."
function set_control!(stream::Stream, id::Integer, values)
    _check_callback_error(stream)
    control_id = _core_uint32(id, "control ID")
    native_values = collect(Float32, values)
    length(native_values) <= typemax(UInt32) ||
        throw(ArgumentError("stream control has too many values"))
    result = GC.@preserve native_values lock(stream.state_lock) do
        ccall(
            (:pw_stream_set_control, LibPipeWire.PipeWire_jll.libpipewire),
            Cint,
            (Ptr{LibPipeWire.pw_stream}, UInt32, UInt32, Ptr{Cfloat}),
            _require_open(stream),
            control_id,
            UInt32(length(native_values)),
            isempty(native_values) ? C_NULL : pointer(native_values),
        )
    end
    _check_result(:pw_stream_set_control, result)
    return stream
end

set_control!(stream::Stream, id::Integer, value::Real) =
    set_control!(stream, id, (Float32(value),))

"Return a concrete timing snapshot for a running stream."
function stream_time(stream::Stream)
    _check_callback_error(stream)
    native = Ref{LibPipeWire.pw_time}()
    result = lock(stream.state_lock) do
        LibPipeWire.pw_stream_get_time_n(
            _require_open(stream),
            native,
            sizeof(LibPipeWire.pw_time),
        )
    end
    _check_result(:pw_stream_get_time_n, result)
    value = native[]
    return StreamTime(
        value.now,
        SPA.Fraction(value.rate.num, value.rate.denom),
        value.ticks,
        value.delay,
        value.queued,
        value.buffered,
        value.queued_buffers,
        value.avail_buffers,
        value.size,
    )
end

"Return the stream's current native monotonic time in nanoseconds."
function stream_nsec(stream::Stream)
    _check_callback_error(stream)
    return lock(stream.state_lock) do
        LibPipeWire.pw_stream_get_nsec(_require_open(stream))
    end
end

"Return whether a driver stream is currently driving the graph."
function is_driving(stream::Stream)
    _check_callback_error(stream)
    return lock(stream.state_lock) do
        handle = _require_open(stream)
        stream.connected && LibPipeWire.pw_stream_is_driving(handle)
    end
end

"Return whether the graph uses lazy scheduling for `stream`."
function is_lazy(stream::Stream)
    _check_callback_error(stream)
    return lock(stream.state_lock) do
        handle = _require_open(stream)
        stream.connected && LibPipeWire.pw_stream_is_lazy(handle)
    end
end

"Adjust an adaptive stream resampler's rate and return `stream`."
function set_rate!(stream::Stream, rate::Real)
    _check_callback_error(stream)
    value = Float64(rate)
    isfinite(value) || throw(ArgumentError("stream rate must be finite"))
    result = lock(stream.state_lock) do
        LibPipeWire.pw_stream_set_rate(_require_open(stream), value)
    end
    _check_result(:pw_stream_set_rate, result)
    return stream
end

"Emit an owned SPA event POD from `stream` and return it."
function emit_event!(stream::Stream, event::Pod)
    _check_callback_error(stream)
    object = pod_value(SPA.Object, event)
    LibPipeWire.SPA_TYPE_EVENT_START <= object.type < LibPipeWire._SPA_TYPE_EVENT_LAST ||
        throw(ArgumentError("the POD is not an SPA event object"))
    result = GC.@preserve event lock(stream.state_lock) do
        LibPipeWire.pw_stream_emit_event(
            _require_open(stream),
            Ptr{LibPipeWire.spa_event}(_pod_pointer(event)),
        )
    end
    _check_result(:pw_stream_emit_event, result)
    return stream
end

"""
    set_error!(stream, result, message)

Move `stream` to PipeWire's error state. `result` must be a negative
errno-style `Cint` value.
"""
function set_error!(stream::Stream, result::Integer, message::AbstractString)
    typemin(Cint) <= result < 0 ||
        throw(ArgumentError("a PipeWire stream error result must be a negative Cint"))
    text = _validate_c_string(String(message), "stream error message")
    format = "%s"
    native_result = GC.@preserve text format lock(stream.state_lock) do
        ccall(
            (:pw_stream_set_error, LibPipeWire.PipeWire_jll.libpipewire),
            Cint,
            (Ptr{LibPipeWire.pw_stream}, Cint, Cstring, Cstring),
            _require_open(stream),
            Cint(result),
            pointer(format),
            pointer(text),
        )
    end
    _check_result(:pw_stream_set_error, native_result)
    return stream
end

"""
    connect!(stream, direction; target=typemax(UInt32), flags=..., params=())

Connect a stream in the `:input` or `:output` direction and return it.
"""
function connect!(
    stream::Stream,
    direction::Symbol;
    target::Integer=_PW_ID_ANY,
    flags::Integer=STREAM_AUTOCONNECT | STREAM_MAP_BUFFERS,
    params=Pod[],
)
    native_direction = if direction === :input
        LibPipeWire.SPA_DIRECTION_INPUT
    elseif direction === :output
        LibPipeWire.SPA_DIRECTION_OUTPUT
    else
        throw(ArgumentError("stream direction must be :input or :output"))
    end
    target_id = _core_uint32(target, "stream target ID")
    native_flags = _core_uint32(flags, "stream flags")
    native_flags & LibPipeWire.PW_STREAM_FLAG_RT_PROCESS == 0 || throw(
        ArgumentError(
            "Julia stream callbacks are not hard-real-time safe; RT_PROCESS is unsupported",
        ),
    )
    native_flags & LibPipeWire.PW_STREAM_FLAG_RT_TRIGGER_DONE == 0 || throw(
        ArgumentError(
            "Julia stream callbacks are not hard-real-time safe; RT_TRIGGER_DONE is unsupported",
        ),
    )
    native_params, param_pointers = _stream_params(params)
    result = GC.@preserve native_params param_pointers begin
        lock(stream.state_lock) do
            stream.connected && throw(
                InvalidStateException("the PipeWire stream is already connected", :connected),
            )
            result = LibPipeWire.pw_stream_connect(
                _require_open(stream),
                native_direction,
                target_id,
                native_flags,
                isempty(param_pointers) ? C_NULL : pointer(param_pointers),
                UInt32(length(param_pointers)),
            )
            result >= 0 && (stream.connected = true)
            result
        end
    end
    _check_result(:pw_stream_connect, result)
    return stream
end

"Disconnect `stream` and return it."
function disconnect!(stream::Stream)
    result = lock(stream.state_lock) do
        handle = _require_open(stream)
        stream.connected || return Cint(0)
        result = LibPipeWire.pw_stream_disconnect(handle)
        result >= 0 && (stream.connected = false)
        result
    end
    _check_result(:pw_stream_disconnect, result)
    return stream
end

"Set whether `stream` is active and return it."
function set_active!(stream::Stream, active::Bool=true)
    _check_callback_error(stream)
    result = lock(stream.state_lock) do
        LibPipeWire.pw_stream_set_active(_require_open(stream), active)
    end
    _check_result(:pw_stream_set_active, result)
    return stream
end

"Flush queued buffers, optionally draining them first, and return `stream`."
function flush!(stream::Stream; drain::Bool=false)
    _check_callback_error(stream)
    result = lock(stream.state_lock) do
        LibPipeWire.pw_stream_flush(_require_open(stream), drain)
    end
    _check_result(:pw_stream_flush, result)
    return stream
end

"Request processing for a trigger-driven stream and return it."
function trigger_process!(stream::Stream)
    _check_callback_error(stream)
    result = lock(stream.state_lock) do
        LibPipeWire.pw_stream_trigger_process(_require_open(stream))
    end
    _check_result(:pw_stream_trigger_process, result)
    return stream
end

"""
    StreamBuffer

A dequeued, borrowed PipeWire stream buffer. Exactly one of
`queue_buffer!(buffer, stream)` or `return_buffer!(buffer, stream)` must be
called before the buffer can be dequeued again. Construct `StreamBuffer()` once
and use [`dequeue_buffer!`](@ref) to avoid allocations in a process callback.
"""
mutable struct StreamBuffer
    handle::Ptr{LibPipeWire.pw_buffer}
end

StreamBuffer() = StreamBuffer(Ptr{LibPipeWire.pw_buffer}(C_NULL))

function _require_available(buffer::StreamBuffer)
    buffer.handle == C_NULL &&
        throw(InvalidStateException("the PipeWire stream buffer was already returned", :returned))
    return buffer.handle
end

"""
    dequeue_buffer(stream) -> Union{Nothing,StreamBuffer}

Dequeue a buffer, returning `nothing` when none is available. This convenience
method allocates a wrapper; use [`dequeue_buffer!`](@ref) on hot paths.
"""
function dequeue_buffer(stream::Stream)
    _check_callback_error(stream)
    handle = lock(stream.state_lock) do
        LibPipeWire.pw_stream_dequeue_buffer(_require_open(stream))
    end
    return handle == C_NULL ? nothing : StreamBuffer(handle)
end

"""
    dequeue_buffer!(buffer::StreamBuffer, stream::Stream) -> Bool

Dequeue into a reusable buffer wrapper. Return `true` when a buffer was
available and `false` otherwise. This form avoids the wrapper allocation made
by [`dequeue_buffer`](@ref).
"""
function dequeue_buffer!(buffer::StreamBuffer, stream::Stream)
    buffer.handle == C_NULL || throw(
        InvalidStateException("the previous PipeWire stream buffer is still dequeued", :dequeued),
    )
    _check_callback_error(stream)
    handle = lock(stream.state_lock) do
        LibPipeWire.pw_stream_dequeue_buffer(_require_open(stream))
    end
    buffer.handle = handle
    return handle != C_NULL
end

function _return_stream_buffer!(operation, buffer::StreamBuffer, stream::Stream)
    handle = _require_available(buffer)
    result = lock(stream.state_lock) do
        _require_open(stream)
        operation(stream.handle, handle)
    end
    _check_result(
        operation === LibPipeWire.pw_stream_queue_buffer ?
        :pw_stream_queue_buffer : :pw_stream_return_buffer,
        result,
    )
    buffer.handle = Ptr{LibPipeWire.pw_buffer}(C_NULL)
    return stream
end

"Queue a dequeued buffer, clear its wrapper, and return `stream`."
queue_buffer!(buffer::StreamBuffer, stream::Stream) =
    _return_stream_buffer!(LibPipeWire.pw_stream_queue_buffer, buffer, stream)
"Return a dequeued buffer, clear its wrapper, and return `stream`."
return_buffer!(buffer::StreamBuffer, stream::Stream) =
    _return_stream_buffer!(LibPipeWire.pw_stream_return_buffer, buffer, stream)

"""A borrowed data plane belonging to a [`StreamBuffer`](@ref)."""
struct StreamData
    buffer::StreamBuffer
    index::Int
end

"Return a borrowed data-plane view from a dequeued stream buffer."
function buffer_data(buffer::StreamBuffer, index::Integer=1)
    native_buffer = unsafe_load(_require_available(buffer)).buffer
    native_buffer == C_NULL && throw(InvalidStateException("the stream buffer has no SPA buffer", :no_buffer))
    count = Int(unsafe_load(native_buffer).n_datas)
    1 <= index <= count || throw(BoundsError(1:count, index))
    return StreamData(buffer, Int(index))
end

function _native_data(data::StreamData)
    native_buffer = unsafe_load(_require_available(data.buffer)).buffer
    buffer = unsafe_load(native_buffer)
    return unsafe_load(buffer.datas, data.index)
end

"Return the writable capacity in bytes of a stream data plane."
capacity(data::StreamData) = Int(_native_data(data).maxsize)

"Return the native memory pointer for a stream data plane."
function data_pointer(data::StreamData)
    native = _native_data(data)
    native.data == C_NULL &&
        throw(InvalidStateException("the PipeWire data plane is not mapped", :unmapped))
    return Ptr{UInt8}(native.data)
end

function _chunk(data::StreamData)
    native = _native_data(data)
    native.chunk == C_NULL &&
        throw(InvalidStateException("the PipeWire data plane has no chunk", :no_chunk))
    return native, native.chunk, unsafe_load(native.chunk)
end

"Return a borrowed byte view of the current chunk in a stream data plane."
function bytes(data::StreamData)
    native, _, chunk = _chunk(data)
    pointer = data_pointer(data)
    offset = Int(chunk.offset % max(native.maxsize, UInt32(1)))
    size = min(Int(chunk.size), Int(native.maxsize) - offset)
    return unsafe_wrap(Vector{UInt8}, pointer + offset, size; own=false)
end

"Return a borrowed writable byte view spanning a stream data plane's capacity."
function writable_bytes(data::StreamData)
    native = _native_data(data)
    return unsafe_wrap(Vector{UInt8}, data_pointer(data), Int(native.maxsize); own=false)
end

"Set valid chunk bounds for a stream data plane and return `data`."
function set_chunk!(data::StreamData; offset::Integer=0, size::Integer, stride::Integer=0)
    native, pointer, chunk = _chunk(data)
    0 <= offset <= native.maxsize || throw(ArgumentError("chunk offset exceeds data capacity"))
    0 <= size <= native.maxsize - offset || throw(ArgumentError("chunk size exceeds data capacity"))
    unsafe_store!(
        pointer,
        LibPipeWire.spa_chunk(UInt32(offset), UInt32(size), Int32(stride), chunk.flags),
    )
    return data
end

function run!(stream::Stream)
    run!(main_loop(stream))
    _check_callback_error(stream)
    return nothing
end

quit!(stream::Stream) = quit!(main_loop(stream))
