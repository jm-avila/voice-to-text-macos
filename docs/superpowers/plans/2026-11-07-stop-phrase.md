# Stop by Voice ("The End" / "Se acabó") Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** While a dictation is recording, saying "The End" or "Se acabó" on its own stops it exactly like a second press of the shortcut (transcribe, paste), without the phrase in the text.

**Architecture:** Three small pieces in `VoiceToTextKit`, each unit tested:
- `LoneUtterances` finds short sounds with a pause before and after, from the mic's 16 kHz samples.
- `StopPhrase` decides whether a transcript is the phrase.
- `StopPhraseListener` runs each lone utterance through Parakeet in the background and reports the first match.

`Dictation` arms a listener only for recordings started by the shortcut, the menu or the icon (and `vtt start --stop-phrase`). On a match it calls the existing `stop`, with the audio cut just before the phrase.

**Tech Stack:** Swift 6.2 package (Command Line Tools only), Swift Testing, FluidAudio Parakeet (`SampleTranscribing`), the app's self-test and `say`-based e2e scripts.

**Spec:** this plan's "Requirements" section below (from the conversation of 2026-11-07); the story S-017 added in Task 0.

## Requirements (from the user)

- User, verbatim: "i would like to only to stop a running recording"
- Choices: "Stop word" (not a silence timeout). Phrase: "The End in english, Se acabo in spanish. Make a plan because we are doing other changes in the app before this one."
- The phrase counts only when said on its own: a pause before and a pause after.
- Stopping by voice does what the second press does: Pop, transcribe, save to history, paste. The phrase is not in the text.

## Global Constraints

- **Depends on branch `parakeet-memory`** (in progress on 2026-11-07, not merged). This plan uses its `SampleTranscribing`, `SampleBuffer`, `Dictation.sampler` and `FakeTranscriber.transcribe(samples:language:)`. Start only after it is merged into `main`. Then branch `stop-phrase` from `main`.
- **Models:** works with Parakeet only (`Parakeet.model`, the default). With Whisper local or OpenAI the setting has no effect.
  - Whisper local: each check would cost about 430 ms of whisper-server time and compete with the streamed pieces.
  - OpenAI: each check would be a paid API call.
- **Phrases**, matched in any language setting: `the end` and `se acabo`, after folding case and accents.
- **Timing defaults:**
  - pause before: ≥ 0.4 s;
  - pause after: ≥ 0.6 s;
  - utterance: ≤ 2.0 s from the first sound to the last;
  - margin: 0.1 s kept on each side.
- **Setting:** `stopPhrase`, default `true`.
  - Settings label: "Stop by Voice".
  - Caption: "Say “The End” or “Se acabó” after a pause. Parakeet only."
  - CLI flag: `--stop-phrase`.
- **Isolation:** the app target has `.defaultIsolation(MainActor.self)`. Closures handed to the recorder's audio queue must be created in `VoiceToTextKit` (nonisolated), never as a closure literal in `Dictation.swift`. See the existing comment in `Dictation.start`.
- **Commit style:** `VoiceToText: <what changed>`.
- **Tracking:** one issue (Why / What / How, assigned to `jm-avila`) and one PR with `Closes #N`.

## Review Focus

1. **Dictated words that end like the phrase**, for example "…until the end. [pause] The End." Only the spoken phrase goes. "Until the end." stays, because the in-memory path cuts the audio and never strips text. Test: Task 5 self-test "words before the phrase that end like it stay".
2. **The phrase inside a sentence** ("Se acabó la reunión…", "The end of the month…") must not stop. The sentence goes on, so there is no pause after it, and the text is not the bare phrase. Tests: Task 1 `doesNotMatch`, Task 2 `sentenceGoesOn`, Task 6 e2e in-sentence clips.
3. **The shortcut pressed while a phrase check is running** must stop once: one history entry, one paste, and never two Parakeet runs at the same time. Test: Task 5 self-test "the shortcut during a phrase check stops once".
4. **The phrase said with nothing before it** gives no text and the "nothing heard" notice. Nothing is pasted, and the phrase is not pasted. Test: Task 5 self-test "only the phrase: nothing pasted".
5. **A check from a canceled recording** must not stop the next recording. Test: Task 5 self-test "a check from a canceled recording does not stop the next one".

---

### Task 0: Branch, issue, story

**Files:**
- Modify: `VoiceToText/docs/STORIES.md` (append after S-016)

- [ ] **Step 1: Branch from main once `parakeet-memory` is merged**

```bash
cd ~/Repositories/agent-workspace/repository/util/voice-to-text
git switch main && git pull --ff-only
git log --oneline -5 | rg -i "parakeet" # the memory change must be in main
rg -n "protocol SampleTranscribing" VoiceToText/Sources/VoiceToTextKit/Parakeet.swift   # must print a line
git switch -c stop-phrase
```

- [ ] **Step 2: Create the issue**

```bash
gh issue list --repo jm-avila/voice-to-text-macos --state all --search "stop phrase OR stop by voice"
gh issue create --repo jm-avila/voice-to-text-macos --assignee jm-avila \
  --title "Stop a recording by voice: \"The End\" / \"Se acabó\"" \
  --body-file /tmp/stop-phrase-issue.md
```

`/tmp/stop-phrase-issue.md` has three sections:
- **Why:** the Requirements section above, verbatim, plus these rejected alternatives:
  - silence timeout: the user picked a stop word;
  - a separate keyword-spotting model: Parakeet already answers in about 0.1 s;
  - Whisper and OpenAI: cost per pause.
- **What:** the setting, the CLI flag and the files of Tasks 1–6.
- **How:** this plan, with the verification checkboxes from Task 6.

- [ ] **Step 3: Add the story**

Append to `VoiceToText/docs/STORIES.md`:

```markdown
### S-017 Stop by voice
As the user, I end a dictation by saying "The End" or "Se acabó" after a pause, and the text is pasted without it, as if I had pressed the shortcut again.
Screens: Settings
Acceptance:
- [unit] The phrase alone matches however it is written ("¡Se acabó!", "THE END."); a sentence with it does not; strip takes it off the end only.
- [unit] Lone utterances: a short sound between a ≥ 0.4 s pause and a ≥ 0.6 s pause is found with its start; a sentence that goes on, or one without a pause before, is not; memory stays bounded.
- [unit] The listener calls back once, for the first lone utterance that is the phrase; failed or other checks keep listening; cancel drops a check in flight.
- [self] The shortcut's recording stops on the phrase, pastes, and the audio is cut before it; other words, the setting off, other models and a plain `vtt start` keep recording; `vtt start --stop-phrase` saves without pasting; the shortcut during a check stops once; a canceled recording's check stops nothing; the whole-file fallback strips the phrase.
- [e2e] `tools/stop-phrase.sh`: Spanish and English clips stop on the phrase, before the words after it; the phrase inside a sentence does not stop.
- [manual] Dictate into another app, pause, say "Se acabó": pasted without it in about a second. Say "se acabó la reunión" mid-sentence: keeps recording.
Status: in progress
```

- [ ] **Step 4: Commit**

```bash
git add VoiceToText/docs/STORIES.md docs/superpowers/plans/2026-11-07-stop-phrase.md
git commit -m "VoiceToText: story S-017 and plan for stopping a recording by voice"
```

---

### Task 1: `StopPhrase`, deciding whether a transcript is the phrase

**Files:**
- Create: `VoiceToText/Sources/VoiceToTextKit/StopPhrase.swift`
- Test: `VoiceToText/Tests/VoiceToTextKitTests/StopPhraseTests.swift`

**Interfaces:**
- Produces: `public enum StopPhrase { static func matches(_ text: String) -> Bool; static func strip(_ text: String) -> String }`

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
@testable import VoiceToTextKit

@Suite("S-017 The stop phrase")
struct StopPhraseTests {
    @Test("The phrase alone matches, however it is written", arguments: [
        "The End", "the end.", "THE END!", "Se acabó.", "se acabo", "¡Se acabó!", "  Se   acabó  ", "Seacabó", "The end…"])
    func matches(_ text: String) {
        #expect(StopPhrase.matches(text))
    }

    @Test("Anything more or less than the phrase does not", arguments: [
        "", "The", "End.", "The end of the month", "Se acabó la reunión", "Until the end", "Weekend",
        "Se acabaron", "The ends", "Se acaba"])
    func doesNotMatch(_ text: String) {
        #expect(!StopPhrase.matches(text))
    }

    @Test("Strip takes the phrase off the end, with its punctuation")
    func strip() {
        #expect(StopPhrase.strip("Mañana compramos pan. Se acabó.") == "Mañana compramos pan.")
        #expect(StopPhrase.strip("Call Maria, the end") == "Call Maria")
        #expect(StopPhrase.strip("Hola ¡se acabó!") == "Hola")
        #expect(StopPhrase.strip("The End.") == "")
    }

    @Test("Strip leaves the phrase in the middle, and words that only end like it")
    func stripKeeps() {
        #expect(StopPhrase.strip("The end of the month is near.") == "The end of the month is near.")
        #expect(StopPhrase.strip("Breathe end") == "Breathe end")
        #expect(StopPhrase.strip("Nothing to remove") == "Nothing to remove")
    }
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `(cd VoiceToText && tools/test.sh . --filter StopPhraseTests)`
Expected: build error `cannot find 'StopPhrase' in scope`.

- [ ] **Step 3: Implement**

```swift
import Foundation

/// "The End" or "Se acabó", said on its own, stops a dictation like a second press.
public enum StopPhrase {
    /// As `fold` writes them, without spaces: Parakeet sometimes joins the words.
    static let phrases: Set<String> = ["theend", "seacabo"]

    /// The whole text is a stop phrase: "Se acabó.", "THE END!", "se acabo".
    public static func matches(_ text: String) -> Bool {
        phrases.contains(fold(text))
    }

    /// Takes a stop phrase off the end of a transcript, with its punctuation.
    /// Only for audio that still has the phrase (the whole-file fallback): the
    /// samples in memory are cut before it instead, so earlier words stay.
    public static func strip(_ text: String) -> String {
        let ending = /[\s,;:]*¡?\b(?:se\s*acab[oó]|the\s*end)\b[\s.!?,;:…]*$/.ignoresCase()
        guard let match = text.firstMatch(of: ending) else { return text }
        return String(text[..<match.range.lowerBound])
    }

    /// Lower case, no accents, letters only.
    static func fold(_ text: String) -> String {
        String(text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).filter(\.isLetter))
    }
}
```

- [ ] **Step 4: Run the tests to see them pass**

Run: `(cd VoiceToText && tools/test.sh . --filter StopPhraseTests)`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add VoiceToText/Sources/VoiceToTextKit/StopPhrase.swift VoiceToText/Tests/VoiceToTextKitTests/StopPhraseTests.swift
git commit -m "VoiceToText: StopPhrase matches \"The End\" / \"Se acabó\" and strips it off a transcript"
```

---

### Task 2: `LoneUtterances`, finding what is said on its own

**Files:**
- Create: `VoiceToText/Sources/VoiceToTextKit/LoneUtterances.swift`
- Test: `VoiceToText/Tests/VoiceToTextKitTests/LoneUtterancesTests.swift`

**Interfaces:**
- Consumes: `SpeechChunker.frame` (320 samples), `SpeechChunker.silenceFloor`, `SpeechChunker.decibels(_:)` and `SpeechChunker.threshold(_:)`. These are internal statics in `Streaming.swift`, in the same module, so no change is needed. Also `WAV.rate`.
- Produces: `public struct LoneUtterances: Sendable { init(before:after:longest:margin:); mutating func append(_ samples: [Float]) -> [Utterance] }` and `public struct Utterance: Sendable, Equatable { let start: Int; let samples: [Float] }`. `start` is the sample index in the dictation.

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
@testable import VoiceToTextKit

/// Test audio at 16 kHz: speech is a loud tone, a pause is a faint one.
private func tone(_ seconds: Double, _ amplitude: Float) -> [Float] {
    (0..<Int(seconds * Double(WAV.rate))).map { amplitude * sin(Float($0) * 2 * .pi * 220 / Float(WAV.rate)) }
}
private func speech(_ seconds: Double) -> [Float] { tone(seconds, 0.3) }
private func pause(_ seconds: Double) -> [Float] { tone(seconds, 0.0005) }

/// Fed 100 ms at a time, like the microphone.
private func feed(_ samples: [Float], into finder: inout LoneUtterances) -> [LoneUtterances.Utterance] {
    stride(from: 0, to: samples.count, by: 1600).flatMap {
        finder.append(Array(samples[$0 ..< min($0 + 1600, samples.count)]))
    }
}

@Suite("S-017 Lone utterances")
struct LoneUtterancesTests {
    @Test("A short sound between two pauses is found, with where it starts in the dictation")
    func found() throws {
        var finder = LoneUtterances()
        let found = feed(speech(3) + pause(1) + speech(0.7) + pause(0.8), into: &finder)
        #expect(found.count == 1)
        let lone = try #require(found.first)
        // First loud frame at 4.0 s, minus the 0.1 s margin.
        #expect(abs(lone.start - (4 * WAV.rate - WAV.rate / 10)) <= SpeechChunker.frame)
        // 0.7 s of sound plus the margin on each side.
        #expect(abs(lone.samples.count - Int(0.9 * Double(WAV.rate))) <= 2 * SpeechChunker.frame)
    }

    @Test("A sentence that goes on past 2 s is not")
    func sentenceGoesOn() {
        var finder = LoneUtterances()
        #expect(feed(speech(3) + pause(1) + speech(2.5) + pause(1), into: &finder).isEmpty)
    }

    @Test("Words with short gaps count as one sentence")
    func shortGaps() {
        var finder = LoneUtterances()
        #expect(feed(pause(1) + speech(1) + pause(0.2) + speech(1.5) + pause(1), into: &finder).isEmpty)
    }

    @Test("Without a pause before, the end of a sentence is not on its own")
    func noPauseBefore() {
        var finder = LoneUtterances()
        #expect(feed(pause(1) + speech(3) + pause(0.2) + speech(0.6) + pause(1), into: &finder).isEmpty)
    }

    @Test("Without a pause after it yet, nothing is found")
    func noPauseAfter() {
        var finder = LoneUtterances()
        #expect(feed(speech(3) + pause(1) + speech(0.7) + pause(0.3), into: &finder).isEmpty)
    }

    @Test("Silence finds nothing")
    func silence() {
        var finder = LoneUtterances()
        #expect(feed(pause(3), into: &finder).isEmpty)
    }

    @Test("Two lone utterances are both found, in order")
    func two() {
        var finder = LoneUtterances()
        let found = feed(speech(3) + pause(1) + speech(0.6) + pause(1) + speech(0.6) + pause(1), into: &finder)
        #expect(found.count == 2)
        #expect(found.count == 2 && found[0].start < found[1].start)
    }

    @Test("A long dictation keeps only a few seconds of audio")
    func bounded() {
        var finder = LoneUtterances()
        for _ in 0..<10 { _ = feed(speech(5) + pause(0.2), into: &finder) }
        #expect(finder.keptSamples < 3 * WAV.rate)
    }
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `(cd VoiceToText && tools/test.sh . --filter LoneUtterancesTests)`
Expected: build error `cannot find 'LoneUtterances' in scope`.

- [ ] **Step 3: Implement**

```swift
import Foundation

/// Finds what is said on its own: a pause before, a pause after, and at most
/// `longest` seconds from the first sound to the last. "Se acabó" between two
/// pauses is one; a sentence that goes on is not. 16 kHz mono samples, the
/// same 20 ms frames and room-following threshold as `SpeechChunker`.
public struct LoneUtterances: Sendable {
    public struct Utterance: Sendable, Equatable {
        /// Where it starts in the dictation, in samples (a little before the first sound).
        public let start: Int
        public let samples: [Float]
    }

    public var before: Double
    public var after: Double
    public var longest: Double
    /// Kept on each side, so the first and last sounds are whole.
    public var margin: Double

    private static let framesPerSecond = 50.0
    /// Samples that don't make a whole 20 ms frame yet.
    private var pending: [Float] = []
    /// The audio an utterance could still need; `audio[0]` is sample `audioStart` of the dictation.
    private var audio: [Float] = []
    private var audioStart = 0
    /// Whole frames seen so far.
    private var frames = 0
    /// The last 10 s of frame levels, for telling speech from pause.
    private var recent: [Float] = []
    private var threshold = SpeechChunker.silenceFloor
    /// Quiet frames in a row. The start of a dictation counts as a pause.
    private var quietRun: Int
    /// The utterance being heard: its first and last loud frame.
    private var current: (first: Int, last: Int)?

    public init(before: Double = 0.4, after: Double = 0.6, longest: Double = 2, margin: Double = 0.1) {
        self.before = before
        self.after = after
        self.longest = longest
        self.margin = margin
        quietRun = Int(before * Self.framesPerSecond)
    }

    /// Samples kept in memory, for the test that they stay few.
    var keptSamples: Int { audio.count }

    /// Adds audio. Returns the utterances that just ended with a long enough pause.
    public mutating func append(_ samples: [Float]) -> [Utterance] {
        var found: [Utterance] = []
        audio += samples
        pending += samples
        let size = SpeechChunker.frame
        while pending.count >= size {
            let level = SpeechChunker.decibels(pending[..<size])
            pending.removeFirst(size)
            // Digital zeros (the first frames from a mic, a muted one) say nothing about the room.
            if level > -100 {
                recent.append(level)
                if recent.count > 500 { recent.removeFirst(recent.count - 500) }
                threshold = SpeechChunker.threshold(recent)
            }
            let frame = frames
            frames += 1
            if level > threshold {
                if var heard = current {
                    heard.last = frame
                    // Too long for a phrase: a sentence. Wait for the next pause.
                    current = Double(frame - heard.first) / Self.framesPerSecond > longest ? nil : heard
                } else if Double(quietRun) / Self.framesPerSecond >= before {
                    current = (frame, frame)
                }
                quietRun = 0
            } else {
                quietRun += 1
                if let heard = current, Double(quietRun) / Self.framesPerSecond >= after {
                    found.append(cut(heard))
                    current = nil
                }
            }
        }
        trim()
        return found
    }

    private func cut(_ heard: (first: Int, last: Int)) -> Utterance {
        let size = SpeechChunker.frame
        let pad = Int(margin * Double(WAV.rate))
        let from = max(audioStart, heard.first * size - pad)
        let to = min(audioStart + audio.count, (heard.last + 1) * size + pad)
        return Utterance(start: from, samples: Array(audio[(from - audioStart) ..< (to - audioStart)]))
    }

    /// Keeps the utterance being heard, or else only the margin an utterance starting next would need.
    private mutating func trim() {
        let keepFrom = (current?.first ?? frames) * SpeechChunker.frame - Int(margin * Double(WAV.rate))
        let drop = min(max(0, keepFrom - audioStart), audio.count)
        audio.removeFirst(drop)
        audioStart += drop
    }
}
```

- [ ] **Step 4: Run the tests to see them pass**

Run: `(cd VoiceToText && tools/test.sh . --filter LoneUtterancesTests)`
Expected: all pass. If `found` misses: the first 0.5 s has no threshold yet (fewer than 25 levels), and the first ~0.3 s of a pause after loud audio still counts as speech until 10% of `recent` is quiet. The tests' 1 s pauses allow for both. Do not shorten them.

- [ ] **Step 5: Commit**

```bash
git add VoiceToText/Sources/VoiceToTextKit/LoneUtterances.swift VoiceToText/Tests/VoiceToTextKitTests/LoneUtterancesTests.swift
git commit -m "VoiceToText: LoneUtterances finds short sounds between two pauses"
```

---

### Task 3: `StopPhraseListener` and `Tee`, checking while the person talks

**Files:**
- Modify: `VoiceToText/Sources/VoiceToTextKit/StopPhrase.swift` (append)
- Test: `VoiceToText/Tests/VoiceToTextKitTests/StopPhraseTests.swift` (append a suite)

**Interfaces:**
- Consumes: `LoneUtterances` (Task 2), `StopPhrase.matches` (Task 1).
- Produces:
  - `public final class StopPhraseListener: Sendable`:
    - `init(finder: LoneUtterances = .init(), transcribe: @escaping @Sendable ([Float]) async throws -> String, heard: @escaping @Sendable (Int) async -> Void)`
    - `func append(_ samples: [Float])`, safe from the audio queue.
    - `func cancel()`
    - `func cancelAndWait() async`
  - `public enum Tee { static func both(_ first: @escaping @Sendable ([Float]) -> Void, _ second: (@Sendable ([Float]) -> Void)?) -> @Sendable ([Float]) -> Void }`

- [ ] **Step 1: Write the failing tests**

Append to `StopPhraseTests.swift`. Add `import Synchronization` at the top of that file.

```swift
private func tone(_ seconds: Double, _ amplitude: Float) -> [Float] {
    (0..<Int(seconds * Double(WAV.rate))).map { amplitude * sin(Float($0) * 2 * .pi * 220 / Float(WAV.rate)) }
}
/// Speech, then two lone utterances: the first starts near 4.0 s, the second near 5.6 s.
private let twoLone = tone(3, 0.3) + tone(1, 0.0005) + tone(0.6, 0.3) + tone(1, 0.0005) + tone(0.6, 0.3) + tone(1, 0.0005)

private final class Calls: Sendable {
    let starts = Mutex<[Int]>([])
    let checks = Mutex(0)
    let finished = Mutex(false)
}

private final class Seen: Sendable {
    let names = Mutex<[String]>([])
}

private func wait(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }

@Suite("S-017 Listening for the stop phrase")
struct StopPhraseListenerTests {
    @Test("The first lone utterance that is the phrase calls back once, with its start")
    func heardOnce() async {
        let calls = Calls()
        let listener = StopPhraseListener(transcribe: { _ in "Se acabó." },
                                          heard: { start in calls.starts.withLock { $0.append(start) } })
        listener.append(twoLone)
        await wait(0.5)
        let starts = calls.starts.withLock { $0 }
        #expect(starts.count == 1)
        #expect(abs((starts.first ?? 0) - (4 * WAV.rate - WAV.rate / 10)) <= SpeechChunker.frame)
    }

    @Test("Other words, or a failed check, keep listening")
    func keepsListening() async {
        let calls = Calls()
        let listener = StopPhraseListener(transcribe: { _ in
            let n = calls.checks.withLock { $0 += 1; return $0 }
            if n == 1 { throw TranscriptionError.local("busy") }
            return "The End."
        }, heard: { start in calls.starts.withLock { $0.append(start) } })
        listener.append(twoLone)
        await wait(0.5)
        let starts = calls.starts.withLock { $0 }
        #expect(starts.count == 1)
        // The second utterance, near 5.6 s.
        #expect((starts.first ?? 0) > 5 * WAV.rate)
    }

    @Test("Cancel drops a check in flight: no call back")
    func cancel() async {
        let calls = Calls()
        let listener = StopPhraseListener(transcribe: { _ in
            try? await Task.sleep(for: .milliseconds(300))
            return "Se acabó"
        }, heard: { start in calls.starts.withLock { $0.append(start) } })
        listener.append(twoLone)
        await wait(0.1)
        listener.cancel()
        await wait(0.5)
        #expect(calls.starts.withLock { $0 }.isEmpty)
    }

    @Test("cancelAndWait returns after the check in flight ends")
    func cancelAndWait() async {
        let calls = Calls()
        let listener = StopPhraseListener(transcribe: { _ in
            try? await Task.sleep(for: .milliseconds(200))
            calls.finished.withLock { $0 = true }
            return "Hola"
        }, heard: { _ in })
        listener.append(twoLone)
        await wait(0.05)
        await listener.cancelAndWait()
        #expect(calls.finished.withLock { $0 })
    }

    @Test("Tee hands the same samples to both, in order")
    func tee() {
        // A class around the Mutex: a noncopyable value can't be captured by an escaping closure.
        let seen = Seen()
        let both = Tee.both({ _ in seen.names.withLock { $0.append("buffer") } },
                            { _ in seen.names.withLock { $0.append("listener") } })
        both([0.1])
        #expect(seen.names.withLock { $0 } == ["buffer", "listener"])
    }
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `(cd VoiceToText && tools/test.sh . --filter StopPhraseListenerTests)`
Expected: build error `cannot find 'StopPhraseListener' in scope`.

- [ ] **Step 3: Implement**

Append to `StopPhrase.swift`:

```swift
/// Listens to a dictation for the stop phrase while it is recorded. Each lone
/// utterance goes to `transcribe`, one at a time; the first that is a stop
/// phrase calls `heard` once, with the sample where it starts.
public final class StopPhraseListener: Sendable {
    public typealias Transcribe = @Sendable (_ samples: [Float]) async throws -> String

    private let input: AsyncStream<[Float]>.Continuation
    private let worker: Task<Void, Never>

    public init(finder: LoneUtterances = LoneUtterances(), transcribe: @escaping Transcribe,
                heard: @escaping @Sendable (_ start: Int) async -> Void) {
        let (stream, input) = AsyncStream.makeStream(of: [Float].self, bufferingPolicy: .unbounded)
        self.input = input
        worker = Task {
            var finder = finder
            for await samples in stream {
                for utterance in finder.append(samples) {
                    guard !Task.isCancelled else { return }
                    // A failed check is not a stop: keep listening.
                    let text = try? await transcribe(utterance.samples)
                    guard !Task.isCancelled else { return }
                    if let text, StopPhrase.matches(text) {
                        // Not awaited: `heard` stops the dictation, which waits for this task to end.
                        Task { await heard(utterance.start) }
                        return
                    }
                }
            }
        }
    }

    /// Samples from the microphone, 16 kHz mono. Safe from the audio thread.
    public func append(_ samples: [Float]) {
        input.yield(samples)
    }

    /// Stops listening; a check in flight is ignored.
    public func cancel() {
        input.finish()
        worker.cancel()
    }

    /// Stops listening and returns once a check in flight has ended, so the
    /// model is free for the whole dictation.
    public func cancelAndWait() async {
        cancel()
        await worker.value
    }
}

/// One microphone, two listeners. Built here, not in the app's main-actor
/// code, because the recorder calls it from its own queue.
public enum Tee {
    public static func both(_ first: @escaping @Sendable ([Float]) -> Void,
                            _ second: (@Sendable ([Float]) -> Void)?) -> @Sendable ([Float]) -> Void {
        guard let second else { return first }
        return { samples in
            first(samples)
            second(samples)
        }
    }
}
```

- [ ] **Step 4: Run the tests to see them pass**

Run: `(cd VoiceToText && tools/test.sh . --filter "StopPhrase|LoneUtterances")`
Expected: all pass.

- [ ] **Step 5: Run the whole unit suite**

Run: `(cd VoiceToText && tools/test.sh .)`
Expected: all pass, with the new tests counted on top of the existing ones.

- [ ] **Step 6: Commit**

```bash
git add VoiceToText/Sources/VoiceToTextKit/StopPhrase.swift VoiceToText/Tests/VoiceToTextKitTests/StopPhraseTests.swift
git commit -m "VoiceToText: StopPhraseListener checks lone utterances with the model while the person talks"
```

---

### Task 4: The `stopPhrase` setting, in Settings and the CLI

**Files:**
- Modify: `VoiceToText/Sources/VoiceToTextKit/DictationSettings.swift`
- Modify: `VoiceToText/Sources/VoiceToText/SettingsView.swift` (after the Sounds toggle, around line 141)
- Modify: `VoiceToText/Sources/VoiceToText/Agent/AgentCommands.swift` (`settings update` params and body, `agentStatus`)
- Test: `VoiceToText/Tests/VoiceToTextKitTests/VoiceToTextKitTests.swift`

**Interfaces:**
- Produces: `DictationSettings.stopPhrase: Bool` (default `true`); `vtt settings update --stop-phrase true|false`; `"stopPhrase"` in `vtt status` and in the `settings update` reply.

- [ ] **Step 1: Write the failing test**

Append to `VoiceToTextKitTests.swift`:

```swift
@Suite("S-017 The stop phrase setting")
struct StopPhraseSetting {
    @Test("On by default, also for a settings.json from before it existed")
    func defaultOn() {
        #expect(DictationSettings().stopPhrase)
        #expect(DictationSettings.decode(Data(#"{"model":"parakeet-ultra-local"}"#.utf8)).stopPhrase)
    }

    @Test("Off is saved and read back")
    func savedOff() throws {
        var settings = DictationSettings()
        settings.stopPhrase = false
        #expect(DictationSettings.decode(try settings.encoded()).stopPhrase == false)
    }
}
```

- [ ] **Step 2: Run it to see it fail**

Run: `(cd VoiceToText && tools/test.sh . --filter StopPhraseSetting)`
Expected: build error `value of type 'DictationSettings' has no member 'stopPhrase'`.

- [ ] **Step 3: Implement the setting**

In `DictationSettings.swift`:

```swift
    /// "The End" or "Se acabó", said on its own, stops the recording (Parakeet only).
    public var stopPhrase = true
```

Make these edits in the same file:
- Add `stopPhrase: Bool = true` as the last parameter of the memberwise `init`, and add `self.stopPhrase = stopPhrase` to its body.
- Add this to `init(from:)`:

```swift
        stopPhrase = try container.decodeIfPresent(Bool.self, forKey: .stopPhrase) ?? stopPhrase
```

- [ ] **Step 4: Run it to see it pass**

Run: `(cd VoiceToText && tools/test.sh . --filter StopPhraseSetting)`
Expected: PASS.

- [ ] **Step 5: Settings toggle and CLI**

In `SettingsView.swift`, right after the Sounds toggle:

```swift
                Toggle(isOn: $dictation.settings.stopPhrase) {
                    Text("Stop by Voice")
                    Text("Say “The End” or “Se acabó” after a pause. Parakeet only.")
                }
```

In `AgentCommands.swift`, `settings update`:
- Add to `params`:

```swift
                              .init(name: "stop-phrase", kind: .boolean, help: "\"The End\" or \"Se acabó\" said on its own stops the recording (Parakeet)"),
```

- Add to the body, after the `hide-when-idle` line:

```swift
            if let stop = try args.bool("stop-phrase") { settings.stopPhrase = stop }
```

- Add `"stopPhrase": settings.stopPhrase` to the returned dictionary.
- In `agentStatus`, add `"stopPhrase": dictation.settings.stopPhrase,` after `"hideWhenIdle"`.
- Update the `settings update` summary to: "Change the model, the language, the sounds, stop by voice, or the menu bar icon. Only the options you give change."

- [ ] **Step 6: Build, check the layout, look at Settings**

```bash
(cd VoiceToText && ./build.sh && tools/grid-lint.sh && tools/snap.sh)
```
Expected:
- the build succeeds;
- grid-lint passes;
- in the Settings snapshots (light and dark), the new toggle sits under Sounds and its caption fits on one line without clipping.

Judge by eye. Fix and re-shoot until it looks right.

- [ ] **Step 7: Commit**

```bash
git add VoiceToText/Sources/VoiceToTextKit/DictationSettings.swift VoiceToText/Sources/VoiceToText/SettingsView.swift VoiceToText/Sources/VoiceToText/Agent/AgentCommands.swift VoiceToText/Tests/VoiceToTextKitTests/VoiceToTextKitTests.swift
git commit -m "VoiceToText: Stop by Voice setting, in Settings, vtt settings update and vtt status"
```

---

### Task 5: `Dictation` stops on the phrase

**Files:**
- Modify: `VoiceToText/Sources/VoiceToText/Dictation.swift` (`toggle`, `start`, `stop`, `dropStream`, `transcribeRecording`, new `VoiceStop`, `makeListener`, `stopByPhrase`)
- Modify: `VoiceToText/Sources/VoiceToText/Agent/AgentCommands.swift` (`start` gets `--stop-phrase`; `agentStatus` gets `stoppedByPhrase`)
- Modify: `VoiceToText/Sources/VoiceToText/Fakes.swift` (`FakeTranscriber.phraseReply`, `phraseDelay`)
- Test: `VoiceToText/Sources/VoiceToText/SelfTest.swift` (new S-017 block after the S-016 block)

**Interfaces:**
- Consumes: `StopPhraseListener`, `Tee`, `StopPhrase.strip` (Tasks 1–3); `DictationSettings.stopPhrase` (Task 4); `SampleTranscribing.transcribe(samples:language:)`, `SampleBuffer` and `Dictation.sampler` (from `parakeet-memory`).
- Produces:
  - `Dictation.start(voiceStop: Dictation.VoiceStop? = nil)`
  - `Dictation.stop(paste: Bool, cutAt: Int? = nil)`
  - `Dictation.lastStopByPhrase: Bool`
  - `vtt start --stop-phrase`
  - `"stoppedByPhrase"` in `vtt status`

- [ ] **Step 1: Fakes, a reply for the short phrase checks**

In `FakeTranscriber` (`Fakes.swift`), add the following, then replace `transcribe(samples:language:)`:

```swift
    /// Answers the stop-phrase checks when set: under 3 s of samples with a sound in them.
    /// The dictation cut before the phrase gets `sampleReply`, even when it is short and quiet.
    var phraseReply: String?
    var phraseDelay: Duration = .milliseconds(20)

    func transcribe(samples: [Float], language: String?) async throws -> String {
        sampleCalls.append((samples.count, language))
        if let phraseReply, samples.count < 3 * WAV.rate, samples.contains(where: { abs($0) > 0.1 }) {
            try? await Task.sleep(for: phraseDelay)
            return phraseReply
        }
        try? await Task.sleep(for: .milliseconds(20))
        return try sampleReply.get()
    }
```

- [ ] **Step 2: Write the failing self-test block**

In `SelfTest.swift`, after the S-016 block, reuse the `tone` helper from the S-014 block:

```swift
        // S-017 "The End" / "Se acabó" said on its own stops like a second press.
        let lone = tone(3, 0.3) + tone(1, 0.0005) + tone(0.7, 0.3) + tone(0.8, 0.0005)
        dictation.settings.model = Parakeet.model
        dictation.settings.stopPhrase = true
        transcriber.sampleReply = .success("Texto dictado.")
        transcriber.phraseReply = "Se acabó."
        await dictation.toggle()
        recorder.speak(lone)
        await wait(0.5)
        check("S-017 the phrase said on its own stops and pastes", dictation.state == .idle
                && paster.last?.text == "Texto dictado." && dictation.lastStopByPhrase)
        let kept = transcriber.sampleCalls.last?.count ?? 0
        check("S-017 the audio is cut before the phrase", kept > Int(3.5 * Double(WAV.rate)) && kept < 4 * WAV.rate, "\(kept) samples")

        transcriber.sampleReply = .success("Until the end.")
        await dictation.toggle()
        recorder.speak(lone)
        await wait(0.5)
        check("S-017 words before the phrase that end like it stay", paster.last?.text == "Until the end.")

        transcriber.phraseReply = "Vale."
        await dictation.toggle()
        recorder.speak(lone)
        await wait(0.5)
        check("S-017 other words said on their own keep recording", dictation.state.name == "recording")
        await dictation.cancel()
        transcriber.phraseReply = "Se acabó."

        dictation.settings.stopPhrase = false
        let checksOff = transcriber.sampleCalls.count
        await dictation.toggle()
        recorder.speak(lone)
        await wait(0.5)
        check("S-017 off in Settings: the phrase does nothing", dictation.state.name == "recording"
                && transcriber.sampleCalls.count == checksOff)
        await dictation.cancel()
        dictation.settings.stopPhrase = true

        // start(voiceStop:) as the shortcut calls it, without blocked() (which wants an OpenAI key here).
        dictation.settings.model = "gpt-4o-mini-transcribe"
        try? await dictation.start(voiceStop: .paste)
        recorder.speak(lone)
        await wait(0.5)
        check("S-017 with an OpenAI model the phrase does nothing", dictation.state.name == "recording")
        await dictation.cancel()
        dictation.settings.model = Parakeet.model

        try? await dictation.start()
        recorder.speak(lone)
        await wait(0.5)
        check("S-017 a plain vtt start does not listen", dictation.state.name == "recording")
        await dictation.cancel()

        transcriber.sampleReply = .success("Para el agente.")
        try? await dictation.start(voiceStop: .keep)
        recorder.speak(lone)
        await wait(0.5)
        check("S-017 vtt start --stop-phrase stops and saves without pasting", dictation.state == .idle
                && dictation.history.last?.text == "Para el agente." && paster.last?.text != "Para el agente.")

        transcriber.sampleReply = .success("")
        let historyEmpty = dictation.history.count
        await dictation.toggle()
        recorder.speak(tone(1, 0.0005) + tone(0.7, 0.3) + tone(0.8, 0.0005))
        await wait(0.5)
        check("S-017 only the phrase: nothing pasted", dictation.state == .idle && dictation.lastStopByPhrase
                && dictation.history.count == historyEmpty)

        transcriber.sampleReply = .success("Una vez.")
        transcriber.phraseDelay = .milliseconds(400)
        let historyOnce = dictation.history.count
        await dictation.toggle()
        recorder.speak(lone)
        await wait(0.1)
        await dictation.toggle()
        await wait(0.7)
        check("S-017 the shortcut during a phrase check stops once", dictation.state == .idle
                && dictation.history.count == historyOnce + 1 && !dictation.lastStopByPhrase)

        await dictation.toggle()
        recorder.speak(lone)
        await wait(0.1)
        await dictation.cancel()
        await dictation.toggle()
        await wait(0.7)
        check("S-017 a check from a canceled recording does not stop the next one", dictation.state.name == "recording")
        await dictation.cancel()
        transcriber.phraseDelay = .milliseconds(20)

        // The whole-file fallback (samples with a gap) still has the phrase: its text is stripped.
        let replyBefore = transcriber.reply
        recorder.duration = 60
        transcriber.reply = .success("Mañana. Se acabó.")
        await dictation.toggle()
        recorder.speak(lone)
        await wait(0.6)
        check("S-017 the whole-file fallback strips the phrase", paster.last?.text == "Mañana.")
        recorder.duration = 1.5
        transcriber.reply = replyBefore
        transcriber.phraseReply = nil
```

Run: `(cd VoiceToText && ./build.sh && tools/selftest.sh)`
Expected: build error `extra argument 'voiceStop' in call` (or `has no member 'lastStopByPhrase'`).

- [ ] **Step 3: Implement in `Dictation.swift`**

Add the following near `buffer`:

```swift
    /// Listens for "The End" / "Se acabó" while recording (Parakeet, Stop by Voice on).
    @ObservationIgnored private var listener: StopPhraseListener?
    /// Counts recordings, so a phrase heard in an earlier one cannot stop this one.
    @ObservationIgnored private var recordingID = 0
    /// The last dictation was stopped by the stop phrase.
    private(set) var lastStopByPhrase = false

    /// What hearing the stop phrase does: paste (the shortcut, menu, icon) or only save (an agent).
    enum VoiceStop { case paste, keep }
```

In `toggle()`, change the idle case to:

```swift
        case .idle: if !blocked() { try? await start(voiceStop: .paste) }
```

Change `start()` to `func start(voiceStop: VoiceStop? = nil) async throws`. After `self.buffer = buffer`, add:

```swift
        recordingID += 1
        let listener = voiceStop.flatMap { makeListener(recording: recordingID, paste: $0 == .paste) }
        self.listener = listener
```

Then change the `recorder.start` call's `onAudio` to:

```swift
            try await recorder.start(to: store.recordingURL, timeout: Self.micTimeout,
                                     onAudio: stream?.append ?? buffer.map { Tee.both($0.append, listener?.append) })
```

Make these edits in `stop`:
- Change the signature to `func stop(paste: Bool, cutAt phrase: Int? = nil) async throws -> String`.
- Right after `let recorded = await recorder.stop()`, add:

```swift
        // A phrase check still running ends first: one Parakeet run at a time.
        let listener = self.listener
        self.listener = nil
        await listener?.cancelAndWait()
        lastStopByPhrase = phrase != nil
```

- Replace the `whole`/return lines at the end with:

```swift
        // All of it, or the file: a gap (a mic that failed to restart) must not lose words.
        let whole = samples.flatMap { Double($0.count) >= recorded * Double(WAV.rate) * 0.9 ? $0 : nil }
        // In memory the phrase is cut off the audio; the whole file still has it, so its text is stripped.
        let kept = phrase.flatMap { cut in whole.map { Array($0.prefix(cut)) } } ?? whole
        return try await transcribeRecording(paste: paste, stream: stream, samples: kept,
                                             stripPhrase: phrase != nil && kept == nil, since: keyUp)
```

In `dropStream()`, add:

```swift
        listener?.cancel()
        listener = nil
```

In `transcribeRecording`:
- add the parameter `stripPhrase: Bool = false` before `since`;
- change `let text: String` to `var text: String`;
- right after the `do { … } catch { … }`, add:

```swift
        if stripPhrase { text = StopPhrase.strip(text) }
```

Add two new private methods:

```swift
    /// A listener for the stop phrase, when it can run: Stop by Voice on, Parakeet chosen.
    private func makeListener(recording id: Int, paste: Bool) -> StopPhraseListener? {
        guard settings.stopPhrase, settings.model == Parakeet.model, let sampler else { return nil }
        return StopPhraseListener(transcribe: { samples in
            // No language: the phrase is English or Spanish whatever is chosen.
            try await sampler.transcribe(samples: samples, language: nil)
        }, heard: { [weak self] start in
            await self?.stopByPhrase(at: start, recording: id, paste: paste)
        })
    }

    /// The phrase was heard: stop like a second press, without it.
    private func stopByPhrase(at start: Int, recording id: Int, paste: Bool) async {
        guard id == recordingID, case .recording = state else { return }
        _ = try? await stop(paste: paste, cutAt: start)
    }
```

- [ ] **Step 4: CLI `start --stop-phrase`, and the status field**

In `AgentCommands.swift`, replace the `start` command with:

```swift
        AgentCommand(name: "start", summary: "Start recording the microphone. Returns once the mic is live: talk after that.",
                     params: [.init(name: "stop-phrase", kind: .boolean,
                                    help: "stop by itself when you say \"The End\" or \"Se acabó\" (Parakeet); the text goes to history, not pasted")],
                     example: "vtt start") { args, services in
            try await services.dictation.start(voiceStop: try args.bool("stop-phrase") == true ? .keep : nil)
            return ["state": services.dictation.state.name]
        },
```

In `agentStatus`, add `"stoppedByPhrase": dictation.lastStopByPhrase,` after `"canRetry"`.

- [ ] **Step 5: Build and run the self-test**

Run: `(cd VoiceToText && ./build.sh && tools/selftest.sh)`
Expected:
- every check passes, the earlier ones too;
- the count is the old count + 12;
- no `Incorrect actor executor` crash. If you see one, a closure handed to the recorder was written in `Dictation.swift`. Build it in `VoiceToTextKit` (`Tee`) instead.

- [ ] **Step 6: Unit tests still pass**

Run: `(cd VoiceToText && tools/test.sh .)`
Expected: all pass.

- [ ] **Step 7: Commit**

```bash
git add VoiceToText/Sources/VoiceToText/Dictation.swift VoiceToText/Sources/VoiceToText/Agent/AgentCommands.swift VoiceToText/Sources/VoiceToText/Fakes.swift VoiceToText/Sources/VoiceToText/SelfTest.swift
git commit -m "VoiceToText: saying \"The End\" or \"Se acabó\" stops the recording like a second press"
```

---

### Task 6: Real-audio e2e, docs, manual check, PR

**Files:**
- Create: `VoiceToText/tools/stop-phrase.sh`
- Modify: `README.md` ("Use" table and the `vtt` block), `VoiceToText/README.md` (checks table), `VoiceToText/docs/STORIES.md` (S-017 `Status: done`)

- [ ] **Step 1: Write the e2e script**

```zsh
#!/bin/zsh
# Stop by Voice against real Parakeet, in a test copy of the installed app
# (APP_STORE in /tmp: never your history or settings, never the shortcut).
# Its "microphone" plays `say` clips in real time (APP_FAKE_MIC):
#   es, en         words, a pause, the phrase, a pause, more words: the
#                  recording must stop by itself, without the phrase or the words after it
#   es-in, en-in   the phrase inside a sentence: the recording must go on
# Free: everything runs on this Mac. Parakeet downloads 610 MB the first time.
# Usage: tools/stop-phrase.sh
#        tools/stop-phrase.sh --help
set -uo pipefail
zmodload zsh/datetime   # $EPOCHREALTIME
if [[ ${1:-} == -h || ${1:-} == --help ]]; then sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 0; fi
cli=~/Applications/VoiceToText.app/Contents/MacOS/VoiceToText
export APP_STORE=/tmp/VoiceToText-stop-phrase.store
export APP_AGENT_SOCKET=$APP_STORE.sock
work=$(mktemp -d)
failures=0
json() { python3 -I -c "import json,sys; d=json.loads(sys.argv[1]); print(eval(sys.argv[2], {'d': d}))" "$1" "$2" 2>/dev/null; }
quit_copy() { local pid=$(lsof -t "$APP_AGENT_SOCKET" 2>/dev/null | head -1); [[ -n "$pid" ]] && kill "$pid" 2>/dev/null; sleep 0.5; }
pass() { echo "PASS $1"; }
fail() { echo "FAIL $1"; failures=$((failures + 1)); }
has() { [[ "${(L)1}" == *"${(L)2}"* ]]; }
trap 'quit_copy; rm -rf "$work"' EXIT

typeset -A text=(
  es "Mañana compramos pan y leche en el mercado. [[slnc 1000]] Se acabó. [[slnc 1500]] Esto no se tiene que pegar."
  en "Please call Maria before Friday. [[slnc 1000]] The end. [[slnc 1500]] This should not be pasted."
  es-in "Se acabó la reunión y nos fuimos a casa a descansar un rato. [[slnc 1500]]"
  en-in "The end of the month is when we send the invoices to the clients. [[slnc 1500]]"
)
typeset -A voice=(es Mónica en Samantha es-in Mónica en-in Samantha)

for clip in es en es-in en-in; do
  say -v $voice[$clip] -o "$work/$clip.aiff" "$text[$clip]"
  afconvert -f m4af -d aac "$work/$clip.aiff" "$work/$clip.m4a"
  seconds=$(afinfo "$work/$clip.m4a" | awk '/estimated duration/ {print $3}')
  quit_copy; rm -rf "$APP_STORE"; mkdir -p "$APP_STORE"
  export APP_FAKE_MIC="$work/$clip.m4a"
  "$cli" settings update --model parakeet-ultra-local --language es --stop-phrase true --json >/dev/null
  for i in {1..600}; do [[ $(json "$("$cli" status --json)" "d['parakeetLoaded']") == True ]] && break; sleep 0.5; done
  "$cli" start --stop-phrase --json >/dev/null
  t0=$EPOCHREALTIME
  for i in {1..100}; do [[ $(json "$("$cli" status --json)" "d['state']") == idle ]] && break; sleep 0.1; done
  took=$(( EPOCHREALTIME - t0 ))
  state=$(json "$("$cli" status --json)" "d['state']")
  if [[ $clip == *-in ]]; then
    [[ $state == recording ]] && pass "$clip: the phrase inside a sentence keeps recording" || fail "$clip: stopped ($state)"
    "$cli" stop --json >/dev/null
  else
    last=$(json "$("$cli" history list --limit 1 --json)" "d['entries'][0]['text']")
    if [[ $state == idle ]] && (( took < seconds )) && ! has "$last" "acab" && ! has "$last" "the end" \
       && ! has "$last" "pegar" && ! has "$last" "pasted" && { has "$last" "pan" || has "$last" "maria"; }; then
      pass "$clip: stopped by itself after ${took%.*} s of ${seconds%.*} s: \"$last\""
    else
      fail "$clip: state=$state after ${took%.*} s of ${seconds%.*} s, text \"$last\""
    fi
  fi
  unset APP_FAKE_MIC
done
echo "$failures failed"
exit $failures
```

- [ ] **Step 2: Run it**

```bash
chmod +x VoiceToText/tools/stop-phrase.sh
(cd VoiceToText && ./build.sh && tools/stop-phrase.sh)
```
Expected: 4 PASS, `0 failed`.

If `es` or `en` fails with the phrase still in the text, run the clip through `vtt transcribe` and see how Parakeet writes the phrase alone. Add that spelling to `StopPhrase.phrases` (folded, without spaces) and add it to the `matches` test arguments. Never loosen the pause rule to make a clip pass.

- [ ] **Step 3: Docs**

In `README.md`:
- Add to the "Use" table:

```markdown
| Stop by voice | Pause, say "The End" or "Se acabó", pause. Same as pressing ⌃. again, without the phrase (Parakeet; Settings › Stop by Voice) |
```

- Add to the `vtt` block:

```sh
vtt start --stop-phrase                   # stops by itself on "The End" / "Se acabó"; text goes to history (not pasted)
```

In `VoiceToText/README.md`, update the unit and self-test counts in the Checks table from the real runs, and add this row:

```markdown
| Stop by voice | `tools/stop-phrase.sh` | Spanish and English stop on the phrase; inside a sentence they don't |
```

In `STORIES.md`, change S-017 to `Status: done`.

- [ ] **Step 4: Manual check with the real mic**

Run `./build.sh --open`. Every rebuild resets the Mic and Accessibility grants: re-grant them, then check with `vtt status --json`. Then:
1. TextEdit in front: ⌃., dictate a sentence in Spanish, pause, "Se acabó", pause. Expected: Pop, then the text pasted without the phrase, about 1 s after the phrase.
2. ⌃., "the end of the story is near", keep talking. Expected: keeps recording. Press ⌃. to finish.
3. ⌃. with music playing in the room, talk 20 s without the phrase. Expected: no stop.

Write the results into the issue.

- [ ] **Step 5: Commit, PR**

```bash
git add VoiceToText/tools/stop-phrase.sh README.md VoiceToText/README.md VoiceToText/docs/STORIES.md
git commit -m "VoiceToText: stop-by-voice e2e with real Parakeet, docs, S-017 done"
git push -u origin stop-phrase
gh pr create --repo jm-avila/voice-to-text-macos --title "Stop a recording by voice: \"The End\" / \"Se acabó\"" \
  --body "Closes #<issue>. Unit, self-test and e2e results in the issue."
```

Update the issue body's How section with the real results, including failures.
