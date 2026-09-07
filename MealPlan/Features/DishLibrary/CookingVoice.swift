import AVFoundation
import Foundation
import Observation
import Speech

/// Hands-free plumbing for Cooking Mode: one object speaks the current step
/// aloud, the other listens for a small set of spoken commands. Both are
/// deliberately no-ops until Cooking Mode explicitly starts them, and both stop
/// the moment that screen goes away — nothing here ever runs in the background.

// MARK: - Audio session

/// Cooking Mode is the only place the app plays synthesized speech or opens the
/// microphone, and the two have to share one session: while the recogniser
/// holds the mic the category must stay `.playAndRecord` or narration would cut
/// it off. Everything is a best-effort `try?` — a failed session change should
/// never crash a recipe.
enum CookingAudioSession {
    static func configureForPlayback() {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers, .mixWithOthers])
        try? session.setActive(true)
        #endif
    }

    static func configureForPlayAndRecord() {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(
            .playAndRecord,
            mode: .spokenAudio,
            options: [.duckOthers, .mixWithOthers, .defaultToSpeaker, .allowBluetoothHFP]
        )
        try? session.setActive(true)
        #endif
    }

    static func deactivate() {
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }
}

// MARK: - Narrator

/// Reads a cooking step aloud. Kept dumb on purpose: Cooking Mode decides
/// *when* to speak (a step became current, the cook asked for a repeat), this
/// only decides *how*.
@MainActor
@Observable
final class CookingNarrator: NSObject, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()

    /// True while an utterance is in flight — drives the speaker icon in the UI.
    private(set) var isSpeaking = false

    /// BCP-47 code for the recipe's language (e.g. `de-DE`), so a German recipe
    /// isn't read in an English accent. Nil falls back to the system voice.
    var languageCode: String?

    /// Set by Cooking Mode while the recogniser owns the audio session, so the
    /// narrator doesn't fight it for the category.
    var audioSessionManagedExternally = false

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        synthesizer.stopSpeaking(at: .immediate)
        if !audioSessionManagedExternally { CookingAudioSession.configureForPlayback() }

        let utterance = AVSpeechUtterance(string: trimmed)
        if let languageCode, let voice = AVSpeechSynthesisVoice(language: languageCode) {
            utterance.voice = voice
        }
        // Honour the rate and voice a VoiceOver user has already tuned, when
        // they've turned that setting on.
        utterance.prefersAssistiveTechnologySettings = true
        isSpeaking = true
        synthesizer.speak(utterance)
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        isSpeaking = false
        if !audioSessionManagedExternally { CookingAudioSession.deactivate() }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.isSpeaking = false
            if !self.audioSessionManagedExternally { CookingAudioSession.deactivate() }
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.isSpeaking = false }
    }
}

// MARK: - Voice command recogniser

/// Listens for a handful of cooking commands and reports them one at a time.
///
/// On-device only — `requiresOnDeviceRecognition` is forced and the feature
/// reports itself unavailable if the OS can't honour that, so kitchen chatter
/// is never streamed to a server. The recogniser is cycled in short segments:
/// each recognised command ends the current segment so the same word can't fire
/// twice, and a long silence rolls it over before the system times out.
@MainActor
@Observable
final class CookingVoiceController {
    enum Command: Equatable, CaseIterable {
        case next, back, repeatStep, markStepDone, startTimer, stop
    }

    private(set) var isListening = false
    /// False when there is no recogniser for the locale, or the OS won't do it
    /// on device. The UI hides the toggle in that case.
    let isAvailable: Bool
    /// Most recent transcript tail, shown under the listening indicator so the
    /// cook can see it heard something even before a command lands.
    private(set) var lastHeard = ""

    /// Fired on the main actor for each recognised command.
    var onCommand: ((Command) -> Void)?

    private let recognizer: SFSpeechRecognizer?
    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var restartTask: Task<Void, Never>?
    /// How much of the current segment's transcript has already been acted on,
    /// so only the newly-heard tail is scanned for the next command.
    private var consumedPrefixLength = 0

    init() {
        let recognizer = SFSpeechRecognizer(locale: Locale.current) ?? SFSpeechRecognizer()
        self.recognizer = recognizer
        self.isAvailable = (recognizer?.supportsOnDeviceRecognition ?? false)
    }

    // MARK: Authorization

    /// Asks for speech + microphone permission. Cooking Mode calls this before
    /// the first `start()` and reverts its toggle if it returns false.
    func requestAuthorization() async -> Bool {
        let speechAuthorized = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
        guard speechAuthorized else { return false }
        return await requestMicrophone()
    }

    private func requestMicrophone() async -> Bool {
        #if os(iOS)
        return await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { continuation.resume(returning: $0) }
        }
        #else
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { continuation.resume(returning: $0) }
            }
        default:
            return false
        }
        #endif
    }

    // MARK: Listening

    func start() {
        guard isAvailable, !isListening, let recognizer, recognizer.isAvailable else { return }
        CookingAudioSession.configureForPlayAndRecord()
        do {
            try beginSegment(with: recognizer)
            isListening = true
        } catch {
            teardownEngine()
            isListening = false
            CookingAudioSession.deactivate()
        }
    }

    func stop() {
        restartTask?.cancel()
        restartTask = nil
        teardownEngine()
        isListening = false
        lastHeard = ""
        CookingAudioSession.deactivate()
    }

    private func teardownEngine() {
        task?.cancel()
        task = nil
        request?.endAudio()
        request = nil
        if audioEngine.isRunning { audioEngine.stop() }
        audioEngine.inputNode.removeTap(onBus: 0)
    }

    private func beginSegment(with recognizer: SFSpeechRecognizer) throws {
        task?.cancel()
        task = nil
        consumedPrefixLength = 0

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        request.addsPunctuation = false
        request.taskHint = .confirmation
        self.request = request

        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        // The tap runs on a realtime audio thread; it only forwards buffers to
        // the request (safe to call from any thread) and touches nothing else.
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }
        audioEngine.prepare()
        try audioEngine.start()

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            // The handler arrives off the main actor; pull out only Sendable
            // values and finish the work back on the main actor.
            let transcript = result?.bestTranscription.formattedString
            let finished = error != nil || (result?.isFinal ?? false)
            Task { @MainActor in
                guard let self else { return }
                if let transcript { self.consume(transcript) }
                if finished { self.scheduleRestart() }
            }
        }
    }

    /// Acts on the first command word in the not-yet-consumed tail of the
    /// transcript, then cycles the segment so it can't match again.
    private func consume(_ transcript: String) {
        let normalized = transcript.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: nil
        )
        lastHeard = transcript
        guard normalized.count > consumedPrefixLength else { return }
        let tail = String(normalized.dropFirst(consumedPrefixLength))
        guard let command = Self.match(in: tail) else { return }
        consumedPrefixLength = normalized.count
        onCommand?(command)
        scheduleRestart(after: .milliseconds(150))
    }

    private func scheduleRestart(after delay: Duration = .milliseconds(500)) {
        restartTask?.cancel()
        restartTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, self.isListening, !Task.isCancelled,
                  let recognizer = self.recognizer else { return }
            self.task?.cancel()
            self.task = nil
            self.request?.endAudio()
            self.request = nil
            try? self.beginSegment(with: recognizer)
        }
    }

    // MARK: Matching

    /// Substring match against a folded (lower-cased, accent-stripped)
    /// transcript, so keyword entries here are written without diacritics.
    /// English and German both, to match the app's catalog; order runs from the
    /// most specific phrase to the most generic so "next step" wins over "next".
    static func match(in haystack: String) -> Command? {
        for (command, phrases) in keywordTable {
            if phrases.contains(where: haystack.contains) { return command }
        }
        return nil
    }

    static let keywordTable: [(Command, [String])] = [
        (.markStepDone, ["mark done", "step done", "check step", "check it off", "erledigt", "abgehakt", "schritt fertig"]),
        (.startTimer, ["start timer", "start the timer", "set timer", "set a timer", "timer starten", "starte timer", "wecker stellen"]),
        (.repeatStep, ["repeat", "say again", "say that again", "read again", "read it again", "again please", "wiederhole", "wiederholen", "noch mal", "nochmal"]),
        (.stop, ["stop listening", "stop the voice", "stop voice control", "hor auf zu horen", "hoer auf zu hoeren", "sprachsteuerung aus"]),
        (.back, ["go back", "previous step", "last step", "step back", "back a step", "zuruck", "zurueck", "vorheriger schritt", "einen zuruck"]),
        (.next, ["next step", "next", "go on", "continue", "carry on", "move on", "weiter", "nachster schritt", "naechster schritt", "weiter geht"]),
        (.markStepDone, ["done"]),
    ]
}
