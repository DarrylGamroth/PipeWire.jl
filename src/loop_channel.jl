struct _LoopChannelDrain{T,Callback}
    channel::Channel{T}
    callback::Callback
end

function (drain::_LoopChannelDrain)(source::EventSource, count::UInt64)
    remaining = count
    while remaining > 0
        item = take!(drain.channel)
        drain.callback(source, item)
        remaining -= 1
    end
    return nothing
end

"""
    LoopChannel{T}(loop, callback; capacity=32)

Create a bounded, typed channel into a PipeWire loop. Calling `put!(channel,
item)` from a Julia task queues `item`, wakes the loop, and invokes
`callback(event_source, item)` in the loop context.

The queue applies back pressure when it reaches `capacity`. Its element type,
callback type, event-source type, and loop type are all represented concretely
in the resulting object.
"""
mutable struct LoopChannel{T,ChannelType<:Channel{T},SourceType<:EventSource}
    channel::ChannelType
    source::SourceType
end

function LoopChannel{T}(
    loop::AbstractPipeWireLoop,
    callback;
    capacity::Integer=32,
) where {T}
    0 < capacity <= typemax(Int) ||
        throw(ArgumentError("loop channel capacity must be a positive Int"))
    queue = Channel{T}(Int(capacity))
    source = try
        EventSource(loop, _LoopChannelDrain(queue, callback))
    catch
        close(queue)
        rethrow()
    end
    return LoopChannel(queue, source)
end

function Base.isopen(channel::LoopChannel)
    return isopen(channel.channel) && isopen(channel.source)
end

function Base.put!(channel::LoopChannel{T}, item) where {T}
    _check_source_callback_error(channel.source)
    put!(channel.channel, convert(T, item))
    try
        signal!(channel.source)
    catch
        # The item cannot be removed safely if another producer has queued work.
        # Closing the queue wakes blocked producers and makes the failure terminal.
        close(channel.channel)
        rethrow()
    end
    return channel
end

function Base.close(channel::LoopChannel)
    close(channel.source)
    close(channel.channel)
    return nothing
end
