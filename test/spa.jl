using PipeWire
using Test

function pod_value_allocations(::Type{T}, pod) where {T}
    pod_value(T, pod)
    return @allocated pod_value(T, pod)
end


@testset "scalar SPA POD values" begin
    scalar_values = (
        (Nothing, nothing, PipeWire.LibPipeWire.SPA_TYPE_None),
        (Bool, true, PipeWire.LibPipeWire.SPA_TYPE_Bool),
        (Bool, false, PipeWire.LibPipeWire.SPA_TYPE_Bool),
        (SPA.Id, SPA.Id(17), PipeWire.LibPipeWire.SPA_TYPE_Id),
        (Int32, Int32(-123), PipeWire.LibPipeWire.SPA_TYPE_Int),
        (Int64, Int64(1) << 40, PipeWire.LibPipeWire.SPA_TYPE_Long),
        (Float32, 1.25f0, PipeWire.LibPipeWire.SPA_TYPE_Float),
        (Float64, -2.5, PipeWire.LibPipeWire.SPA_TYPE_Double),
        (String, "PipeWire ✓", PipeWire.LibPipeWire.SPA_TYPE_String),
        (SPA.Bytes, SPA.Bytes(UInt8[0x00, 0x7f, 0xff]), PipeWire.LibPipeWire.SPA_TYPE_Bytes),
        (SPA.Fd, SPA.Fd(-1), PipeWire.LibPipeWire.SPA_TYPE_Fd),
        (
            SPA.Rectangle,
            SPA.Rectangle(1_920, 1_080),
            PipeWire.LibPipeWire.SPA_TYPE_Rectangle,
        ),
        (
            SPA.Fraction,
            SPA.Fraction(30_000, 1_001),
            PipeWire.LibPipeWire.SPA_TYPE_Fraction,
        ),
    )

    for (value_type, value, wire_type) in scalar_values
        pod = Pod(value)
        @test pod_type(pod) == wire_type
        @test pod_value(value_type, pod) == value
        @test pod_value(pod) == value
    end

    for value_type in (SPA.Id, SPA.Fd, SPA.Bytes, SPA.Rectangle, SPA.Fraction)
        @test isconcretetype(value_type)
        @test all(isconcretetype, fieldtypes(value_type))
    end
    @test all(isbitstype, (SPA.Id, SPA.Fd, SPA.Rectangle, SPA.Fraction))

    bytes_source = UInt8[1, 2, 3]
    bytes_value = SPA.Bytes(bytes_source)
    bytes_source[1] = 9
    @test bytes_value == SPA.Bytes(UInt8[1, 2, 3])
    @test isequal(bytes_value, SPA.Bytes(UInt8[1, 2, 3]))
    @test hash(bytes_value) == hash(SPA.Bytes(UInt8[1, 2, 3]))

    int_pod = Pod(Int32(-7))
    rectangle_pod = Pod(SPA.Rectangle(640, 480))
    @test @inferred(pod_value(Int32, int_pod)) == -7
    @test @inferred(pod_value(SPA.Rectangle, rectangle_pod)) == SPA.Rectangle(640, 480)
    @test pod_value_allocations(Int32, int_pod) == 0
    @test pod_value_allocations(SPA.Rectangle, rectangle_pod) == 0

    @test_throws ArgumentError pod_value(Int32, Pod(true))
    @test_throws ArgumentError SPA.Id(-1)
    @test_throws ArgumentError SPA.Id(big(typemax(UInt32)) + 1)
    @test_throws ArgumentError SPA.Fd(big(typemax(Int64)) + 1)
    @test_throws ArgumentError SPA.Rectangle(-1, 1)
    @test_throws ArgumentError SPA.Fraction(1, -1)
    @test_throws ArgumentError Pod("embedded\0null")

    malformed_string = PipeWire._pod_from_body(
        UInt32(PipeWire.LibPipeWire.SPA_TYPE_String),
        UInt8[0x61],
    )
    embedded_null = PipeWire._pod_from_body(
        UInt32(PipeWire.LibPipeWire.SPA_TYPE_String),
        UInt8[0x61, 0x00, 0x62, 0x00],
    )
    malformed_bool = PipeWire._pod_from_body(
        UInt32(PipeWire.LibPipeWire.SPA_TYPE_Bool),
        UInt8[0x01],
    )
    @test_throws ArgumentError pod_value(String, malformed_string)
    @test_throws ArgumentError pod_value(String, embedded_null)
    @test_throws ArgumentError pod_value(Bool, malformed_bool)
end

@testset "container SPA POD values" begin
    arrays = (
        SPA.Array(Bool[true, false, true]),
        SPA.Array(SPA.Id[SPA.Id(1), SPA.Id(7)]),
        SPA.Array(Int32[-1, 0, 1]),
        SPA.Array(Int64[-(Int64(1) << 40), Int64(1) << 40]),
        SPA.Array(Float32[-1.5, 2.25]),
        SPA.Array(Float64[-3.5, 4.75]),
        SPA.Array([SPA.Rectangle(640, 480), SPA.Rectangle(1_920, 1_080)]),
        SPA.Array([SPA.Fraction(24, 1), SPA.Fraction(30_000, 1_001)]),
        SPA.Array([SPA.Fd(-1), SPA.Fd(9)]),
        SPA.Array(Int32[]),
    )

    for array in arrays
        pod = Pod(array)
        @test pod_type(pod) == PipeWire.LibPipeWire.SPA_TYPE_Array
        @test pod_value(typeof(array), pod) == array
        @test pod_value(pod) == array
        @test isconcretetype(typeof(array))
        @test all(isconcretetype, fieldtypes(typeof(array)))
    end

    source = Int32[1, 2, 3]
    array = SPA.Array(source)
    source[1] = 9
    @test array.values == Int32[1, 2, 3]

    int_array_pod = Pod(SPA.Array(Int32[4, 5, 6]))
    @test @inferred(pod_value(SPA.Array{Int32}, int_array_pod)) ==
          SPA.Array(Int32[4, 5, 6])
    @test_throws ArgumentError pod_value(SPA.Array{Int64}, int_array_pod)
    @test_throws ArgumentError SPA.Array(Real[1, 2])
    @test_throws ArgumentError Pod(SPA.Array(["not", "fixed-size"]))

    children = [Pod(Int32(7)), Pod("hello"), Pod(SPA.Array(Int64[8, 9]))]
    value = SPA.Struct(children)
    children[1] = Pod(Int32(99))
    pod = Pod(value)
    @test pod_type(pod) == PipeWire.LibPipeWire.SPA_TYPE_Struct
    decoded = @inferred pod_value(SPA.Struct, pod)
    @test decoded == value
    @test pod_value(pod) == value
    @test isconcretetype(typeof(decoded))
    @test all(isconcretetype, fieldtypes(typeof(decoded)))
    @test pod_value(Int32, decoded.values[1]) == 7
    @test pod_value(String, decoded.values[2]) == "hello"
    @test pod_value(decoded.values[3]) == SPA.Array(Int64[8, 9])

    partial_array_body = UInt8[]
    PipeWire._append_bits!(partial_array_body, UInt32(sizeof(Int32)))
    PipeWire._append_bits!(partial_array_body, UInt32(PipeWire.LibPipeWire.SPA_TYPE_Int))
    append!(partial_array_body, UInt8[1, 2, 3])
    partial_array = PipeWire._pod_from_body(
        UInt32(PipeWire.LibPipeWire.SPA_TYPE_Array),
        partial_array_body,
    )
    missing_array_header = PipeWire._pod_from_body(
        UInt32(PipeWire.LibPipeWire.SPA_TYPE_Array),
        UInt8[],
    )
    @test_throws ArgumentError pod_value(SPA.Array{Int32}, partial_array)
    @test_throws ArgumentError pod_value(SPA.Array, missing_array_header)

    unpadded_struct = PipeWire._pod_from_body(
        UInt32(PipeWire.LibPipeWire.SPA_TYPE_Struct),
        Pod(Int32(1)).data,
    )
    partial_struct = PipeWire._pod_from_body(
        UInt32(PipeWire.LibPipeWire.SPA_TYPE_Struct),
        UInt8[0x01],
    )
    @test_throws ArgumentError pod_value(SPA.Struct, unpadded_struct)
    @test_throws ArgumentError pod_value(SPA.Struct, partial_struct)

    oversized_header = UInt8[]
    PipeWire._append_bits!(oversized_header, UInt32(1 << 20))
    PipeWire._append_bits!(oversized_header, UInt32(PipeWire.LibPipeWire.SPA_TYPE_Bytes))
    @test_throws ArgumentError Pod(oversized_header)
end

@testset "choice SPA POD values" begin
    choices = (
        SPA.Choice(SPA.CHOICE_NONE, Bool[true]),
        SPA.Choice(SPA.CHOICE_ENUM, SPA.Id[SPA.Id(1), SPA.Id(2), SPA.Id(7)]),
        SPA.Choice(SPA.CHOICE_RANGE, Int32[48_000, 8_000, 192_000]),
        SPA.Choice(SPA.CHOICE_STEP, Int64[8, 0, 64, 8]),
        SPA.Choice(SPA.CHOICE_ENUM, Float32[1.0, 1.5, 2.0]; flags=3),
        SPA.Choice(SPA.CHOICE_RANGE, Float64[1.0, 0.5, 2.0]),
        SPA.Choice(
            SPA.CHOICE_RANGE,
            [
                SPA.Rectangle(1_920, 1_080),
                SPA.Rectangle(320, 240),
                SPA.Rectangle(3_840, 2_160),
            ],
        ),
        SPA.Choice(
            SPA.CHOICE_STEP,
            [
                SPA.Fraction(30_000, 1_001),
                SPA.Fraction(1, 1),
                SPA.Fraction(60, 1),
                SPA.Fraction(1, 1),
            ],
        ),
        SPA.Choice(SPA.CHOICE_FLAGS, [SPA.Fd(3)]),
    )

    for choice in choices
        pod = Pod(choice)
        @test pod_type(pod) == PipeWire.LibPipeWire.SPA_TYPE_Choice
        @test pod_value(typeof(choice), pod) == choice
        @test pod_value(pod) == choice
        @test isconcretetype(typeof(choice))
        @test all(isconcretetype, fieldtypes(typeof(choice)))
    end

    source = Int32[2, 1, 3]
    choice = SPA.Choice(SPA.CHOICE_RANGE, source)
    source[1] = 9
    @test choice.values == Int32[2, 1, 3]

    choice_pod = Pod(choice)
    @test @inferred(pod_value(SPA.Choice{Int32}, choice_pod)) == choice
    @test_throws ArgumentError pod_value(SPA.Choice{Int64}, choice_pod)
    @test_throws ArgumentError SPA.Choice(SPA.CHOICE_NONE, Int32[])
    @test_throws ArgumentError SPA.Choice(SPA.CHOICE_NONE, Int32[1, 2])
    @test_throws ArgumentError SPA.Choice(SPA.CHOICE_RANGE, Int32[1, 2])
    @test_throws ArgumentError SPA.Choice(SPA.CHOICE_RANGE, Int32[1, 2, 3, 4])
    @test_throws ArgumentError SPA.Choice(SPA.CHOICE_STEP, Int32[1, 2, 3])
    @test_throws ArgumentError SPA.Choice(SPA.CHOICE_STEP, Int32[1, 2, 3, 4, 5])
    @test_throws ArgumentError SPA.Choice(SPA.CHOICE_ENUM, Int32[])
    @test_throws ArgumentError SPA.Choice(SPA.CHOICE_ENUM, Int32[1])
    @test_throws ArgumentError SPA.Choice(SPA.CHOICE_FLAGS, Int32[])
    @test_throws ArgumentError SPA.Choice(SPA.CHOICE_FLAGS, Int32[1, 2])
    @test_throws ArgumentError SPA.Choice(SPA.CHOICE_NONE, Real[1])
    @test_throws ArgumentError SPA.Choice(SPA.CHOICE_NONE, Int32[1]; flags=-1)
    @test_throws ArgumentError Pod(SPA.Choice(SPA.CHOICE_NONE, ["not fixed-size"]))

    unknown_kind_body = UInt8[]
    PipeWire._append_bits!(unknown_kind_body, UInt32(99))
    PipeWire._append_bits!(unknown_kind_body, UInt32(0))
    PipeWire._append_bits!(unknown_kind_body, UInt32(sizeof(Int32)))
    PipeWire._append_bits!(unknown_kind_body, UInt32(PipeWire.LibPipeWire.SPA_TYPE_Int))
    PipeWire._append_bits!(unknown_kind_body, Int32(1))
    unknown_kind = PipeWire._pod_from_body(
        UInt32(PipeWire.LibPipeWire.SPA_TYPE_Choice),
        unknown_kind_body,
    )

    partial_choice_body = UInt8[]
    PipeWire._append_bits!(partial_choice_body, UInt32(SPA.CHOICE_NONE))
    PipeWire._append_bits!(partial_choice_body, UInt32(0))
    PipeWire._append_bits!(partial_choice_body, UInt32(sizeof(Int32)))
    PipeWire._append_bits!(partial_choice_body, UInt32(PipeWire.LibPipeWire.SPA_TYPE_Int))
    append!(partial_choice_body, UInt8[1, 2, 3])
    partial_choice = PipeWire._pod_from_body(
        UInt32(PipeWire.LibPipeWire.SPA_TYPE_Choice),
        partial_choice_body,
    )

    missing_choice_header = PipeWire._pod_from_body(
        UInt32(PipeWire.LibPipeWire.SPA_TYPE_Choice),
        UInt8[],
    )
    @test_throws ArgumentError pod_value(SPA.Choice, unknown_kind)
    @test_throws ArgumentError pod_value(SPA.Choice{Int32}, partial_choice)
    @test_throws ArgumentError pod_value(SPA.Choice, missing_choice_header)
end

@testset "object SPA POD values" begin
    object = SPA.Object(
        0x40002,
        3,
        SPA.Property(1, SPA.Id(7); flags=SPA.PROPERTY_READONLY),
        SPA.Property(2, "audio"),
        SPA.Property(
            3,
            SPA.Choice(SPA.CHOICE_RANGE, Int32[48_000, 8_000, 192_000]);
            flags=SPA.PROPERTY_MANDATORY | SPA.PROPERTY_DONT_FIXATE,
        ),
    )
    pod = Pod(object)
    @test pod_type(pod) == PipeWire.LibPipeWire.SPA_TYPE_Object
    decoded = @inferred pod_value(SPA.Object, pod)
    @test decoded == object
    @test pod_value(pod) == object
    @test isconcretetype(typeof(decoded))
    @test all(isconcretetype, fieldtypes(typeof(decoded)))
    @test isconcretetype(SPA.Property)
    @test all(isconcretetype, fieldtypes(SPA.Property))
    @test decoded.properties[1].flags == SPA.PROPERTY_READONLY
    @test pod_value(SPA.Id, decoded.properties[1].value) == SPA.Id(7)
    @test pod_value(String, decoded.properties[2].value) == "audio"
    @test pod_value(decoded.properties[3].value) ==
          SPA.Choice(SPA.CHOICE_RANGE, Int32[48_000, 8_000, 192_000])

    properties = [SPA.Property(1, Int32(2))]
    copied = SPA.Object(1, 2, properties)
    properties[1] = SPA.Property(1, Int32(9))
    @test pod_value(Int32, copied.properties[1].value) == 2

    format = pod_value(SPA.Object, audio_format())
    @test format.type == PipeWire.LibPipeWire.SPA_TYPE_OBJECT_Format
    @test format.id == PipeWire.LibPipeWire.SPA_PARAM_EnumFormat
    @test length(format.properties) == 6
    @test map(property -> property.key, format.properties) == UInt32[
        PipeWire.LibPipeWire.SPA_FORMAT_mediaType,
        PipeWire.LibPipeWire.SPA_FORMAT_mediaSubtype,
        PipeWire.LibPipeWire.SPA_FORMAT_AUDIO_format,
        PipeWire.LibPipeWire.SPA_FORMAT_AUDIO_rate,
        PipeWire.LibPipeWire.SPA_FORMAT_AUDIO_channels,
        PipeWire.LibPipeWire.SPA_FORMAT_AUDIO_position,
    ]

    @test_throws ArgumentError SPA.Property(-1, Int32(1))
    @test_throws ArgumentError SPA.Property(1, Int32(1); flags=-1)
    @test_throws ArgumentError SPA.Object(-1, 1, SPA.Property[])
    @test_throws ArgumentError SPA.Object(1, -1, SPA.Property[])

    missing_object_header = PipeWire._pod_from_body(
        UInt32(PipeWire.LibPipeWire.SPA_TYPE_Object),
        UInt8[],
    )
    partial_property_body = UInt8[]
    PipeWire._append_bits!(partial_property_body, UInt32(1))
    PipeWire._append_bits!(partial_property_body, UInt32(2))
    push!(partial_property_body, 0x01)
    partial_property = PipeWire._pod_from_body(
        UInt32(PipeWire.LibPipeWire.SPA_TYPE_Object),
        partial_property_body,
    )
    truncated_value_body = UInt8[]
    PipeWire._append_bits!(truncated_value_body, UInt32(1))
    PipeWire._append_bits!(truncated_value_body, UInt32(2))
    PipeWire._append_bits!(truncated_value_body, UInt32(3))
    PipeWire._append_bits!(truncated_value_body, UInt32(0))
    PipeWire._append_bits!(truncated_value_body, UInt32(8))
    PipeWire._append_bits!(truncated_value_body, UInt32(PipeWire.LibPipeWire.SPA_TYPE_Long))
    PipeWire._append_bits!(truncated_value_body, Int32(1))
    truncated_value = PipeWire._pod_from_body(
        UInt32(PipeWire.LibPipeWire.SPA_TYPE_Object),
        truncated_value_body,
    )
    @test_throws ArgumentError pod_value(SPA.Object, missing_object_header)
    @test_throws ArgumentError pod_value(SPA.Object, partial_property)
    @test_throws ArgumentError pod_value(SPA.Object, truncated_value)
end

@testset "sequence SPA POD values" begin
    sequence = SPA.Sequence(
        1,
        SPA.Control(0, 2, SPA.Bytes(UInt8[0x90, 0x40, 0x7f])),
        SPA.Control(128, 3, Float32(0.5)),
        SPA.Control(256, 4, SPA.Object(1, 2, SPA.Property(3, Int32(4)))),
    )
    pod = Pod(sequence)
    @test pod_type(pod) == PipeWire.LibPipeWire.SPA_TYPE_Sequence
    decoded = @inferred pod_value(SPA.Sequence, pod)
    @test decoded == sequence
    @test pod_value(pod) == sequence
    @test isconcretetype(SPA.Control)
    @test all(isconcretetype, fieldtypes(SPA.Control))
    @test isconcretetype(SPA.Sequence)
    @test all(isconcretetype, fieldtypes(SPA.Sequence))
    @test pod_value(SPA.Bytes, decoded.controls[1].value) ==
          SPA.Bytes(UInt8[0x90, 0x40, 0x7f])
    @test pod_value(Float32, decoded.controls[2].value) == 0.5f0
    @test pod_value(SPA.Object, decoded.controls[3].value) ==
          SPA.Object(1, 2, SPA.Property(3, Int32(4)))

    controls = [SPA.Control(0, 1, Int32(2))]
    copied = SPA.Sequence(1, controls)
    controls[1] = SPA.Control(0, 1, Int32(9))
    @test pod_value(Int32, copied.controls[1].value) == 2

    @test_throws ArgumentError SPA.Control(-1, 1, Int32(1))
    @test_throws ArgumentError SPA.Control(1, -1, Int32(1))
    @test_throws ArgumentError SPA.Sequence(-1, SPA.Control[])

    missing_sequence_header = PipeWire._pod_from_body(
        UInt32(PipeWire.LibPipeWire.SPA_TYPE_Sequence),
        UInt8[],
    )
    nonzero_padding_body = UInt8[]
    PipeWire._append_bits!(nonzero_padding_body, UInt32(1))
    PipeWire._append_bits!(nonzero_padding_body, UInt32(1))
    nonzero_padding = PipeWire._pod_from_body(
        UInt32(PipeWire.LibPipeWire.SPA_TYPE_Sequence),
        nonzero_padding_body,
    )
    partial_control_body = UInt8[]
    PipeWire._append_bits!(partial_control_body, UInt32(1))
    PipeWire._append_bits!(partial_control_body, UInt32(0))
    push!(partial_control_body, 0x01)
    partial_control = PipeWire._pod_from_body(
        UInt32(PipeWire.LibPipeWire.SPA_TYPE_Sequence),
        partial_control_body,
    )
    truncated_control_body = UInt8[]
    PipeWire._append_bits!(truncated_control_body, UInt32(1))
    PipeWire._append_bits!(truncated_control_body, UInt32(0))
    PipeWire._append_bits!(truncated_control_body, UInt32(0))
    PipeWire._append_bits!(truncated_control_body, UInt32(2))
    PipeWire._append_bits!(truncated_control_body, UInt32(8))
    PipeWire._append_bits!(truncated_control_body, UInt32(PipeWire.LibPipeWire.SPA_TYPE_Long))
    PipeWire._append_bits!(truncated_control_body, Int32(1))
    truncated_control = PipeWire._pod_from_body(
        UInt32(PipeWire.LibPipeWire.SPA_TYPE_Sequence),
        truncated_control_body,
    )
    @test_throws ArgumentError pod_value(SPA.Sequence, missing_sequence_header)
    @test_throws ArgumentError pod_value(SPA.Sequence, nonzero_padding)
    @test_throws ArgumentError pod_value(SPA.Sequence, partial_control)
    @test_throws ArgumentError pod_value(SPA.Sequence, truncated_control)
end

@testset "raw video format" begin
    @test length(instances(Video.Format)) == 88
    @test Video.DSP_F32 == Video.RGBA_F32

    format = @inferred video_format()
    object = pod_value(SPA.Object, format)
    @test object.type == PipeWire.LibPipeWire.SPA_TYPE_OBJECT_Format
    @test object.id == PipeWire.LibPipeWire.SPA_PARAM_EnumFormat
    @test map(property -> property.key, object.properties) == UInt32[
        PipeWire.LibPipeWire.SPA_FORMAT_mediaType,
        PipeWire.LibPipeWire.SPA_FORMAT_mediaSubtype,
        PipeWire.LibPipeWire.SPA_FORMAT_VIDEO_format,
        PipeWire.LibPipeWire.SPA_FORMAT_VIDEO_size,
        PipeWire.LibPipeWire.SPA_FORMAT_VIDEO_framerate,
    ]
    @test pod_value(SPA.Id, object.properties[1].value) ==
          SPA.Id(PipeWire.LibPipeWire.SPA_MEDIA_TYPE_video)
    @test pod_value(SPA.Id, object.properties[2].value) ==
          SPA.Id(PipeWire.LibPipeWire.SPA_MEDIA_SUBTYPE_raw)
    @test pod_value(SPA.Id, object.properties[3].value) == SPA.Id(UInt32(Video.RGBA))
    @test pod_value(SPA.Rectangle, object.properties[4].value) == SPA.Rectangle(640, 480)
    @test pod_value(SPA.Fraction, object.properties[5].value) == SPA.Fraction(30, 1)

    complete = pod_value(
        SPA.Object,
        video_format(
            format=Video.NV12,
            size=SPA.Rectangle(1_920, 1_080),
            framerate=SPA.Fraction(30_000, 1_001),
            modifier=0,
            max_framerate=SPA.Fraction(60, 1),
            views=2,
            interlace_mode=1,
            pixel_aspect_ratio=SPA.Fraction(1, 1),
            multiview_mode=2,
            multiview_flags=3,
            chroma_site=4,
            color_range=1,
            color_matrix=2,
            transfer_function=3,
            color_primaries=4,
            id=4,
        ),
    )
    @test complete.id == 4
    @test length(complete.properties) == 17
    property_by_key = Dict(property.key => property for property in complete.properties)
    @test pod_value(SPA.Id, property_by_key[PipeWire.LibPipeWire.SPA_FORMAT_VIDEO_format].value) ==
          SPA.Id(UInt32(Video.NV12))
    @test pod_value(Int64, property_by_key[PipeWire.LibPipeWire.SPA_FORMAT_VIDEO_modifier].value) == 0
    @test property_by_key[PipeWire.LibPipeWire.SPA_FORMAT_VIDEO_modifier].flags ==
          SPA.PROPERTY_MANDATORY
    @test pod_value(Int32, property_by_key[PipeWire.LibPipeWire.SPA_FORMAT_VIDEO_views].value) == 2
    @test pod_value(
        SPA.Fraction,
        property_by_key[PipeWire.LibPipeWire.SPA_FORMAT_VIDEO_pixelAspectRatio].value,
    ) == SPA.Fraction(1, 1)

    no_rate = pod_value(SPA.Object, video_format(framerate=nothing))
    @test all(
        property -> property.key != PipeWire.LibPipeWire.SPA_FORMAT_VIDEO_framerate,
        no_rate.properties,
    )

    @test_throws ArgumentError video_format(size=SPA.Rectangle(0, 480))
    @test_throws ArgumentError video_format(framerate=SPA.Fraction(30, 0))
    @test_throws ArgumentError video_format(max_framerate=SPA.Fraction(60, 0))
    @test_throws ArgumentError video_format(pixel_aspect_ratio=SPA.Fraction(1, 0))
    @test_throws ArgumentError video_format(modifier=big(typemax(Int64)) + 1)
    @test_throws ArgumentError video_format(views=big(typemax(Int32)) + 1)
    @test_throws ArgumentError video_format(interlace_mode=-1)
    @test_throws ArgumentError video_format(id=-1)
end

@testset "bitmap and pointer SPA POD values" begin
    source = UInt8[0xaa, 0x55]
    bitmap = SPA.Bitmap(source)
    source[1] = 0x00
    bitmap_pod = Pod(bitmap)
    @test pod_type(bitmap_pod) == PipeWire.LibPipeWire.SPA_TYPE_Bitmap
    @test pod_value(SPA.Bitmap, bitmap_pod) == SPA.Bitmap(UInt8[0xaa, 0x55])
    @test pod_value(bitmap_pod) == bitmap
    @test isconcretetype(SPA.Bitmap)
    @test all(isconcretetype, fieldtypes(SPA.Bitmap))
    @test_throws ArgumentError SPA.Bitmap(UInt8[])

    storage = Ref{Int32}(42)
    pointer = SPA.Pointer(7, Base.unsafe_convert(Ptr{Int32}, storage))
    pointer_pod = GC.@preserve storage Pod(pointer)
    decoded = @inferred pod_value(SPA.Pointer{Int32}, pointer_pod)
    @test decoded == pointer
    @test pod_type(pointer_pod) == PipeWire.LibPipeWire.SPA_TYPE_Pointer
    @test pod_value(pointer_pod) == SPA.Pointer(7, Ptr{Cvoid}(pointer.value))
    @test isconcretetype(typeof(pointer))
    @test all(isconcretetype, fieldtypes(typeof(pointer)))
    @test isbitstype(typeof(pointer))
    @test pod_value_allocations(SPA.Pointer{Int32}, pointer_pod) == 0
    @test_throws ArgumentError SPA.Pointer(-1, pointer.value)

    nonzero_padding_body = UInt8[]
    PipeWire._append_bits!(nonzero_padding_body, UInt32(7))
    PipeWire._append_bits!(nonzero_padding_body, UInt32(1))
    PipeWire._append_bits!(nonzero_padding_body, UInt(pointer.value))
    nonzero_padding = PipeWire._pod_from_body(
        UInt32(PipeWire.LibPipeWire.SPA_TYPE_Pointer),
        nonzero_padding_body,
    )
    @test_throws ArgumentError pod_value(SPA.Pointer{Int32}, nonzero_padding)

    empty_bitmap = PipeWire._pod_from_body(
        UInt32(PipeWire.LibPipeWire.SPA_TYPE_Bitmap),
        UInt8[],
    )
    @test_throws ArgumentError pod_value(SPA.Bitmap, empty_bitmap)
end
@testset "typed SPA parameters, commands, and events" begin
    buffers = buffers_param(
        buffers=4,
        blocks=1,
        size=4096,
        stride=256,
        align=16,
        data_types=Int32(1 << PipeWire.LibPipeWire.SPA_DATA_MemPtr),
        metadata_types=Int32(1 << PipeWire.LibPipeWire.SPA_META_Header),
    )
    @test buffers isa SPA.Parameter
    @test all(isconcretetype, fieldtypes(typeof(buffers)))
    @test buffers.object.type == PipeWire.LibPipeWire.SPA_TYPE_OBJECT_ParamBuffers
    @test buffers.object.id == PipeWire.LibPipeWire.SPA_PARAM_Buffers
    @test pod_value(SPA.Parameter, Pod(buffers)) == buffers

    metadata = metadata_param(PipeWire.LibPipeWire.SPA_META_Header; size=64)
    io = io_param(PipeWire.LibPipeWire.SPA_IO_Buffers; size=32)
    @test pod_value(SPA.Parameter, Pod(metadata)) == metadata
    @test pod_value(SPA.Parameter, Pod(io)) == io
    @test_throws ArgumentError buffers_param(size=big(typemax(Int32)) + 1)

    latency = latency_param(
        PipeWire.LibPipeWire.SPA_DIRECTION_OUTPUT;
        min_quantum=0.5,
        max_quantum=2,
        min_rate=64,
        max_rate=256,
        min_ns=1_000,
        max_ns=2_000,
    )
    process_latency = process_latency_param(quantum=1, rate=128, ns=500)
    tag = tag_param(
        PipeWire.LibPipeWire.SPA_DIRECTION_INPUT,
        ("language" => "en", "role" => "music"),
    )
    @test latency.object.type == PipeWire.LibPipeWire.SPA_TYPE_OBJECT_ParamLatency
    @test process_latency.object.type ==
          PipeWire.LibPipeWire.SPA_TYPE_OBJECT_ParamProcessLatency
    @test tag.object.type == PipeWire.LibPipeWire.SPA_TYPE_OBJECT_ParamTag
    @test pod_value(SPA.Parameter, Pod(latency)) == latency
    @test pod_value(SPA.Parameter, Pod(process_latency)) == process_latency
    @test pod_value(SPA.Parameter, Pod(tag)) == tag
    @test_throws ArgumentError latency_param(
        PipeWire.LibPipeWire.SPA_DIRECTION_INPUT;
        min_quantum=Inf,
    )

    command = node_command(PipeWire.LibPipeWire.SPA_NODE_COMMAND_Start)
    event = node_event(PipeWire.LibPipeWire.SPA_NODE_EVENT_RequestProcess)
    @test command isa SPA.Command
    @test event isa SPA.Event
    @test all(isconcretetype, fieldtypes(typeof(command)))
    @test all(isconcretetype, fieldtypes(typeof(event)))
    @test pod_value(SPA.Command, Pod(command)) == command
    @test pod_value(SPA.Event, Pod(event)) == event
    @test device_command(1).object.type == PipeWire.LibPipeWire.SPA_TYPE_COMMAND_Device
    @test device_event(1).object.type == PipeWire.LibPipeWire.SPA_TYPE_EVENT_Device
    @test_throws ArgumentError SPA.Command(
        SPA.Object(PipeWire.LibPipeWire.SPA_TYPE_OBJECT_Format, 0),
    )
    @test_throws ArgumentError SPA.Event(
        SPA.Object(PipeWire.LibPipeWire.SPA_TYPE_OBJECT_Format, 0),
    )

    typed_audio = audio_format_param(rate=48_000, channels=2)
    typed_video = video_format_param(size=SPA.Rectangle(1920, 1080))
    @test typed_audio isa SPA.Parameter
    @test typed_video isa SPA.Parameter
    @test typed_audio.object.type == PipeWire.LibPipeWire.SPA_TYPE_OBJECT_Format
    @test typed_video.object.type == PipeWire.LibPipeWire.SPA_TYPE_OBJECT_Format
end
