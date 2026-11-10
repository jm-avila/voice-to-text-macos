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

/// What can be done right now. Every entry point checks it, and `vtt status` lists it.
enum DictationAction: String, CaseIterable {
    case start, stop, cancel, retry
}

/// What Retry sends again after a failure.
enum Retryable: Equatable {
    /// The last recording, kept in the store.
    case recording
    /// A file dropped on the menu bar icon.
    case file(URL)
}

/// The result the HUD shows for a moment after a dictation.
enum Notice: Equatable {
    case pasted, copied, nothingHeard, canceled
    case error(String)

    var duration: Duration { if case .error = self { .seconds(4) } else { .seconds(1.2) } }

    /// For `vtt status`.
    var name: String {
        switch self {
        case .pasted: "pasted"
        case .copied: "copied"
        case .nothingHeard: "nothingHeard"
        case .canceled: "canceled"
        case .error: "failed"
        }
    }
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
        case .nothingToRetry: "there is no failed recording or file to retry"
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

/// One opening of the mic, and where its samples go while it records.
private final class Mic {
    let opening: Task<Void, Error>
    /// Local Whisper with its server loaded: transcribed while it is spoken.
    let stream: StreamingTranscription?
    /// Parakeet: kept for key-up.
    let buffer: SampleBuffer?

    init(opening: Task<Void, Error>, stream: StreamingTranscription?, buffer: SampleBuffer?) {
        self.opening = opening
        self.stream = stream
        self.buffer = buffer
    }
}

/// One transcription. A cancel leaves it running and throws its text away.
private final class Job {
    /// What Retry sends again if it fails or is canceled.
    let source: Retryable
    var stream: StreamingTranscription?

    init(_ source: Retryable) { self.source = source }
}

/// Where a dictation is. Each case holds what only it has, so a stream with no
/// mic, or a cancel left over from an earlier start, cannot happen.
private enum Phase {
    case idle
    /// A modifiers-only shortcut is held: the mic opens, unseen, before it fires on release.
    case priming(Mic)
    /// The mic is opening. A cancel now stops it as soon as it is open.
    case starting(Mic, cancelRequested: Bool)
    case recording(Mic, since: Date)
    case transcribing(Job)
}

/// Push to talk: start, stop, transcribe, paste, save. The hotkey, the menu,
/// and the agent CLI all go through here, so there is one state to trust.
@Observable
final class Dictation {
    static let micTimeout: Duration = .seconds(10)
    /// Shorter than this is a press and a change of mind: nothing to send.
    static let shortest: TimeInterval = 0.3

    private var phase = Phase.idle
    private(set) var notice: Notice?
    /// The last result, kept after the notice fades (`vtt status`).
    private(set) var lastOutcome: Notice?
    private(set) var lastError: String?
    /// Every saved transcript, oldest first.
    private(set) var history: [HistoryEntry]
    /// The last try failed (or was canceled while transcribing), and what Retry sends again.
    private(set) var retryable: Retryable?
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
    @ObservationIgnored private var noticeTask: Task<Void, Never>?
    /// The recorder still closing after a cancel or a dropped early mic. The next start waits for it.
    @ObservationIgnored private var canceling: Task<Void, Never>?

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

    /// What the person sees. The early mic of a held shortcut is unseen: idle.
    var state: DictationState {
        switch phase {
        case .idle, .priming: .idle
        case .starting: .starting
        case .recording(_, let since): .recording(since: since)
        case .transcribing: .transcribing
        }
    }

    /// The state with the unseen one too: idle, priming, starting, recording, transcribing.
    var phaseName: String {
        if case .priming = phase { "priming" } else { state.name }
    }

    var canRetry: Bool { retryable != nil }

    var elapsed: TimeInterval {
        if case .recording(_, let since) = phase { Date.now.timeIntervalSince(since) } else { 0 }
    }

    /// The one table of what each state allows.
    func allows(_ action: DictationAction) -> Bool {
        switch (phase, action) {
        case (.idle, .start), (.priming, .start): true
        case (.idle, .retry), (.priming, .retry): retryable != nil
        case (.recording, .stop): true
        case (.starting, .cancel), (.recording, .cancel), (.transcribing, .cancel): true
        default: false
        }
    }

    var allowedActions: [DictationAction] { DictationAction.allCases.filter(allows) }

    /// The hotkey: start when idle, stop and paste when recording. Presses
    /// while the mic opens or while transcribing are ignored.
    func toggle() async {
        switch phase {
        case .idle, .priming:
            if !blocked() { try? await start(adoptingEarly: true) } else { await dropEarly()?.value }
        case .recording: _ = try? await stop(paste: true)
        case .starting, .transcribing: break
        }
    }

    /// A modifiers-only shortcut is held: the mic starts opening now, before
    /// it is let go (that is when it fires). Nothing shows until then. If it was
    /// another shortcut (⌥⌘I), `dropEarly` throws the audio away.
    func openEarly() {
        // Opening the mic deletes the kept recording, which a failed one needs for Retry.
        guard case .idle = phase, retryable == nil, ready() else { return }
        let mic = openMic()
        phase = .priming(mic)
        // Held and never let go, or the release was missed: never leave the mic open unseen.
        Task { [weak self] in
            try? await Task.sleep(for: Self.earlyLimit)
            guard let self, case .priming(let held) = self.phase, held === mic else { return }
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
    @discardableResult
    func dropEarly() -> Task<Void, Never>? {
        guard case .priming(let mic) = phase else { return nil }
        phase = .idle
        return close(mic)
    }

    /// Returns once the mic is live. Only the shortcut's release adopts the mic its
    /// press opened: anything else (the CLI) would get speech from before it started.
    func start(adoptingEarly: Bool = false) async throws {
        guard allows(.start) else { throw DictationError.busy(state.name) }
        var early: Mic?
        if case .priming(let mic) = phase {
            if adoptingEarly { early = mic } else { dropEarly() }
        }
        // Starting replaces the kept recording, so it cannot be retried any more.
        retryable = nil
        let mic = early ?? openMic()
        update(.starting(mic, cancelRequested: false))
        do {
            try await mic.opening.value
        } catch {
            mic.stream?.cancel()
            fail(error)
            throw error
        }
        guard case .starting(let current, let cancelRequested) = phase, current === mic, !cancelRequested else {
            mic.stream?.cancel()
            await recorder.cancel()
            update(.idle, notice: .canceled)
            throw DictationError.canceled
        }
        update(.recording(mic, since: .now))
        if settings.sounds { sounds.play(.start) }
    }

    /// Starts the recorder, with the stream (Whisper) or buffer (Parakeet) for its samples.
    private func openMic() -> Mic {
        let stream = makeStream()
        let buffer = stream == nil && settings.model == Parakeet.model && sampler != nil ? SampleBuffer() : nil
        // A method of the stream or buffer, not a closure written here: this file runs
        // on the main actor, and the samples arrive on the recorder's queue.
        let onAudio = stream?.append ?? buffer?.append
        let url = store.recordingURL
        let opening = Task { [recorder, canceling] in
            await canceling?.value
            try await recorder.start(to: url, timeout: Self.micTimeout, onAudio: onAudio)
        }
        return Mic(opening: opening, stream: stream, buffer: buffer)
    }

    /// Stops sending its samples anywhere and closes the recorder once it has opened.
    private func close(_ mic: Mic) -> Task<Void, Never> {
        mic.stream?.cancel()
        let task = Task { [recorder] in
            _ = try? await mic.opening.value
            await recorder.cancel()
        }
        canceling = task
        return task
    }

    /// Stops, transcribes, and saves to history. `paste` puts the text in
    /// the front app (the hotkey); the CLI only wants the text back.
    func stop(paste: Bool) async throws -> String {
        guard case .recording(let mic, _) = phase else { throw DictationError.notRecording }
        // The cue plays on the press: capture ends right after it.
        if settings.sounds { sounds.play(.stop) }
        let keyUp = ContinuousClock.now
        lastStreamed = false
        lastInMemory = false
        let job = Job(.recording)
        job.stream = mic.stream
        update(.transcribing(job))
        // After the recorder stopped: every sample is in the stream and the file is finished.
        let recorded = await recorder.stop()
        let samples = mic.buffer?.take()
        guard recorded >= Self.shortest else {
            mic.stream?.cancel()
            guard isCurrent(job) else { throw DictationError.canceled }
            update(.idle, notice: .nothingHeard)
            return ""
        }
        // All of it, or the file. The recorder hands over every sample it writes, so
        // this only fails past the buffer's limit (a very long dictation).
        let whole = samples.flatMap { Double($0.count) >= recorded * Double(WAV.rate) * 0.9 ? $0 : nil }
        return try await transcribeRecording(job, paste: paste, samples: whole, since: keyUp)
    }

    /// Sends the last failed recording or dropped file again.
    func retry(paste: Bool) async throws -> String {
        guard case .idle = state else { throw DictationError.busy(state.name) }
        guard let retryable else { throw DictationError.nothingToRetry }
        switch retryable {
        case .file(let file):
            return try await transcribeDropped(file)
        case .recording:
            dropEarly()
            let job = Job(.recording)
            update(.transcribing(job))
            return try await transcribeRecording(job, paste: paste, since: .now)
        }
    }

    /// Throws the recording away. While the mic is still opening, it stops
    /// as soon as it opens. While transcribing, it stops waiting: the text is
    /// dropped and Retry sends it again. True when there was something to cancel.
    @discardableResult
    func cancel() async -> Bool {
        switch phase {
        case .starting(let mic, _):
            phase = .starting(mic, cancelRequested: true)
            return true
        case .recording(let mic, _):
            // Idle first, so a press while the recorder stops cannot also stop and transcribe.
            update(.idle, notice: .canceled)
            await close(mic).value
            return true
        case .transcribing(let job):
            job.stream?.cancel()
            retryable = job.source
            update(.idle, notice: .canceled)
            return true
        case .idle, .priming:
            return false
        }
    }

    /// Any audio file, with the current model and language. Not saved to history.
    func transcribe(file: URL) async throws -> String {
        try await transcriber.transcribe(file, model: settings.model, language: settings.languageCode)
    }

    /// A file dropped on the menu bar icon: transcribed, saved to history, and copied.
    func transcribeDropped(_ file: URL) async throws -> String {
        guard case .idle = state else { throw DictationError.busy(state.name) }
        // ⌥⌘ held while a file is dropped: that mic was not for this.
        dropEarly()
        let job = Job(.file(file))
        update(.transcribing(job))
        let text: String
        do {
            text = try await transcriber.transcribe(file, model: settings.model, language: settings.languageCode)
        } catch {
            guard isCurrent(job) else { throw DictationError.canceled }
            retryable = .file(file)
            fail(error)
            throw error
        }
        guard isCurrent(job) else { throw DictationError.canceled }
        if retryable == .file(file) { retryable = nil }
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
    /// While dictating it only copies: the pill keeps showing the dictation.
    func copy(_ text: String) {
        paster.copy(text)
        if state == .idle { show(.copied) }
    }

    /// A stream when the local model's server is ready: the language is the one chosen at the start.
    private func makeStream() -> StreamingTranscription? {
        guard settings.model == LocalWhisper.model, let streamer, streamer.isReady else { return nil }
        let language = settings.languageCode
        return StreamingTranscription { wav, prompt in
            try await streamer.transcribe(wav: wav, language: language, prompt: prompt)
        }
    }

    /// The job is still the one being transcribed: no cancel came since.
    private func isCurrent(_ job: Job) -> Bool {
        if case .transcribing(let current) = phase { current === job } else { false }
    }

    /// The streamed text, Parakeet's from the samples in memory, or the whole
    /// file when there was neither or they failed.
    private func transcribeRecording(_ job: Job, paste: Bool, samples: [Float]? = nil,
                                     since start: ContinuousClock.Instant) async throws -> String {
        let text: String
        do {
            lastStreamed = false
            lastInMemory = false
            let language = settings.languageCode
            if let stream = job.stream, let streamed = try? await stream.finish() {
                text = streamed
                lastStreamed = true
            } else if settings.model == Parakeet.model, let samples, let sampler, isCurrent(job),
                      let heard = try? await sampler.transcribe(samples: samples, language: language) {
                text = heard
                lastInMemory = true
            } else {
                guard isCurrent(job) else { throw DictationError.canceled }
                text = try await transcriber.transcribe(store.recordingURL, model: settings.model, language: settings.languageCode)
            }
            lastLatency = start.duration(to: .now)
        } catch {
            guard isCurrent(job) else { throw DictationError.canceled }
            retryable = FileManager.default.fileExists(atPath: store.recordingURL.path) ? .recording : nil
            fail(error)
            throw error
        }
        guard isCurrent(job) else { throw DictationError.canceled }
        retryable = nil
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
    private func update(_ phase: Phase, notice: Notice? = nil) {
        self.phase = phase
        show(notice)
    }

    /// A notice is the result of a dictation: it shows only once back to ready, never over a live one.
    private func show(_ notice: Notice?) {
        noticeTask?.cancel()
        let notice = state == .idle ? notice : nil
        self.notice = notice
        if let notice {
            lastOutcome = notice
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
