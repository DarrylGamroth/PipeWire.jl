using Test

include(joinpath(@__DIR__, "..", "examples", "audio_sine.jl"))
include(joinpath(@__DIR__, "..", "examples", "video_capture.jl"))

@testset "client examples" begin
    @test all(isconcretetype, fieldtypes(AudioSine.SineProcess))
    @test all(isconcretetype, fieldtypes(VideoCapture.CaptureProcess))
    @test isconcretetype(VideoCapture.FormatReporter)
    @test AudioSine.SineProcess(440, 0.1, 48_000, 2).channels == 2
    @test VideoCapture.CaptureProcess(report_every=30).report_every == 30
    @test_throws ArgumentError AudioSine.SineProcess(440, 2, 48_000, 2)
    @test_throws ArgumentError VideoCapture.CaptureProcess(report_every=0)

    output = IOBuffer()
    AudioSine.usage(output)
    @test occursin("audio_sine.jl", String(take!(output)))
    VideoCapture.usage(output)
    @test occursin("video_capture.jl", String(take!(output)))
end
