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
"Enable explicit stream processing triggers."
const STREAM_TRIGGER = LibPipeWire.PW_STREAM_FLAG_TRIGGER
const _PW_ID_ANY = typemax(UInt32)

"""
    Stream(core, name; properties=nothing, on_state_changed=nothing,
           on_param_changed=nothing, on_process=nothing,
           on_buffer_added=nothing, on_buffer_removed=nothing,
           on_drained=nothing)

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

function _stream_events(::T) where {T<:Stream}
    state_changed = @cfunction(
        _stream_state_changed,
        Cvoid,
        (Ref{T}, Int32, Int32, Cstring),
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
    return LibPipeWire.pw_stream_events(
        UInt32(2),
        _NULL_CALLBACK,
        state_changed,
        _NULL_CALLBACK,
        _NULL_CALLBACK,
        param_changed,
        buffer_added,
        buffer_removed,
        process,
        drained,
        _NULL_CALLBACK,
        _NULL_CALLBACK,
    )
end

function Stream(
    core::CoreConnection,
    name::AbstractString;
    properties=nothing,
    on_state_changed=nothing,
    on_param_changed=nothing,
    on_process=nothing,
    on_buffer_added=nothing,
    on_buffer_removed=nothing,
    on_drained=nothing,
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
        on_param_changed=on_param_changed,
        on_process=on_process,
        on_buffer_added=on_buffer_added,
        on_buffer_removed=on_buffer_removed,
        on_drained=on_drained,
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
    target_id = UInt32(target)
    native_flags = UInt32(flags)
    native_flags & LibPipeWire.PW_STREAM_FLAG_RT_PROCESS == 0 || throw(
        ArgumentError(
            "Julia stream callbacks are not hard-real-time safe; RT_PROCESS is unsupported",
        ),
    )
    native_params = Pod[pod for pod in params]
    param_pointers = Ptr{LibPipeWire.spa_pod}[_pod_pointer(pod) for pod in native_params]
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
