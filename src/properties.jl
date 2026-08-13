"""
    Properties([entries])

An owning PipeWire property dictionary. `Properties` implements the mutable
`AbstractDict{String,String}` interface and releases its native storage with
[`close`](@ref). Constructors and methods copy their string arguments.
"""
mutable struct Properties <: AbstractDict{String,String}
    handle::Ptr{LibPipeWire.pw_properties}
    state_lock::ReentrantLock
end

function _validate_c_string(value::String, kind::AbstractString)
    contains(value, '\0') && throw(ArgumentError("a PipeWire $kind cannot contain NUL"))
    return value
end

function _new_properties(entries)
    pairs = Pair{String,String}[
        _validate_c_string(String(key), "property key") =>
            _validate_c_string(String(value), "property value") for (key, value) in entries
    ]
    sort!(pairs; by=first)
    keys = first.(pairs)
    values = last.(pairs)
    items = Vector{LibPipeWire.spa_dict_item}(undef, length(pairs))

    handle = GC.@preserve keys values items begin
        for index in eachindex(items)
            items[index] = LibPipeWire.spa_dict_item(pointer(keys[index]), pointer(values[index]))
        end
        dictionary = Ref(
            LibPipeWire.spa_dict(
                UInt32(1), # SPA_DICT_FLAG_SORTED
                UInt32(length(items)),
                pointer(items),
            ),
        )
        GC.@preserve dictionary begin
            LibPipeWire.pw_properties_new_dict(
                Base.unsafe_convert(Ptr{LibPipeWire.spa_dict}, dictionary),
            )
        end
    end
    handle == C_NULL && throw(PipeWireError(:pw_properties_new_dict, -Base.Libc.errno()))

    properties = Properties(handle, ReentrantLock())
    finalizer(close, properties)
    return properties
end

Properties() = _new_properties(())
Properties(entries) = _new_properties(entries)

function Properties(serialized::AbstractString)
    input = _validate_c_string(String(serialized), "property serialization")
    handle = GC.@preserve input LibPipeWire.pw_properties_new_string(pointer(input))
    handle == C_NULL && throw(PipeWireError(:pw_properties_new_string, -Base.Libc.errno()))
    properties = Properties(handle, ReentrantLock())
    finalizer(close, properties)
    return properties
end

function _require_open(properties::Properties)
    properties.handle == C_NULL &&
        throw(InvalidStateException("the PipeWire properties are closed", :closed))
    return properties.handle
end

function Base.isopen(properties::Properties)
    return lock(properties.state_lock) do
        properties.handle != C_NULL
    end
end

function Base.close(properties::Properties)
    handle = lock(properties.state_lock) do
        properties.handle == C_NULL && return C_NULL
        handle = properties.handle
        properties.handle = Ptr{LibPipeWire.pw_properties}(C_NULL)
        return handle
    end
    handle == C_NULL || LibPipeWire.pw_properties_free(handle)
    return nothing
end

function _copy_properties_dict(properties::Properties)
    handle = lock(properties.state_lock) do
        _require_open(properties)
    end
    native = unsafe_load(handle)
    dictionary = Ref(native.dict)
    return GC.@preserve dictionary _copy_properties(
        Base.unsafe_convert(Ptr{LibPipeWire.spa_dict}, dictionary),
    )
end

function _copy_native_properties(properties::Properties)
    handle = lock(properties.state_lock) do
        LibPipeWire.pw_properties_copy(_require_open(properties))
    end
    handle == C_NULL && throw(PipeWireError(:pw_properties_copy, -Base.Libc.errno()))
    return handle
end

function _owned_native_properties(properties)
    properties === nothing && return Ptr{LibPipeWire.pw_properties}(C_NULL)
    properties isa Properties && return _copy_native_properties(properties)

    temporary = Properties(properties)
    return lock(temporary.state_lock) do
        handle = _require_open(temporary)
        temporary.handle = Ptr{LibPipeWire.pw_properties}(C_NULL)
        return handle
    end
end

Base.length(properties::Properties) = length(_copy_properties_dict(properties))
Base.eltype(::Type{Properties}) = Pair{String,String}
Base.IteratorSize(::Type{Properties}) = Base.HasLength()

function Base.iterate(properties::Properties)
    entries = collect(_copy_properties_dict(properties))
    item = iterate(entries)
    item === nothing && return nothing
    value, next = item
    return value, (entries, next)
end

function Base.iterate(::Properties, state)
    entries, next = state
    item = iterate(entries, next)
    item === nothing && return nothing
    value, following = item
    return value, (entries, following)
end

function Base.getindex(properties::Properties, key::AbstractString)
    key_string = _validate_c_string(String(key), "property key")
    value = lock(properties.state_lock) do
        value_pointer = GC.@preserve key_string LibPipeWire.pw_properties_get(
            _require_open(properties),
            pointer(key_string),
        )
        value_pointer == C_NULL ? nothing : unsafe_string(value_pointer)
    end
    value === nothing && throw(KeyError(key))
    return value
end

function Base.get(properties::Properties, key::AbstractString, default)
    key_string = _validate_c_string(String(key), "property key")
    value = lock(properties.state_lock) do
        value_pointer = GC.@preserve key_string LibPipeWire.pw_properties_get(
            _require_open(properties),
            pointer(key_string),
        )
        value_pointer == C_NULL ? nothing : unsafe_string(value_pointer)
    end
    return value === nothing ? default : value
end

Base.haskey(properties::Properties, key::AbstractString) =
    get(properties, key, nothing) !== nothing

function Base.setindex!(properties::Properties, value::AbstractString, key::AbstractString)
    key_string = _validate_c_string(String(key), "property key")
    value_string = _validate_c_string(String(value), "property value")
    result = lock(properties.state_lock) do
        GC.@preserve key_string value_string LibPipeWire.pw_properties_set(
            _require_open(properties),
            pointer(key_string),
            pointer(value_string),
        )
    end
    _check_result(:pw_properties_set, result)
    return properties
end

function Base.delete!(properties::Properties, key::AbstractString)
    key_string = _validate_c_string(String(key), "property key")
    result = lock(properties.state_lock) do
        GC.@preserve key_string LibPipeWire.pw_properties_set(
            _require_open(properties),
            pointer(key_string),
            C_NULL,
        )
    end
    _check_result(:pw_properties_set, result)
    return properties
end

function Base.empty!(properties::Properties)
    lock(properties.state_lock) do
        LibPipeWire.pw_properties_clear(_require_open(properties))
    end
    return properties
end

function Base.copy(properties::Properties)
    handle = _copy_native_properties(properties)
    result = Properties(handle, ReentrantLock())
    finalizer(close, result)
    return result
end

function Base.show(io::IO, properties::Properties)
    isopen(properties) || return print(io, "Properties(closed)")
    return print(io, "Properties(", repr(_copy_properties_dict(properties)), ')')
end
