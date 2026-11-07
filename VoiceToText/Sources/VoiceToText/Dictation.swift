import AppKit
import Observation
import VoiceToTextKit

enum DictationState: Equatable {
    case idle
    /// The mic is opening: don't talk yet.
    case starting
    /// The mic is live.
    case recording(since: Date)
    case transcribing

    var name: String {
        switch self {
        case .idle: "idle"
        case .starting: "starting"
        case .recording: "recording"
        case .transcribing: "transcribing"
        }
    }
}

/// The result the HUD shows for a moment after a dictation.
enum Notice: Equatable {
    case pasted, copied, nothingHeard, canceled
    case error(String)

    var duration: Duration { if case .error = self { .seconds(4) } else { .seconds(1.2) } }
}

nonisolated enum DictationError: LocalizedError {
    case busy(String)
    case notRecording
    case nothingToRetry
    case canceled

    var errorDescription: String? {
        switch self {
        case .busy(let state): state == "recording" ? "already recording" : "busy: \(state)"
        case .notRecording: "not recording"
        case .nothingToRetry: "there is no failed recording to retry"
        case .canceled: "canceled"
        }
    }
}

/// Puts text on the pasteboard and presses ⌘V in the front app. The text
/// stays on the clipboard afterwards, like the bash tool.
final class Paster {
    let pasteboard: NSPasteboard
    /// Off in the self-test and snapshots: they never type into your apps.
    var postsPaste = true
    /// Whether ⌘V may be sent (Accessibility). The self-test swaps it.
    var canPaste: () -> Bool = { AXIsProcessTrusted() }
    private(set) var last: (text: String, pasted: Bool)?

    init(pasteboard: NSPasteboard) {
        self.pasteboard = pasteboard
    }

    /// True when it pasted; false when the text is only on the clipboard.
    func paste(_ text: String) async -> Bool {
        copy(text)
        let pasted = canPaste()
        if pasted, postsPaste {
            // Let the pasteboard settle before the front app reads it.
            try? await Task.sleep(for: .milliseconds(60))
            SyntheticEvents.paste()
        }
        last = (text, pasted)
        return pasted
    }

    func copy(_ text: String) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}

/// Tink when the mic is live, Pop when recording stops.
final class Sounds {
    enum Cue: String { case start = "Tink", stop = "Pop" }

    /// Off in the self-test and snapshots: they check the cue without the noise.
    var audible = true
    private(set) var lastCue: Cue?
    /// How many cues played, audible or not.
    private(set) var plays = 0
    /// A playing NSSound must stay referenced, or it stops.
    private var sounds: [Cue: NSSound] = [:]

    func play(_ cue: Cue) {
        lastCue = cue
        plays += 1
        guard audible, let sound = sounds[cue] ?? NSSound(named: cue.rawValue) else { return }
        sounds[cue] = sound
        sound.stop()
        sound.play()
    }
}

/// Push to talk: start, stop, transcribe, paste, save. The hotkey, the menu,
/// and the agent CLI all go through here, so there is one state to trust.
@Observable
final class Dictation {
    static let micTimeout: Duration = .seconds(10)
    /// Shorter than this is a press and a change of mind: nothing to send.
    static let shortest: TimeInterval = 0.3

    private(set) var state = DictationState.idle
    private(set) var notice: Notice?
    private(set) var lastError: String?
    /// Every saved transcript, oldest first.
    private(set) var history: [HistoryEntry]
    /// The last recording failed to transcribe and is still on disk.
    private(set) var canRetry = false
    /// How many tries failed so far. The menu bar dot shows until the menu opens after one.
    private(set) var failures = 0
    /// Key-up to text of the last dictation: how fast it felt.
    private(set) var lastLatency: Duration?
    /// The last dictation was transcribed while it was spoken (no whole file at key-up).
    private(set) var lastStreamed = false
    /// The last dictation went to Parakeet from memory, not through the file.
    private(set) var lastInMemory = false
    var settings: DictationSettings {
        didSet {
            guard settings != oldValue else { return }
            store.save(settings)
            onChange()   // the menu bar icon follows clickToDictate and hideWhenIdle
            onSettingsChange()
        }
    }

    @ObservationIgnored let store: Store
    @ObservationIgnored let recorder: AudioRecording
    @ObservationIgnored let transcriber: Transcribing
    /// The local model's server: pieces go to it while the person talks. nil: whole files only.
    @ObservationIgnored let streamer: ChunkTranscribing?
    /// Parakeet: the samples go to it from memory at key-up. nil: the file.
    @ObservationIgnored let sampler: SampleTranscribing?
    @ObservationIgnored let paster: Paster
    @ObservationIgnored let sounds = Sounds()
    /// Runs after every change of state or notice: the status item and HUD redraw.
    @ObservationIgnored var onChange: () -> Void = {}
    /// Runs after the settings change: the local model's server starts or stops with the model.
    @ObservationIgnored var onSettingsChange: () -> Void = {}
    /// True when the hotkey, the menu, or a click must not start: the mic or
    /// paste is missing. It shows the person what to allow instead. The CLI skips it.
    @ObservationIgnored var blocked: () -> Bool = { false }
    /// The mic and paste are allowed, asked without showing anything (for `openEarly`).
    @ObservationIgnored var ready: () -> Bool = { true }
    @ObservationIgnored private var cancelRequested = false
    @ObservationIgnored private var noticeTask: Task<Void, Never>?
    /// A cancel still stopping the recorder. The next start waits for it.
    @ObservationIgnored private var canceling: Task<Void, Never>?
    /// The dictation being transcribed while it is spoken (local model, server ready).
    @ObservationIgnored private var stream: StreamingTranscription?
    /// The dictation's samples, kept for Parakeet.
    @ObservationIgnored private var buffer: SampleBuffer?
    /// The mic opened on the press of a modifiers-only shortcut, before it fired.
    @ObservationIgnored private var early: Task<Void, Error>?

    init(store: Store, recorder: AudioRecording, transcriber: Transcribing, streamer: ChunkTranscribing? = nil,
         sampler: SampleTranscribing? = nil, paster: Paster) {
        self.store = store
        self.recorder = recorder
        self.transcriber = transcriber
        self.streamer = streamer
        self.sampler = sampler
        self.paster = paster
        settings = store.loadSettings()
        history = store.loadHistory()
    }

    var elapsed: TimeInterval {
        if case .recording(let since) = state { Date.now.timeIntervalSince(since) } else { 0 }
    }

    /// The hotkey: start when idle, stop and paste when recording. Presses
    /// while the mic opens or while transcribing are ignored.
    func toggle() async {
        switch state {
        case .idle:
            if !blocked() { try? await start(adoptingEarly: true) } else { await dropEarly()?.value }
        case .recording: _ = try? await stop(paste: true)
        // A release that starts nothing must not leave its press's mic open.
        case .starting, .transcribing: dropEarly()
        }
    }

    /// A modifiers-only shortcut is held: the mic starts opening now, before
    /// it is let go (that is when it fires). Nothing shows until then. If it was
    /// another shortcut (⌥⌘I), `dropEarly` throws the audio away.
    func openEarly() {
        // Opening the mic deletes the kept recording, which a failed one needs for Retry.
        guard state == .idle, early == nil, !canRetry, ready() else { return }
        let opening = openMic()
        early = opening
        // Held and never let go, or the release was missed: never leave the mic open unseen.
        Task { [weak self] in
            try? await Task.sleep(for: Self.earlyLimit)
            guard let self, self.early == opening else { return }
            self.dropEarly()
            self.onEarlyExpired()
        }
    }

    /// The early mic hit its limit: a hold that long is not a tap, so its release must not start.
    @ObservationIgnored var onEarlyExpired: () -> Void = {}

    /// How long the mic may stay open before the shortcut fires.
    static let earlyLimit: Duration = .seconds(3)

    /// The early mic was not for dictating: close it and forget what it heard.
    /// At once (a press right after can open it again); the task finishes closing it.
    /// Whatever the state: only `start` takes `early`, so its stream and buffer are still its own.
    @discardableResult
    func dropEarly() -> Task<Void, Never>? {
        guard let early else { return nil }
        self.early = nil
        dropStream()
        let task = Task { [recorder] in
            _ = try? await early.value
            await recorder.cancel()
        }
        canceling = task
        return task
    }

    /// Returns once the mic is live. Only the shortcut's release adopts the mic its
    /// press opened: anything else (the CLI) would get speech from before it started.
    func start(adoptingEarly: Bool = false) async throws {
        guard state == .idle else { throw DictationError.busy(state.name) }
        if !adoptingEarly { dropEarly() }
        cancelRequested = false
        // Starting replaces the kept recording, so it cannot be retried any more.
        canRetry = false
        update(.starting)
        let opening = early ?? openMic()
        early = nil
        do {
            try await opening.value
        } catch {
            dropStream()
            fail(error)
            throw error
        }
        if cancelRequested {
            dropStream()
            await recorder.cancel()
            update(.idle, notice: .canceled)
            throw DictationError.canceled
        }
        update(.recording(since: .now))
        if settings.sounds { sounds.play(.start) }
    }

    /// Starts the recorder, with the stream (Whisper) or buffer (Parakeet) for its samples.
    private func openMic() -> Task<Void, Error> {
        let stream = makeStream()
        self.stream = stream
        let buffer = stream == nil && settings.model == Parakeet.model && sampler != nil ? SampleBuffer() : nil
        self.buffer = buffer
        // A method of the stream or buffer, not a closure written here: this file runs
        // on the main actor, and the samples arrive on the recorder's queue.
        let onAudio = stream?.append ?? buffer?.append
        let url = store.recordingURL
        return Task { [recorder, canceling] in
            await canceling?.value
            try await recorder.start(to: url, timeout: Self.micTimeout, onAudio: onAudio)
        }
    }

    /// Stops, transcribes, and saves to history. `paste` puts the text in
    /// the front app (the hotkey); the CLI only wants the text back.
    func stop(paste: Bool) async throws -> String {
        guard case .recording = state else { throw DictationError.notRecording }
        // The cue plays on the press: capture ends right after it.
        if settings.sounds { sounds.play(.stop) }
        let keyUp = ContinuousClock.now
        lastStreamed = false
        lastInMemory = false
        update(.transcribing)
        // After the recorder stopped: every sample is in the stream and the file is finished.
        let recorded = await recorder.stop()
        let stream = self.stream
        self.stream = nil
        let samples = buffer?.take()
        buffer = nil
        guard recorded >= Self.shortest else {
            stream?.cancel()
            update(.idle, notice: .nothingHeard)
            return ""
        }
        // All of it, or the file. The recorder hands over every sample it writes, so
        // this only fails past the buffer's limit (a very long dictation).
        let whole = samples.flatMap { Double($0.count) >= recorded * Double(WAV.rate) * 0.9 ? $0 : nil }
        return try await transcribeRecording(paste: paste, stream: stream, samples: whole, since: keyUp)
    }

    /// Sends the kept recording again, after a failure (network, key).
    func retry(paste: Bool) async throws -> String {
        guard state == .idle else { throw DictationError.busy(state.name) }
        guard canRetry else { throw DictationError.nothingToRetry }
        update(.transcribing)
        return try await transcribeRecording(paste: paste, since: .now)
    }

    /// Throws the recording away. While the mic is still opening, it stops
    /// as soon as it opens.
    func cancel() async {
        switch state {
        case .starting:
            cancelRequested = true
        case .recording:
            // Idle first, so a press while the recorder stops cannot also stop and transcribe.
            update(.idle, notice: .canceled)
            dropStream()
            let task = Task { [recorder] in await recorder.cancel() }
            canceling = task
            await task.value
        case .idle, .transcribing:
            break
        }
    }

    /// Any audio file, with the current model and language. Not saved to history.
    func transcribe(file: URL) async throws -> String {
        try await transcriber.transcribe(file, model: settings.model, language: settings.languageCode)
    }

    /// A file dropped on the menu bar icon: transcribed, saved to history, and copied.
    func transcribeDropped(_ file: URL) async throws -> String {
        guard state == .idle else { throw DictationError.busy(state.name) }
        update(.transcribing)
        let text: String
        do {
            text = try await transcriber.transcribe(file, model: settings.model, language: settings.languageCode)
        } catch {
            fail(error)
            throw error
        }
        lastError = nil
        guard !text.isEmpty else {
            update(.idle, notice: .nothingHeard)
            return ""
        }
        save(text)
        paster.copy(text)
        update(.idle, notice: .copied)
        return text
    }

    /// Reads history.md again: the bash tool or a person may have changed it.
    /// The menu, Settings, and `vtt history list` call it before they show it.
    func reloadHistory() {
        history = store.loadHistory()
    }

    /// Puts an older transcript back on the clipboard (the menu's Recent items).
    func copy(_ text: String) {
        paster.copy(text)
        update(state, notice: .copied)
    }

    /// A stream when the local model's server is ready: the language is the one chosen at the start.
    private func makeStream() -> StreamingTranscription? {
        guard settings.model == LocalWhisper.model, let streamer, streamer.isReady else { return nil }
        let language = settings.languageCode
        return StreamingTranscription { wav, prompt in
            try await streamer.transcribe(wav: wav, language: language, prompt: prompt)
        }
    }

    private func dropStream() {
        stream?.cancel()
        stream = nil
        buffer = nil
    }

    /// The streamed text, Parakeet's from the samples in memory, or the whole
    /// file when there was neither or they failed.
    private func transcribeRecording(paste: Bool, stream: StreamingTranscription? = nil, samples: [Float]? = nil,
                                     since start: ContinuousClock.Instant) async throws -> String {
        let text: String
        do {
            lastStreamed = false
            lastInMemory = false
            let language = settings.languageCode
            if let stream, let streamed = try? await stream.finish() {
                text = streamed
                lastStreamed = true
            } else if settings.model == Parakeet.model, let samples, let sampler,
                      let heard = try? await sampler.transcribe(samples: samples, language: language) {
                text = heard
                lastInMemory = true
            } else {
                text = try await transcriber.transcribe(store.recordingURL, model: settings.model, language: settings.languageCode)
            }
            lastLatency = start.duration(to: .now)
        } catch {
            canRetry = FileManager.default.fileExists(atPath: store.recordingURL.path)
            fail(error)
            throw error
        }
        canRetry = false
        lastError = nil
        guard !text.isEmpty else {
            update(.idle, notice: .nothingHeard)
            return ""
        }
        save(text)
        if paste {
            let pasted = await paster.paste(text)
            update(.idle, notice: pasted ? .pasted : .copied)
        } else {
            update(.idle)
        }
        return text
    }

    private func save(_ text: String) {
        let now = Date.now
        do {
            try store.appendHistory(text, at: now)
            history.append(HistoryEntry(date: HistoryLog.stamp(now), text: text))
        } catch {
            lastError = "Could not save to history: \(error.localizedDescription)"
        }
    }

    private func fail(_ error: Error) {
        let message = error.localizedDescription
        lastError = message
        failures += 1
        update(.idle, notice: .error(message))
    }

    /// One place that changes what the person sees, then redraws once.
    private func update(_ state: DictationState, notice: Notice? = nil) {
        self.state = state
        noticeTask?.cancel()
        self.notice = notice
        if let notice {
            noticeTask = Task { [weak self] in
                try? await Task.sleep(for: notice.duration)
                guard !Task.isCancelled, let self else { return }
                self.notice = nil
                self.onChange()
            }
        }
        onChange()
    }
}
