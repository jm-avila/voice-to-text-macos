import FluidAudio
import Foundation
import Synchronization

/// NVIDIA Parakeet TDT v3, post-trained as Parakeet Ultra, on the Neural Engine
/// through FluidAudio. No key, no network after the first download (610 MB,
/// from Hugging Face, into FluidAudio's own folder). 25 European languages,
/// detected from the speech: English said with Español chosen stays English.
/// A 23 s dictation takes about 0.1 s on an M4 Pro, so nothing streams.
public enum Parakeet {
    /// The id saved in settings.json and shown by `vtt`.
    public static let model = "parakeet-ultra-local"
    static let version = AsrModelVersion.ultra
    public static let directory = AsrModels.defaultCacheDirectory(for: version)

    public enum Status: String, Sendable {
        case ready, noModel
    }

    /// Downloaded completely (an interrupted download is not ready).
    public static var status: Status {
        AsrModels.modelsExist(at: directory, version: version) ? .ready : .noModel
    }

    /// The language hint keeps the output in the language's script. Latin
    /// languages decode alike, so it never translates.
    static func hint(_ language: String?) -> Language? {
        language.flatMap(Language.init(rawValue:))
    }
}

/// Keeps the model loaded while it is selected (`load`), frees it when another
/// model is picked (`unload`). A transcription with nothing loaded loads it
/// first: about 0.1 s once downloaded, the download itself the first time.
public final class ParakeetTranscriber: Transcribing, Sendable {
    private struct State {
        var manager: AsrManager?
        /// Runs to the end once started (a download can't be stopped halfway), so a
        /// pick, a switch away, and a pick again share one download.
        var loading: Task<AsrManager, Error>?
        /// Parakeet is selected. A load that finishes when it is not keeps nothing.
        var wanted = false
    }
    private let state = Mutex(State())

    public init() {}

    public var isLoaded: Bool { state.withLock { $0.manager != nil } }
    public var isLoading: Bool { state.withLock { $0.loading != nil } }

    /// Loads (and the first time downloads) the model. Safe to call again while it loads.
    /// `keep` is for picking the model; a transcription joins the load without keeping
    /// it, so one that ends after the person switched away does not hold 600 MB.
    @discardableResult
    public func load(keep: Bool = true) async throws -> AsrManager {
        let task = state.withLock { state -> Task<AsrManager, Error> in
            if keep { state.wanted = true }
            if let manager = state.manager { return Task { manager } }
            if let loading = state.loading { return loading }
            let loading = Task {
                let models = try await AsrModels.downloadAndLoad(version: Parakeet.version)
                let manager = AsrManager(config: .default)
                try await manager.loadModels(models)
                return manager
            }
            state.loading = loading
            return loading
        }
        do {
            let manager = try await task.value
            state.withLock { state in
                if state.loading == task { state.loading = nil }
                if state.wanted, state.manager == nil { state.manager = manager }
            }
            return manager
        } catch {
            state.withLock { state in
                if state.loading == task { state.loading = nil }
            }
            throw TranscriptionError.local("Parakeet: \(error.localizedDescription)")
        }
    }

    /// Frees the model's memory once no transcription holds it (it is not
    /// cleaned up under a running one). A load still running finishes but is dropped.
    public func unload() {
        state.withLock { state in
            state.wanted = false
            state.manager = nil
        }
    }

    public func transcribe(_ file: URL, model: String, language: String?) async throws -> String {
        let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
        guard size > 0 else { throw TranscriptionError.emptyRecording }
        let manager = try await load(keep: false)
        let samples: [Float]
        do {
            samples = try AudioConverter().resampleAudioFile(path: file.path)
        } catch {
            throw TranscriptionError.local("Parakeet could not read the recording: \(error.localizedDescription)")
        }
        // Under a quarter second there is nothing to hear. The model refuses less than
        // its minimum (0.3 s), so a short word is padded with silence.
        guard samples.count >= 4_000 else { return "" }
        let minimum = ASRConstants.minimumRequiredSamples(forSampleRate: 16_000)
        let padded = samples + [Float](repeating: 0, count: max(0, minimum - samples.count))
        var decoder = TdtDecoderState.make()
        do {
            let result = try await manager.transcribe(padded, decoderState: &decoder, language: Parakeet.hint(language))
            return Transcript.clean(result.text)
        } catch {
            throw TranscriptionError.local("Parakeet: \(error.localizedDescription)")
        }
    }
}
