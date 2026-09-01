@preconcurrency import AVFoundation
import XCTest

@testable import FluidAudio

@available(macOS 14.0, iOS 17.0, *)
final class AudioSourceFactoryTests: XCTestCase {
    func testSixteenKilohertzMonoPreservesSampleCountAndLevel() throws {
        try assertConversion(
            inputSampleRate: 16_000,
            channels: 1,
            inputFrames: 1_600,
            expectedSamples: 1_600
        )
    }

    func testEightKilohertzMonoResamplesWithoutDurationDrift() throws {
        try assertConversion(
            inputSampleRate: 8_000,
            channels: 1,
            inputFrames: 800,
            expectedSamples: 1_600
        )
    }

    func testFortyEightKilohertzStereoDownmixesOnceWithoutDurationDrift() throws {
        try assertConversion(
            inputSampleRate: 48_000,
            channels: 2,
            inputFrames: 4_800,
            expectedSamples: 1_600
        )
    }

    private func assertConversion(
        inputSampleRate: Double,
        channels: AVAudioChannelCount,
        inputFrames: AVAudioFrameCount,
        expectedSamples: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioSourceFactoryTests-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let inputURL = directory.appendingPathComponent("input.caf")
        try writeConstantCAF(
            at: inputURL,
            sampleRate: inputSampleRate,
            channels: channels,
            frames: inputFrames,
            value: 0.25
        )

        let result = try AudioSourceFactory().makeDiskBackedSource(
            from: inputURL,
            targetSampleRate: 16_000
        )
        defer { result.source.cleanup() }

        XCTAssertEqual(result.source.sampleCount, expectedSamples, file: file, line: line)
        var samples = [Float](repeating: 0, count: result.source.sampleCount)
        try samples.withUnsafeMutableBufferPointer { buffer in
            try result.source.copySamples(
                into: buffer.baseAddress!,
                offset: 0,
                count: buffer.count
            )
        }

        // Ignore converter edge priming and verify that equal-valued stereo
        // channels are averaged once, never summed or duplicated.
        let interior = samples.dropFirst(min(64, samples.count / 4))
            .dropLast(min(64, samples.count / 4))
        XCTAssertFalse(interior.isEmpty, file: file, line: line)
        let mean = interior.reduce(0, +) / Float(interior.count)
        XCTAssertEqual(mean, 0.25, accuracy: 0.002, file: file, line: line)
    }

    private func writeConstantCAF(
        at url: URL,
        sampleRate: Double,
        channels: AVAudioChannelCount,
        frames: AVAudioFrameCount,
        value: Float
    ) throws {
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: channels,
            interleaved: false
        ))
        var file: AVAudioFile? = try AVAudioFile(
            forWriting: url,
            settings: format.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)
        )
        buffer.frameLength = frames
        for channel in 0..<Int(channels) {
            buffer.floatChannelData?[channel].initialize(
                repeating: value,
                count: Int(frames)
            )
        }
        try file?.write(from: buffer)
        file = nil
    }
}
