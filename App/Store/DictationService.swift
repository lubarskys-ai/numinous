import Foundation
import Speech
import AVFoundation

/// On-device dictation: streams the microphone through Apple's speech recogniser and
/// publishes a live transcript, so you can talk your diary straight into a note instead
/// of dictating elsewhere and pasting. Recognition runs on the device when the model
/// supports it (`requiresOnDeviceRecognition`), so your words never leave the phone.
@MainActor
final class DictationService: NSObject, ObservableObject {
    /// The text recognised so far in the CURRENT dictation session (resets on start).
    @Published var transcript = ""
    @Published var isRecording = false
    /// A human-readable problem to surface (permission denied, recogniser unavailable),
    /// or nil when all is well.
    @Published var problem: String?

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

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
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        // Keep it on-device when the model allows — nothing leaves the phone.
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        self.request = request

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
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.request?.append(buffer)
        }
        audioEngine.prepare()
        do { try audioEngine.start() } catch {
            problem = "Couldn't start the microphone."
            teardown()
            return
        }
        isRecording = true

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            Task { @MainActor in
                if let result { self.transcript = result.bestTranscription.formattedString }
                if error != nil || (result?.isFinal ?? false) { self.finish() }
            }
        }
    }

    /// Stop dictation, keeping whatever was recognised in `transcript`.
    func stop() { finish() }

    private func finish() {
        guard isRecording else { return }
        audioEngine.stop()
        request?.endAudio()
        task?.cancel()
        teardown()
        isRecording = false
    }

    private func teardown() {
        if audioEngine.inputNode.numberOfInputs > 0 { audioEngine.inputNode.removeTap(onBus: 0) }
        request = nil
        task = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
