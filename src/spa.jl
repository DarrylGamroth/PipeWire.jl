"SPA POD value types that need wrappers to preserve their wire-level meaning."
module SPA

export Bytes, Fd, Fraction, Id, Rectangle

"An enumerated SPA POD ID."
struct Id
    value::UInt32

    function Id(value::Integer)
        0 <= value <= typemax(UInt32) ||
            throw(ArgumentError("SPA ID is outside UInt32 range"))
        return new(UInt32(value))
    end
end

"A file descriptor value carried by an SPA POD."
struct Fd
    value::Int64

    function Fd(value::Integer)
        typemin(Int64) <= value <= typemax(Int64) ||
            throw(ArgumentError("SPA file descriptor is outside Int64 range"))
        return new(Int64(value))
    end
end

"An owned byte sequence carried by an SPA POD."
struct Bytes
    data::Vector{UInt8}

    Bytes(data) = new(Vector{UInt8}(data))
end

Base.:(==)(left::Bytes, right::Bytes) = left.data == right.data
Base.isequal(left::Bytes, right::Bytes) = isequal(left.data, right.data)
Base.hash(value::Bytes, seed::UInt) = hash(value.data, seed)

"A width and height carried by an SPA POD."
struct Rectangle
    width::UInt32
    height::UInt32

    function Rectangle(width::Integer, height::Integer)
        0 <= width <= typemax(UInt32) ||
            throw(ArgumentError("SPA rectangle width is outside UInt32 range"))
        0 <= height <= typemax(UInt32) ||
            throw(ArgumentError("SPA rectangle height is outside UInt32 range"))
        return new(UInt32(width), UInt32(height))
    end
end

"A numerator and denominator carried by an SPA POD."
struct Fraction
    num::UInt32
    denom::UInt32

    function Fraction(num::Integer, denom::Integer)
        0 <= num <= typemax(UInt32) ||
            throw(ArgumentError("SPA fraction numerator is outside UInt32 range"))
        0 <= denom <= typemax(UInt32) ||
            throw(ArgumentError("SPA fraction denominator is outside UInt32 range"))
        return new(UInt32(num), UInt32(denom))
    end
end

end # module SPA

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

"Return the SPA type ID stored in an owned POD header."
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

function _pod_from_body(type::UInt32, body)
    length(body) <= typemax(UInt32) || throw(ArgumentError("the SPA POD body is too large"))
    data = UInt8[]
    _append_bits!(data, UInt32(length(body)))
    _append_bits!(data, type)
    append!(data, body)
    return Pod(data)
end

function _scalar_pod(type::UInt32, value::T) where {T}
    data = UInt8[]
    _append_bits!(data, UInt32(sizeof(T)))
    _append_bits!(data, type)
    _append_bits!(data, value)
    return Pod(data)
end

Pod(::Nothing) = _pod_from_body(UInt32(LibPipeWire.SPA_TYPE_None), UInt8[])
Pod(value::Bool) =
    _scalar_pod(UInt32(LibPipeWire.SPA_TYPE_Bool), value ? Int32(1) : Int32(0))
Pod(value::SPA.Id) = _scalar_pod(UInt32(LibPipeWire.SPA_TYPE_Id), value.value)
Pod(value::Int32) = _scalar_pod(UInt32(LibPipeWire.SPA_TYPE_Int), value)
Pod(value::Int64) = _scalar_pod(UInt32(LibPipeWire.SPA_TYPE_Long), value)
Pod(value::Float32) = _scalar_pod(UInt32(LibPipeWire.SPA_TYPE_Float), value)
Pod(value::Float64) = _scalar_pod(UInt32(LibPipeWire.SPA_TYPE_Double), value)
Pod(value::SPA.Bytes) = _pod_from_body(UInt32(LibPipeWire.SPA_TYPE_Bytes), value.data)
Pod(value::SPA.Fd) = _scalar_pod(UInt32(LibPipeWire.SPA_TYPE_Fd), value.value)

function Pod(value::AbstractString)
    string = _validate_c_string(String(value), "SPA string")
    body = Vector{UInt8}(codeunits(string))
    push!(body, 0)
    return _pod_from_body(UInt32(LibPipeWire.SPA_TYPE_String), body)
end

function Pod(value::SPA.Rectangle)
    body = UInt8[]
    _append_bits!(body, value.width)
    _append_bits!(body, value.height)
    return _pod_from_body(UInt32(LibPipeWire.SPA_TYPE_Rectangle), body)
end

function Pod(value::SPA.Fraction)
    body = UInt8[]
    _append_bits!(body, value.num)
    _append_bits!(body, value.denom)
    return _pod_from_body(UInt32(LibPipeWire.SPA_TYPE_Fraction), body)
end

function _check_pod_body(pod::Pod, expected_type::UInt32, expected_size::Integer)
    actual_type = pod_type(pod)
    actual_type == expected_type || throw(
        ArgumentError("expected SPA POD type $expected_type, received $actual_type"),
    )
    data = pod.data
    body_size = length(data) - sizeof(LibPipeWire.spa_pod)
    body_size == expected_size || throw(
        ArgumentError("expected SPA POD body size $expected_size, received $body_size"),
    )
    return nothing
end

function _pod_body_pointer(pod::Pod, expected_type::UInt32, expected_size::Integer)
    _check_pod_body(pod, expected_type, expected_size)
    data = pod.data
    return pointer(data) + sizeof(LibPipeWire.spa_pod)
end

function _pod_scalar(::Type{T}, pod::Pod, expected_type::UInt32) where {T}
    data = pod.data
    return GC.@preserve data unsafe_load(
        Ptr{T}(_pod_body_pointer(pod, expected_type, sizeof(T))),
    )
end

"""
    pod_value(T, pod::Pod) -> T
    pod_value(pod::Pod)

Return the owned value stored in a scalar SPA POD. Supplying `T` gives a
type-stable result and validates that the POD has the corresponding wire type.
The one-argument form selects `T` from [`pod_type`](@ref). Container PODs are
not yet decoded by this method.
"""
function pod_value(::Type{Nothing}, pod::Pod)
    _check_pod_body(pod, UInt32(LibPipeWire.SPA_TYPE_None), 0)
    return nothing
end

function pod_value(::Type{Bool}, pod::Pod)
    return _pod_scalar(Int32, pod, UInt32(LibPipeWire.SPA_TYPE_Bool)) != 0
end

pod_value(::Type{SPA.Id}, pod::Pod) =
    SPA.Id(_pod_scalar(UInt32, pod, UInt32(LibPipeWire.SPA_TYPE_Id)))
pod_value(::Type{Int32}, pod::Pod) =
    _pod_scalar(Int32, pod, UInt32(LibPipeWire.SPA_TYPE_Int))
pod_value(::Type{Int64}, pod::Pod) =
    _pod_scalar(Int64, pod, UInt32(LibPipeWire.SPA_TYPE_Long))
pod_value(::Type{Float32}, pod::Pod) =
    _pod_scalar(Float32, pod, UInt32(LibPipeWire.SPA_TYPE_Float))
pod_value(::Type{Float64}, pod::Pod) =
    _pod_scalar(Float64, pod, UInt32(LibPipeWire.SPA_TYPE_Double))
pod_value(::Type{SPA.Fd}, pod::Pod) =
    SPA.Fd(_pod_scalar(Int64, pod, UInt32(LibPipeWire.SPA_TYPE_Fd)))

function pod_value(::Type{String}, pod::Pod)
    data = pod.data
    body_size = length(data) - sizeof(LibPipeWire.spa_pod)
    _check_pod_body(pod, UInt32(LibPipeWire.SPA_TYPE_String), body_size)
    body_size > 0 || throw(ArgumentError("an SPA string POD must contain a terminator"))
    body = @view data[(sizeof(LibPipeWire.spa_pod) + 1):end]
    body[end] == 0 || throw(ArgumentError("an SPA string POD is not null terminated"))
    findfirst(iszero, body) == lastindex(body) ||
        throw(ArgumentError("an SPA string POD contains an embedded null"))
    return String(body[begin:(end - 1)])
end

function pod_value(::Type{SPA.Bytes}, pod::Pod)
    data = pod.data
    body_size = length(data) - sizeof(LibPipeWire.spa_pod)
    _check_pod_body(pod, UInt32(LibPipeWire.SPA_TYPE_Bytes), body_size)
    return SPA.Bytes(@view data[(sizeof(LibPipeWire.spa_pod) + 1):end])
end

function pod_value(::Type{SPA.Rectangle}, pod::Pod)
    data = pod.data
    return GC.@preserve data begin
        pointer = _pod_body_pointer(
            pod,
            UInt32(LibPipeWire.SPA_TYPE_Rectangle),
            2 * sizeof(UInt32),
        )
        SPA.Rectangle(
            unsafe_load(Ptr{UInt32}(pointer)),
            unsafe_load(Ptr{UInt32}(pointer + sizeof(UInt32))),
        )
    end
end

function pod_value(::Type{SPA.Fraction}, pod::Pod)
    data = pod.data
    return GC.@preserve data begin
        pointer = _pod_body_pointer(
            pod,
            UInt32(LibPipeWire.SPA_TYPE_Fraction),
            2 * sizeof(UInt32),
        )
        SPA.Fraction(
            unsafe_load(Ptr{UInt32}(pointer)),
            unsafe_load(Ptr{UInt32}(pointer + sizeof(UInt32))),
        )
    end
end

function pod_value(pod::Pod)
    type = pod_type(pod)
    type == LibPipeWire.SPA_TYPE_None && return pod_value(Nothing, pod)
    type == LibPipeWire.SPA_TYPE_Bool && return pod_value(Bool, pod)
    type == LibPipeWire.SPA_TYPE_Id && return pod_value(SPA.Id, pod)
    type == LibPipeWire.SPA_TYPE_Int && return pod_value(Int32, pod)
    type == LibPipeWire.SPA_TYPE_Long && return pod_value(Int64, pod)
    type == LibPipeWire.SPA_TYPE_Float && return pod_value(Float32, pod)
    type == LibPipeWire.SPA_TYPE_Double && return pod_value(Float64, pod)
    type == LibPipeWire.SPA_TYPE_String && return pod_value(String, pod)
    type == LibPipeWire.SPA_TYPE_Bytes && return pod_value(SPA.Bytes, pod)
    type == LibPipeWire.SPA_TYPE_Rectangle && return pod_value(SPA.Rectangle, pod)
    type == LibPipeWire.SPA_TYPE_Fraction && return pod_value(SPA.Fraction, pod)
    type == LibPipeWire.SPA_TYPE_Fd && return pod_value(SPA.Fd, pod)
    throw(ArgumentError("SPA POD type $type is not a supported scalar value"))
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
