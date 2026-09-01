import AVFoundation
import XCTest

@testable import FluidAudio

@available(macOS 14.0, iOS 17.0, *)
final class OfflineDiarizerCancellationTests: XCTestCase {
    func testCancellingFileProcessingStopsAllInferenceWorkers() async throws {
        try requireOfflineDiarizerModels()

        let fixture = try DiarizationTestFixtures.fixtureAudio(sampleRate: 16_000)
        var longMeeting: [Float] = []
        longMeeting.reserveCapacity(fixture.count * 60)
        for _ in 0..<60 {
            longMeeting.append(contentsOf: fixture)
        }

        let audioURL = try writeWAV(samples: longMeeting, sampleRate: 16_000)
        defer { try? FileManager.default.removeItem(at: audioURL) }

        let manager = OfflineDiarizerManager()
        let progress = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        var progressIterator = progress.stream.makeAsyncIterator()

        let processingTask = Task {
            try await manager.process(audioURL) { _, _ in
                progress.continuation.yield(())
            }
        }

        guard await progressIterator.next() != nil else {
            processingTask.cancel()
            XCTFail("Diarization ended before inference began")
            return
        }

        let cancellationStart = ContinuousClock.now
        processingTask.cancel()

        do {
            _ = try await processingTask.value
            XCTFail("Cancelled diarization unexpectedly completed")
        } catch is CancellationError {
            // Expected. Returning from the structured task group also proves both
            // inference workers have stopped rather than continuing in the background.
        } catch {
            XCTFail("Expected CancellationError, received \(error)")
        }

        let cancellationDuration = cancellationStart.duration(to: .now)
        XCTAssertLessThan(
            cancellationDuration,
            .seconds(5),
            "Cancellation should stop segmentation and embedding between model calls"
        )
    }

    private func requireOfflineDiarizerModels() throws {
        let repoDirectory = OfflineDiarizerModels.defaultModelsDirectory()
            .appendingPathComponent(Repo.diarizer.folderName, isDirectory: true)
        let allPresent = ModelNames.OfflineDiarizer.requiredModels.allSatisfy {
            FileManager.default.fileExists(atPath: repoDirectory.appendingPathComponent($0).path)
        }
        guard allPresent else {
            throw XCTSkip("Offline diarizer models not available")
        }
    }

    private func writeWAV(samples: [Float], sampleRate: Double) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("offline-diarizer-cancellation-\(UUID().uuidString)")
            .appendingPathExtension("wav")
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        )!
        let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(samples.count)
        )!
        buffer.frameLength = buffer.frameCapacity
        samples.withUnsafeBufferPointer { source in
            buffer.floatChannelData![0].update(
                from: source.baseAddress!,
                count: samples.count
            )
        }

        let file = try AVAudioFile(
            forWriting: url,
            settings: format.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        try file.write(from: buffer)
        return url
    }
}
