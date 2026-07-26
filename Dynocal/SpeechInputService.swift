//
//  SpeechInputService.swift
//  Dynocal
//

import AVFAudio
import Combine
import Speech

@MainActor
final class SpeechInputService: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var message: String?

    private let audioEngine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?

    func toggle(onTranscription: @escaping @MainActor (String) -> Void) {
        if isRecording {
            stop()
        } else {
            Task {
                await start(onTranscription: onTranscription)
            }
        }
    }

    func stop() {
        guard isRecording || recognitionTask != nil else { return }

        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        isRecording = false

        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: .notifyOthersOnDeactivation
        )
    }

    private func start(onTranscription: @escaping @MainActor (String) -> Void) async {
        message = nil

        guard await requestSpeechPermission() else {
            message = "Allow Speech Recognition in Settings to use voice input."
            return
        }

        guard await requestMicrophonePermission() else {
            message = "Allow Microphone access in Settings to use voice input."
            return
        }

        guard let recognizer = SFSpeechRecognizer(locale: Locale.current),
              recognizer.isAvailable else {
            message = "Voice input isn’t available right now."
            return
        }

        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)

            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
            recognitionRequest = request

            let inputNode = audioEngine.inputNode
            let format = inputNode.outputFormat(forBus: 0)
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
                request.append(buffer)
            }

            audioEngine.prepare()
            try audioEngine.start()
            isRecording = true

            recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
                let transcription = result?.bestTranscription.formattedString
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let isFinal = result?.isFinal == true

                Task { @MainActor in
                    if let transcription, !transcription.isEmpty {
                        onTranscription(transcription)
                    }

                    if error != nil || isFinal {
                        self?.stop()
                    }
                }
            }
        } catch {
            stop()
            message = "Couldn’t start voice input: \(error.localizedDescription)"
        }
    }

    private func requestSpeechPermission() async -> Bool {
        if SFSpeechRecognizer.authorizationStatus() == .authorized {
            return true
        }

        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    private func requestMicrophonePermission() async -> Bool {
        if AVAudioApplication.shared.recordPermission == .granted {
            return true
        }

        return await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }
}
