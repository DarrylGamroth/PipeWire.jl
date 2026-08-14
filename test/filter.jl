using PipeWire
using Test

struct FilterProcessRecorder
    count::Base.RefValue{Int}
end

function (callback::FilterProcessRecorder)(
    ::Filter,
    position::Union{Nothing,FilterPosition},
)
    callback.count[] += position === nothing ? 2 : 1
    return nothing
end

struct FilterIORecorder
    port::Base.RefValue{Any}
    io::Base.RefValue{FilterIO}
end

function (callback::FilterIORecorder)(::Filter, port, io::FilterIO)
    callback.port[] = port
    callback.io[] = io
    return nothing
end

function invoke_filter_process(filter::T, position) where {T<:Filter}
    ccall(
        filter.events[].process,
        Cvoid,
        (Ref{T}, Ptr{PipeWire.LibPipeWire.spa_io_position}),
        filter,
        position,
    )
    return nothing
end

function filter_process_allocations(filter, position)
    invoke_filter_process(filter, position)
    nonnull = @allocated invoke_filter_process(filter, position)
    invoke_filter_process(filter, C_NULL)
    null = @allocated invoke_filter_process(filter, C_NULL)
    return nonnull, null
end

@testset "managed filter" begin
    context = Context()
    core = CoreConnection(context; self=true)
    process_count = Ref(0)
    io_port = Ref{Any}(nothing)
    io_event = Ref(FilterIO(0, C_NULL, 0))
    state_changes = Tuple{Int32,Int32,Union{Nothing,String}}[]
    param_changes = Tuple{Any,UInt32,Union{Nothing,Pod}}[]
    added_buffers = Tuple{Any,Ptr{PipeWire.LibPipeWire.pw_buffer}}[]
    removed_buffers = Tuple{Any,Ptr{PipeWire.LibPipeWire.pw_buffer}}[]
    commands = Pod[]
    drained = Ref(0)
    filter = Filter(
        core,
        "Julia managed filter";
        properties=Dict("media.name" => "filter tests"),
        on_state_changed=(filter, old, current, detail) ->
            push!(state_changes, (old, current, detail)),
        on_io_changed=FilterIORecorder(io_port, io_event),
        on_param_changed=(filter, port, id, param) ->
            push!(param_changes, (port, id, param)),
        on_buffer_added=(filter, port, buffer) ->
            push!(added_buffers, (port, buffer)),
        on_buffer_removed=(filter, port, buffer) ->
            push!(removed_buffers, (port, buffer)),
        on_process=FilterProcessRecorder(process_count),
        on_drained=filter -> (drained[] += 1),
        on_command=(filter, command) -> push!(commands, command),
    )
    position_storage = zeros(UInt8, sizeof(PipeWire.LibPipeWire.spa_io_position))
    position_pointer = Ptr{PipeWire.LibPipeWire.spa_io_position}(
        pointer(position_storage),
    )

    @test isopen(filter)
    @test main_loop(filter) === main_loop(core)
    @test filter_name(filter) == "Julia managed filter"
    @test filter_state(filter) == PipeWire.LibPipeWire.PW_FILTER_STATE_UNCONNECTED
    @test isbitstype(FilterPosition)
    @test sizeof(FilterPosition) == sizeof(Ptr{Cvoid})
    position = FilterPosition(position_pointer)
    @test position_snapshot(position).state == 0
    @test isconcretetype(typeof(filter))
    @test all(isconcretetype, fieldtypes(typeof(filter)))
    @test GC.@preserve position_storage filter_process_allocations(
        filter,
        position_pointer,
    ) == (0, 0)
    @test process_count[] == 6
    @test_throws InvalidStateException close(core)
    @test_throws ArgumentError Filter(core, "bad\0name")

    input_data = Ref(Int32(11))
    input = add_port!(
        filter,
        :input;
        data=input_data,
        flags=FILTER_PORT_MAP_BUFFERS,
        properties=Dict("port.name" => "input"),
        params=[audio_format()],
    )
    output = add_port!(
        filter,
        :output;
        data=(gain=1.0f0,),
        properties=Dict("port.name" => "output"),
        params=[audio_format()],
    )
    @test isopen(input)
    @test isopen(output)
    @test input.data === input_data
    @test input.direction == PipeWire.DIRECTION_INPUT
    @test output.direction == PipeWire.DIRECTION_OUTPUT
    @test isconcretetype(typeof(input))
    @test all(isconcretetype, fieldtypes(typeof(input)))
    @test PipeWire._filter_port(input.handle) === input
    @test PipeWire._filter_port(C_NULL) === nothing
    @test_throws ArgumentError add_port!(filter, :sideways)
    @test_throws ArgumentError add_port!(filter, :input; flags=-1)

    @test filter_properties(filter)["media.name"] == "filter tests"
    @test filter_properties(filter, input)["port.name"] == "input"
    @test update_properties!(filter, Dict("application.name" => "filter test")) === filter
    @test update_properties!(input, Dict("port.alias" => "filter input")) === input
    @test filter_properties(filter)["application.name"] == "filter test"
    @test filter_properties(filter, input)["port.alias"] == "filter input"
    @test update_params!(filter, Pod[]) === filter
    @test update_params!(input, [audio_format()]) === input

    area = Ref(UInt32(9))
    GC.@preserve filter input area PipeWire._filter_io_changed(
        filter,
        input.handle,
        UInt32(7),
        Base.unsafe_convert(Ptr{Cvoid}, area),
        UInt32(sizeof(UInt32)),
    )
    @test io_port[] === input
    @test io_event[].id == 7
    @test io_event[].area == Base.unsafe_convert(Ptr{Cvoid}, area)
    @test io_event[].size == sizeof(UInt32)

    param = audio_format()
    GC.@preserve filter input param PipeWire._filter_param_changed(
        filter,
        input.handle,
        UInt32(3),
        PipeWire._pod_pointer(param),
    )
    @test length(param_changes) == 1
    @test param_changes[1][1] === input
    @test param_changes[1][2] == 3
    @test param_changes[1][3] == param

    state_detail = "callback state"
    native_buffer_pointer = Ptr{PipeWire.LibPipeWire.pw_buffer}(1)
    GC.@preserve filter input state_detail begin
        PipeWire._filter_state_changed(
            filter,
            Int32(0),
            Int32(1),
            Cstring(pointer(state_detail)),
        )
        PipeWire._filter_buffer_added(
            filter,
            input.handle,
            native_buffer_pointer,
        )
        PipeWire._filter_buffer_removed(
            filter,
            input.handle,
            native_buffer_pointer,
        )
        PipeWire._filter_command(
            filter,
            Ptr{PipeWire.LibPipeWire.spa_command}(PipeWire._pod_pointer(param)),
        )
        PipeWire._filter_drained(filter)
    end
    @test state_changes == [(Int32(0), Int32(1), "callback state")]
    @test added_buffers == [(input, native_buffer_pointer)]
    @test removed_buffers == [(input, native_buffer_pointer)]
    @test commands == [param]
    @test drained[] == 1

    @test dequeue_buffer(input) === nothing
    reusable = FilterBuffer()
    @test all(isconcretetype, fieldtypes(typeof(reusable)))
    @test !dequeue_buffer!(reusable, input)
    @test reusable.handle == C_NULL
    @test reusable.port_data == C_NULL
    wrong_port = FilterBuffer(Ptr{PipeWire.LibPipeWire.pw_buffer}(1), input.handle)
    @test_throws ArgumentError queue_buffer!(wrong_port, output)
    @test dsp_buffer(input, Float32, 0) == C_NULL
    @test_throws ArgumentError dsp_buffer(input, Float32, -1)

    @test_throws ArgumentError connect!(
        filter;
        flags=PipeWire.LibPipeWire.PW_FILTER_FLAG_RT_PROCESS,
    )
    @test_throws ArgumentError connect!(filter; flags=-1)
    @test connect!(filter) === filter
    @test_throws InvalidStateException connect!(filter)
    @test filter_state(filter) == PipeWire.LibPipeWire.PW_FILTER_STATE_CONNECTING
    @test node_id(filter) isa UInt32
    @test is_driving(filter) isa Bool
    @test is_lazy(filter) isa Bool
    @test filter_nsec(filter) isa UInt64
    @test disconnect!(filter) === filter
    @test disconnect!(filter) === filter

    @test remove_port!(input) === filter
    @test !isopen(input)
    @test_throws InvalidStateException remove_port!(input)
    close(filter)
    @test !isopen(filter)
    @test !isopen(output)
    @test_throws InvalidStateException filter_state(filter)
    close(filter)
    close(core)
    close(context)
end

@testset "filter error state" begin
    context = Context()
    core = CoreConnection(context; self=true)
    filter = Filter(core, "error filter")
    @test_throws ArgumentError set_error!(filter, 1, "not negative")
    @test_throws ArgumentError set_error!(filter, -1, "bad\0message")
    @test set_error!(filter, -5, "filter test error") === filter
    error = try
        filter_state(filter)
        nothing
    catch caught
        caught
    end
    @test error isa PipeWireError
    @test error.code == -5
    @test error.detail == "filter test error"
    close(filter)
    close(core)
    close(context)
end

@testset "filter buffer data" begin
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
    buffer = FilterBuffer(
        Base.unsafe_convert(Ptr{PipeWire.LibPipeWire.pw_buffer}, native_buffer),
        C_NULL,
    )
    GC.@preserve storage chunk native_data spa_buffer native_buffer begin
        data = buffer_data(buffer)
        @test data isa FilterData
        @test capacity(data) == 16
        @test data_pointer(data) == pointer(storage)
        @test bytes(data) == UInt8[3, 4, 5, 6]
        @test writable_bytes(data) == storage
        @test set_chunk!(data; offset=1, size=8, stride=4) === data
        @test chunk[].offset == 1
        @test chunk[].size == 8
        @test chunk[].stride == 4
        @test_throws BoundsError buffer_data(buffer, 2)
        @test_throws ArgumentError set_chunk!(data; offset=0, size=17)
    end
end
