import Foundation
import Speech
import AVFoundation

/// On-device dictation: streams the microphone through Apple's speech recogniser and
/// publishes a live transcript, so you can talk your diary straight into a note instead
/// of dictating elsewhere and pasting. Recognition runs on the device when the model
/// supports it (`requiresOnDeviceRecognition`), so your words never leave the phone.
///
/// Long dictation is handled by accumulating each *finalised* segment into `committed`
/// and starting a fresh recognition request for what comes next — so the transcript keeps
/// growing instead of erasing itself when the recogniser wraps up a phrase or times out.
@MainActor
final class DictationService: NSObject, ObservableObject {
    /// Everything recognised so far in the current dictation session.
    @Published var transcript = ""
    @Published var isRecording = false
    /// A human-readable problem to surface (permission denied, recogniser unavailable),
    /// or nil when all is well.
    @Published var problem: String?

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var tapInstalled = false
    /// Text from segments the recogniser has already finalised; live partials are appended
    /// to this for display, and it's what survives a mid-session restart.
    private var committed = ""
    private var lastRestart = Date.distantPast

    /// Whether dictation can run at all on this device/locale — used to hide the mic
    /// button when there's no recogniser (rather than offering a dead control).
    var isAvailable: Bool { recognizer?.isAvailable ?? false }

    /// Ask for speech + microphone permission (once), returning whether both were granted.
    func requestPermission() async -> Bool {
        let speech = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status == .authorized)
            }
        }
        guard speech else { return false }
        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            AVAudioApplication.requestRecordPermission { granted in cont.resume(returning: granted) }
        }
    }

    /// Begin a fresh dictation session. Live results stream into `transcript`.
    func start() async {
        guard !isRecording else { return }
        problem = nil
        guard await requestPermission() else {
            problem = "Microphone or speech access is off. Turn it on in Settings › Numinous."
            return
        }
        guard let recognizer, recognizer.isAvailable else {
            problem = "Speech recognition isn't available right now."
            return
        }

        transcript = ""
        committed = ""

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            problem = "Couldn't start the microphone."
            return
        }

        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        // A zero sample-rate format means the input node isn't ready — bail rather than crash.
        guard format.sampleRate > 0 else {
            problem = "The microphone isn't ready. Try again."
            try? AVAudioSession.sharedInstance().setActive(false)
            return
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.request?.append(buffer)
        }
        tapInstalled = true
        audioEngine.prepare()
        do { try audioEngine.start() } catch {
            problem = "Couldn't start the microphone."
            teardown()
            return
        }
        isRecording = true
        beginRequest()
    }

    /// Stop dictation, keeping whatever was recognised in `transcript`.
    func stop() {
        guard isRecording else { return }
        isRecording = false
        teardown()
    }

    /// Spin up a new recognition request/task over the still-running audio engine. Called at
    /// the start and again after each finalised segment, so dictation can run indefinitely.
    private func beginRequest() {
        guard let recognizer else { return }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        self.request = request
        lastRestart = Date()

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                // Ignore callbacks from a request we've already superseded (a restart cancels
                // the previous task, whose late cancellation error must not stop us).
                guard let self, self.isRecording, self.request === request else { return }
                if let result {
                    let segment = result.bestTranscription.formattedString
                    self.transcript = self.committed.isEmpty ? segment
                        : (segment.isEmpty ? self.committed : self.committed + " " + segment)
                    if result.isFinal {
                        // Bank this segment and keep listening for the next one.
                        self.committed = self.transcript
                        self.restart()
                    }
                }
                if error != nil {
                    // Bank whatever we have; retry once if it wasn't an immediate/tight loop,
                    // otherwise stop cleanly (so a "no speech" error can't spin forever).
                    self.committed = self.transcript
                    if Date().timeIntervalSince(self.lastRestart) > 1.2 {
                        self.restart()
                    } else {
                        self.stop()
                    }
                }
            }
        }
    }

    /// Tear down the current request/task (keeping the audio engine running) and start a
    /// fresh one, preserving `committed`.
    private func restart() {
        guard isRecording else { return }
        task?.cancel(); task = nil
        request?.endAudio(); request = nil
        beginRequest()
    }

    private func teardown() {
        audioEngine.stop()
        request?.endAudio()
        task?.cancel()
        if tapInstalled { audioEngine.inputNode.removeTap(onBus: 0); tapInstalled = false }
        request = nil
        task = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
