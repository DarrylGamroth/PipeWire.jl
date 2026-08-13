"""
Audio sample formats and channel positions used by [`audio_format`](@ref).

For example, `Audio.F32` is native-endian 32-bit floating-point audio and
`Audio.FL`/`Audio.FR` are the front-left and front-right channel positions.
"""
module Audio

using ..LibPipeWire

@enum Format::UInt32 begin
    UNKNOWN = LibPipeWire.SPA_AUDIO_FORMAT_UNKNOWN
    S8 = LibPipeWire.SPA_AUDIO_FORMAT_S8
    U8 = LibPipeWire.SPA_AUDIO_FORMAT_U8
    S16 = LibPipeWire.SPA_AUDIO_FORMAT_S16
    S24 = LibPipeWire.SPA_AUDIO_FORMAT_S24
    S32 = LibPipeWire.SPA_AUDIO_FORMAT_S32
    F32 = LibPipeWire.SPA_AUDIO_FORMAT_F32
    F64 = LibPipeWire.SPA_AUDIO_FORMAT_F64
    U8P = LibPipeWire.SPA_AUDIO_FORMAT_U8P
    S16P = LibPipeWire.SPA_AUDIO_FORMAT_S16P
    S24P = LibPipeWire.SPA_AUDIO_FORMAT_S24P
    S32P = LibPipeWire.SPA_AUDIO_FORMAT_S32P
    F32P = LibPipeWire.SPA_AUDIO_FORMAT_F32P
    F64P = LibPipeWire.SPA_AUDIO_FORMAT_F64P
end

@enum Channel::UInt32 begin
    CHANNEL_UNKNOWN = LibPipeWire.SPA_AUDIO_CHANNEL_UNKNOWN
    NA = LibPipeWire.SPA_AUDIO_CHANNEL_NA
    MONO = LibPipeWire.SPA_AUDIO_CHANNEL_MONO
    FL = LibPipeWire.SPA_AUDIO_CHANNEL_FL
    FR = LibPipeWire.SPA_AUDIO_CHANNEL_FR
    FC = LibPipeWire.SPA_AUDIO_CHANNEL_FC
    LFE = LibPipeWire.SPA_AUDIO_CHANNEL_LFE
    SL = LibPipeWire.SPA_AUDIO_CHANNEL_SL
    SR = LibPipeWire.SPA_AUDIO_CHANNEL_SR
    RL = LibPipeWire.SPA_AUDIO_CHANNEL_RL
    RR = LibPipeWire.SPA_AUDIO_CHANNEL_RR
end

end # module Audio

"""
    Pod(data)

An owned SPA POD value. The constructor copies `data` and validates the POD
header. `Pod` values keep format parameters alive while they are passed to
PipeWire.
"""
struct Pod
    data::Vector{UInt8}

    function Pod(data::AbstractVector{UInt8})
        length(data) >= sizeof(LibPipeWire.spa_pod) ||
            throw(ArgumentError("an SPA POD must contain a complete header"))
        owned = Vector{UInt8}(data)
        header = GC.@preserve owned unsafe_load(Ptr{LibPipeWire.spa_pod}(pointer(owned)))
        total_size = sizeof(LibPipeWire.spa_pod) + Int(header.size)
        total_size <= length(owned) || throw(ArgumentError("the SPA POD body is truncated"))
        resize!(owned, total_size)
        return new(owned)
    end
end

Base.sizeof(pod::Pod) = length(pod.data)

function pod_type(pod::Pod)
    data = pod.data
    return GC.@preserve data unsafe_load(Ptr{LibPipeWire.spa_pod}(pointer(data))).type
end

function _pod_pointer(pod::Pod)
    return Ptr{LibPipeWire.spa_pod}(pointer(pod.data))
end

function _copy_pod(pointer::Ptr{LibPipeWire.spa_pod})
    pointer == C_NULL && return nothing
    header = unsafe_load(pointer)
    total_size = sizeof(LibPipeWire.spa_pod) + Int(header.size)
    total_size <= (1 << 20) || throw(ArgumentError("the SPA POD exceeds its maximum size"))
    data = copy(unsafe_wrap(Vector{UInt8}, Ptr{UInt8}(pointer), total_size; own=false))
    return Pod(data)
end

function _append_bits!(data::Vector{UInt8}, value::T) where {T}
    bytes = reinterpret(UInt8, [value])
    append!(data, bytes)
    return data
end

function _pad_pod!(data::Vector{UInt8})
    append!(data, zeros(UInt8, mod(-length(data), 8)))
    return data
end

function _pod_property!(data, key::UInt32, type::UInt32, value::UInt32)
    _append_bits!(data, key)
    _append_bits!(data, UInt32(0))
    _append_bits!(data, UInt32(sizeof(value)))
    _append_bits!(data, type)
    _append_bits!(data, value)
    return _pad_pod!(data)
end

function _pod_int_property!(data, key::UInt32, value::Integer)
    typemin(Int32) <= value <= typemax(Int32) ||
        throw(ArgumentError("the SPA integer property is outside Int32 range"))
    _append_bits!(data, key)
    _append_bits!(data, UInt32(0))
    _append_bits!(data, UInt32(sizeof(Int32)))
    _append_bits!(data, UInt32(LibPipeWire.SPA_TYPE_Int))
    _append_bits!(data, Int32(value))
    return _pad_pod!(data)
end

function _pod_id_array_property!(data, key::UInt32, values)
    _append_bits!(data, key)
    _append_bits!(data, UInt32(0))
    _append_bits!(data, UInt32(8 + sizeof(UInt32) * length(values)))
    _append_bits!(data, UInt32(LibPipeWire.SPA_TYPE_Array))
    _append_bits!(data, UInt32(sizeof(UInt32)))
    _append_bits!(data, UInt32(LibPipeWire.SPA_TYPE_Id))
    for value in values
        _append_bits!(data, UInt32(value))
    end
    return _pad_pod!(data)
end

function _set_pod_body_size!(data::Vector{UInt8})
    body_size = UInt32(length(data) - sizeof(LibPipeWire.spa_pod))
    GC.@preserve data unsafe_store!(Ptr{UInt32}(pointer(data)), body_size)
    return data
end

"""
    audio_format(; format=Audio.F32, rate=48000, channels=2,
                   position=nothing, id=SPA_PARAM_EnumFormat) -> Pod

Build a fixed raw-audio SPA format parameter. When `position` is omitted,
mono and stereo channel positions are supplied automatically; formats with
more channels are left unpositioned unless positions are given explicitly.
"""
function audio_format(;
    format::Audio.Format=Audio.F32,
    rate::Integer=48_000,
    channels::Integer=2,
    position=nothing,
    id::Integer=LibPipeWire.SPA_PARAM_EnumFormat,
)
    rate > 0 || throw(ArgumentError("audio sample rate must be positive"))
    channels > 0 || throw(ArgumentError("audio channel count must be positive"))
    channels <= 64 || throw(ArgumentError("at most 64 audio channels are supported"))

    positions = if position === nothing
        channels == 1 ? Audio.Channel[Audio.MONO] :
        channels == 2 ? Audio.Channel[Audio.FL, Audio.FR] : Audio.Channel[]
    else
        Audio.Channel[
            value isa Audio.Channel ? value : Audio.Channel(value) for value in position
        ]
    end
    isempty(positions) || length(positions) == channels || throw(
        ArgumentError("the number of audio channel positions must equal channels"),
    )

    data = UInt8[]
    _append_bits!(data, UInt32(0))
    _append_bits!(data, UInt32(LibPipeWire.SPA_TYPE_Object))
    _append_bits!(data, UInt32(LibPipeWire.SPA_TYPE_OBJECT_Format))
    _append_bits!(data, UInt32(id))
    _pod_property!(
        data,
        UInt32(LibPipeWire.SPA_FORMAT_mediaType),
        UInt32(LibPipeWire.SPA_TYPE_Id),
        UInt32(LibPipeWire.SPA_MEDIA_TYPE_audio),
    )
    _pod_property!(
        data,
        UInt32(LibPipeWire.SPA_FORMAT_mediaSubtype),
        UInt32(LibPipeWire.SPA_TYPE_Id),
        UInt32(LibPipeWire.SPA_MEDIA_SUBTYPE_raw),
    )
    _pod_property!(
        data,
        UInt32(LibPipeWire.SPA_FORMAT_AUDIO_format),
        UInt32(LibPipeWire.SPA_TYPE_Id),
        UInt32(format),
    )
    _pod_int_property!(data, UInt32(LibPipeWire.SPA_FORMAT_AUDIO_rate), rate)
    _pod_int_property!(data, UInt32(LibPipeWire.SPA_FORMAT_AUDIO_channels), channels)
    isempty(positions) || _pod_id_array_property!(
        data,
        UInt32(LibPipeWire.SPA_FORMAT_AUDIO_position),
        positions,
    )
    _set_pod_body_size!(data)
    return Pod(data)
end
