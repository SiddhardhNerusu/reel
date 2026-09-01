import AVFoundation
import Foundation
import Speech

/// On-device transcription for burned-in captions. Product constitution §6.3: all intelligence is
/// Apple frameworks on this Mac — `requiresOnDeviceRecognition` is non-negotiable, so captions
/// work offline and nothing leaves the machine (the anti-"AI credits" pitch).
enum AudioTranscriber {

    enum TranscribeError: Error { case notAuthorized, unavailable }

    static func requestAuthorization() async -> Bool {
        await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status == .authorized)
            }
        }
    }

    /// Word-level transcription of a movie's audio. Returns [] for silent takes.
    static func words(from url: URL) async throws -> [(text: String, start: Double, end: Double)] {
        guard await requestAuthorization() else { throw TranscribeError.notAuthorized }
        guard let recognizer = SFSpeechRecognizer(), recognizer.isAvailable,
              recognizer.supportsOnDeviceRecognition else { throw TranscribeError.unavailable }

        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = true   // local-only, always
        request.shouldReportPartialResults = false
        request.taskHint = .dictation

        return try await withCheckedThrowingContinuation { cont in
            var finished = false
            recognizer.recognitionTask(with: request) { result, error in
                guard !finished else { return }
                if let error {
                    finished = true
                    cont.resume(throwing: error)
                    return
                }
                guard let result, result.isFinal else { return }
                finished = true
                let words = result.bestTranscription.segments.map {
                    (text: $0.substring, start: $0.timestamp, end: $0.timestamp + $0.duration)
                }
                cont.resume(returning: words)
            }
        }
    }
}
