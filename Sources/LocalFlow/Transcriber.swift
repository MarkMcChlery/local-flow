import Foundation
import WhisperKit

/// Wraps WhisperKit (Argmax OSS SDK). Downloads the chosen CoreML model
/// on first use, caches it locally, and transcribes Float32 16 kHz audio.
actor Transcriber {
    private var pipe: WhisperKit?
    private var loadedModel: String?

    func load(model: String) async throws {
        if loadedModel == model, pipe != nil { return }
        pipe = nil
        loadedModel = nil
        let config = WhisperKitConfig(model: model)
        pipe = try await WhisperKit(config)
        loadedModel = model
    }

    func transcribe(_ samples: [Float]) async throws -> String {
        guard let pipe else { throw LFError.modelNotReady }
        let results = try await pipe.transcribe(audioArray: samples)
        return results
            .map { $0.text }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
