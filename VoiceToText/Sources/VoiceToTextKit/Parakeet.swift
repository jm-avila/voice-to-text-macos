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
/// A model that takes a dictation's samples straight from the recorder.
public protocol SampleTranscribing: Sendable {
    func transcribe(samples: [Float], language: String?) async throws -> String
}

public final class ParakeetTranscriber: Transcribing, SampleTranscribing, Sendable {
    private enum Phase {
        case off
        /// Runs to the end once started (a download can't be stopped halfway), so a
        /// pick, a switch away, and a pick again share one download. `kept`: Parakeet
        /// is selected; a load that finishes when it is not keeps nothing.
        case loading(Task<AsrManager, Error>, kept: Bool)
        case ready(AsrManager)
        case failed(String)
    }
    private let state = Mutex(Phase.off)

    public init() {}

    public var isLoaded: Bool { residency == .ready }
    public var isLoading: Bool { residency == .loading }

    public var residency: ModelResidency {
        state.withLock { phase in
            switch phase {
            case .off: .off
            case .loading: .loading
            case .ready: .ready
            case .failed(let reason): .failed(reason)
            }
        }
    }

    /// Loads (and the first time downloads) the model. Safe to call again while it loads.
    /// `keep` is for picking the model; a transcription joins the load without keeping
    /// it, so one that ends after the person switched away does not hold 600 MB.
    @discardableResult
    public func load(keep: Bool = true) async throws -> AsrManager {
        let task = state.withLock { phase -> Task<AsrManager, Error> in
            switch phase {
            case .ready(let manager):
                return Task { manager }
            case .loading(let loading, let kept):
                phase = .loading(loading, kept: kept || keep)
                return loading
            case .off, .failed:
                let loading = Task {
                    let models = try await AsrModels.downloadAndLoad(version: Parakeet.version)
                    let manager = AsrManager(config: .default)
                    try await manager.loadModels(models)
                    return manager
                }
                // A failed one was selected: loading it again for a dictation keeps it.
                if case .failed = phase { phase = .loading(loading, kept: true) } else { phase = .loading(loading, kept: keep) }
                return loading
            }
        }
        do {
            let manager = try await task.value
            state.withLock { phase in
                if case .loading(let current, let kept) = phase, current == task { phase = kept ? .ready(manager) : .off }
            }
            return manager
        } catch {
            let message = "Parakeet: \(error.localizedDescription)"
            state.withLock { phase in
                if case .loading(let current, let kept) = phase, current == task { phase = kept ? .failed(message) : .off }
            }
            throw TranscriptionError.local(message)
        }
    }

    /// Frees the model's memory once no transcription holds it (it is not
    /// cleaned up under a running one). A load still running finishes but is dropped.
    public func unload() {
        state.withLock { phase in
            // A load still running finishes, shared by a pick again, but keeps nothing.
            if case .loading(let loading, _) = phase { phase = .loading(loading, kept: false) } else { phase = .off }
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
        return try await transcribe(samples, with: manager, language: language)
    }

    /// The recorder's own 16 kHz mono samples, kept in memory while the person
    /// talks: no file to finish, read back, and resample at key-up.
    public func transcribe(samples: [Float], language: String?) async throws -> String {
        guard samples.count >= Self.audible else { return "" }
        return try await transcribe(samples, with: try await load(keep: false), language: language)
    }

    /// Under a quarter second there is nothing to hear.
    static let audible = 4_000

    private func transcribe(_ samples: [Float], with manager: AsrManager, language: String?) async throws -> String {
        // The model refuses less than its minimum (0.3 s), so a short word is padded with silence.
        guard samples.count >= Self.audible else { return "" }
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

/// The samples of one dictation, as the recorder hands them over (from its
/// queue), for a model that takes them whole at key-up.
/// Past `limit` (15 minutes: 58 MB) it lets go of them all and stays empty:
/// a long recording goes through the file instead of holding hundreds of MB.
public final class SampleBuffer: Sendable {
    private struct State {
        var samples: [Float] = []
        var full = false
    }
    private let state = Mutex(State())
    public let limit: Int

    public init(limit: Int = 15 * 60 * WAV.rate) {
        self.limit = limit
    }

    /// Safe from the recorder's queue.
    public func append(_ more: [Float]) {
        state.withLock { state in
            guard !state.full else { return }
            if state.samples.count + more.count > limit {
                state.full = true
                state.samples = []
            } else {
                state.samples += more
            }
        }
    }

    /// Everything so far, emptied. Empty once the limit was passed.
    public func take() -> [Float] {
        state.withLock { state in
            defer { state.samples = [] }
            return state.samples
        }
    }
}
