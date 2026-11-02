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

    private(set) var state = DictationState.idle
    private(set) var notice: Notice?
    private(set) var lastError: String?
    /// Every saved transcript, oldest first.
    private(set) var history: [HistoryEntry]
    /// The last recording failed to transcribe and is still on disk.
    private(set) var canRetry = false
    var settings: DictationSettings {
        didSet { if settings != oldValue { store.save(settings) } }
    }

    @ObservationIgnored let store: Store
    @ObservationIgnored let recorder: AudioRecording
    @ObservationIgnored let transcriber: Transcribing
    @ObservationIgnored let paster: Paster
    @ObservationIgnored let sounds = Sounds()
    /// Runs after every change of state or notice: the status item and HUD redraw.
    @ObservationIgnored var onChange: () -> Void = {}
    @ObservationIgnored private var cancelRequested = false
    @ObservationIgnored private var noticeTask: Task<Void, Never>?

    init(store: Store, recorder: AudioRecording, transcriber: Transcribing, paster: Paster) {
        self.store = store
        self.recorder = recorder
        self.transcriber = transcriber
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
        case .idle: try? await start()
        case .recording: _ = try? await stop(paste: true)
        case .starting, .transcribing: break
        }
    }

    /// Returns once the mic is live.
    func start() async throws {
        guard state == .idle else { throw DictationError.busy(state.name) }
        cancelRequested = false
        update(.starting)
        do {
            try await recorder.start(to: store.recordingURL, timeout: Self.micTimeout)
        } catch {
            fail(error)
            throw error
        }
        if cancelRequested {
            await recorder.cancel()
            update(.idle, notice: .canceled)
            throw DictationError.canceled
        }
        canRetry = false
        update(.recording(since: .now))
        if settings.sounds { sounds.play(.start) }
    }

    /// Stops, transcribes, and saves to history. `paste` puts the text in
    /// the front app (the hotkey); the CLI only wants the text back.
    func stop(paste: Bool) async throws -> String {
        guard case .recording = state else { throw DictationError.notRecording }
        // The cue plays on the press: capture ends right after it.
        if settings.sounds { sounds.play(.stop) }
        update(.transcribing)
        _ = await recorder.stop()
        return try await transcribeRecording(paste: paste)
    }

    /// Sends the kept recording again, after a failure (network, key).
    func retry(paste: Bool) async throws -> String {
        guard state == .idle else { throw DictationError.busy(state.name) }
        guard canRetry else { throw DictationError.nothingToRetry }
        update(.transcribing)
        return try await transcribeRecording(paste: paste)
    }

    /// Throws the recording away. While the mic is still opening, it stops
    /// as soon as it opens.
    func cancel() async {
        switch state {
        case .starting:
            cancelRequested = true
        case .recording:
            await recorder.cancel()
            update(.idle, notice: .canceled)
        case .idle, .transcribing:
            break
        }
    }

    /// Any audio file, with the current model and language. Not saved to history.
    func transcribe(file: URL) async throws -> String {
        try await transcriber.transcribe(file, model: settings.model, language: settings.languageCode)
    }

    /// Reads history.md again (seed data, or the bash tool wrote to it).
    func reloadHistory() {
        history = store.loadHistory()
    }

    /// Puts an older transcript back on the clipboard (the menu's Recent items).
    func copy(_ text: String) {
        paster.copy(text)
        update(state, notice: .copied)
    }

    private func transcribeRecording(paste: Bool) async throws -> String {
        let text: String
        do {
            text = try await transcriber.transcribe(store.recordingURL, model: settings.model, language: settings.languageCode)
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
        let now = Date.now
        try? store.appendHistory(text, at: now)
        history.append(HistoryEntry(date: HistoryLog.stamp(now), text: text))
        if paste {
            let pasted = await paster.paste(text)
            update(.idle, notice: pasted ? .pasted : .copied)
        } else {
            update(.idle)
        }
        return text
    }

    private func fail(_ error: Error) {
        let message = error.localizedDescription
        lastError = message
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
