import AVFoundation
import Foundation
import WhisperKit

final class SpeechEngine {
    var onPartialResult: ((String) -> Void)?
    var onFinalResult: ((String) -> Void)?
    var onError: ((String) -> Void)?
    var onAudioLevel: ((Float) -> Void)?
    var onLocaleUnavailable: ((String) -> Void)?
    var onModelLoading: ((String) -> Void)?
    var onModelReady: (() -> Void)?

    private let audioEngine = AVAudioEngine()
    private var pcmBuffer: [Float] = []
    private let bufferLock = NSLock()
    private let sampleRate: Double = 16_000

    // Serial queue for tap-callback work. By funnelling every callback
    // through this queue, stopRecording() can use a sync barrier to
    // guarantee all in-flight resample/append work has completed before
    // it snapshots pcmBuffer — no more dropped trailing samples.
    private let captureQueue = DispatchQueue(label: "me.changhai.VoiceInput.capture")

    private var whisperKit: WhisperKit?
    private var isLoadingModel = false
    private var modelName: String

    // nil means auto-detect (ideal for mixed zh/en).
    var languageCode: String? {
        didSet { UserDefaults.standard.set(languageCode, forKey: "whisperLanguage") }
    }

    init(modelName: String = "large-v3_turbo") {
        self.modelName = UserDefaults.standard.string(forKey: "whisperModel") ?? modelName
        self.languageCode = UserDefaults.standard.string(forKey: "whisperLanguage")
        loadModel()
    }

    // MARK: - Permissions

    static func requestPermissions(completion: @escaping (Bool, String?) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async {
                if granted {
                    completion(true, nil)
                } else {
                    completion(false, "Microphone access denied.\nGrant in System Settings → Privacy & Security → Microphone.")
                }
            }
        }
    }

    // MARK: - Model

    func changeModel(_ name: String) {
        modelName = name
        UserDefaults.standard.set(name, forKey: "whisperModel")
        whisperKit = nil
        loadModel()
    }

    private func loadModel() {
        guard !isLoadingModel else { return }
        isLoadingModel = true
        let name = modelName

        Task { [weak self] in
            guard let self else { return }
            do {
                let base = try Self.modelStorageDirectory()

                await MainActor.run {
                    self.onModelLoading?("Preparing \(name)...")
                }

                let modelFolder = try await WhisperKit.download(
                    variant: name,
                    downloadBase: base,
                    from: "argmaxinc/whisperkit-coreml",
                    progressCallback: { [weak self] progress in
                        guard let self else { return }
                        let pct = Int(progress.fractionCompleted * 100)
                        DispatchQueue.main.async {
                            self.onModelLoading?("Downloading \(name): \(pct)%")
                        }
                    }
                )

                await MainActor.run {
                    self.onModelLoading?("Loading \(name)...")
                }

                let config = WhisperKitConfig(
                    model: name,
                    downloadBase: base,
                    modelFolder: modelFolder.path,
                    verbose: false,
                    logLevel: .error,
                    prewarm: true,
                    load: true
                )
                let kit = try await WhisperKit(config)

                // Warmup: run one full transcription through the pipeline with
                // silent audio. This forces Core ML lazy init, tokenizer load,
                // and first-run kernel compilation — without it the user's
                // first real recording takes 2-5s extra.
                await MainActor.run {
                    self.onModelLoading?("Warming up \(name)...")
                }
                let silence = [Float](repeating: 0, count: 16_000)   // 1 second @ 16kHz
                let warmupOpts = DecodingOptions(
                    verbose: false,
                    task: .transcribe,
                    language: "en",
                    temperature: 0.0,
                    temperatureFallbackCount: 0,
                    usePrefillPrompt: true,
                    detectLanguage: false,
                    skipSpecialTokens: true,
                    withoutTimestamps: true,
                    noSpeechThreshold: 0.6
                )
                _ = try? await kit.transcribe(audioArray: silence, decodeOptions: warmupOpts)

                await MainActor.run {
                    self.whisperKit = kit
                    self.isLoadingModel = false
                    self.onModelReady?()
                }
            } catch {
                NSLog("[VoiceInput] Model load failed: %@", error.localizedDescription)
                await MainActor.run {
                    self.isLoadingModel = false
                    self.onError?("Model load failed: \(error.localizedDescription)")
                }
            }
        }
    }

    /// Resolves (and creates) ~/Library/Application Support/VoiceInput.
    /// HubApi will append "models/argmaxinc/whisperkit-coreml/<model>" under this,
    /// so the full path becomes
    /// ~/Library/Application Support/VoiceInput/models/argmaxinc/whisperkit-coreml/<model>.
    private static func modelStorageDirectory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = base.appendingPathComponent("VoiceInput", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Recording

    func startRecording() {
        // Request microphone permission on first use. If already granted this
        // returns immediately on the next launch; if denied the system shows
        // its own prompt the very first time.
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    if granted {
                        self?.beginAudioCapture()
                    } else {
                        self?.onError?("Microphone permission denied. Grant in System Settings → Privacy & Security → Microphone.")
                    }
                }
            }
            return
        case .denied, .restricted:
            onError?("Microphone permission denied. Grant in System Settings → Privacy & Security → Microphone.")
            return
        case .authorized:
            beginAudioCapture()
        @unknown default:
            beginAudioCapture()
        }
    }

    private func beginAudioCapture() {
        bufferLock.lock()
        pcmBuffer.removeAll(keepingCapacity: true)
        bufferLock.unlock()

        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            onError?("Cannot create target audio format")
            return
        }

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }

            // Audio level can stay on the audio thread (cheap, no
            // shared state) and is published to main for UI use.
            if let channelData = buffer.floatChannelData?[0] {
                let frameLength = Int(buffer.frameLength)
                var sum: Float = 0
                for i in 0..<frameLength {
                    sum += channelData[i] * channelData[i]
                }
                let rms = sqrtf(sum / Float(max(frameLength, 1)))
                let dB = 20 * log10(max(rms, 1e-6))
                let normalized = max(Float(0), min(Float(1), (dB + 50) / 40))
                DispatchQueue.main.async {
                    self.onAudioLevel?(normalized)
                }
            }

            // Copy the audio frames out of the AVAudioPCMBuffer before
            // dispatching — the buffer object is reused by CoreAudio and
            // its data is no longer valid once this callback returns.
            let frameCount = Int(buffer.frameLength)
            guard frameCount > 0,
                  let src = buffer.floatChannelData?[0]
            else { return }
            var sourceCopy = [Float](repeating: 0, count: frameCount)
            sourceCopy.withUnsafeMutableBufferPointer { dst in
                dst.baseAddress!.update(from: src, count: frameCount)
            }
            let copiedFormat = inputFormat

            // Resample + append on the serial captureQueue so that
            // stopRecording() can sync-barrier on it.
            self.captureQueue.async {
                guard let copiedBuffer = AVAudioPCMBuffer(
                    pcmFormat: copiedFormat,
                    frameCapacity: AVAudioFrameCount(frameCount)
                ) else { return }
                copiedBuffer.frameLength = AVAudioFrameCount(frameCount)
                if let dst = copiedBuffer.floatChannelData?[0] {
                    sourceCopy.withUnsafeBufferPointer { srcPtr in
                        dst.update(from: srcPtr.baseAddress!, count: frameCount)
                    }
                }

                // Fresh converter per buffer to avoid lingering state.
                guard let converter = AVAudioConverter(from: copiedFormat, to: targetFormat) else { return }

                let ratio = targetFormat.sampleRate / copiedFormat.sampleRate
                let outCapacity = AVAudioFrameCount(Double(copiedBuffer.frameLength) * ratio + 16)
                guard let outBuf = AVAudioPCMBuffer(
                    pcmFormat: targetFormat,
                    frameCapacity: outCapacity
                ) else { return }

                var consumed = false
                var err: NSError?
                _ = converter.convert(to: outBuf, error: &err) { _, status in
                    if consumed {
                        status.pointee = .endOfStream
                        return nil
                    }
                    consumed = true
                    status.pointee = .haveData
                    return copiedBuffer
                }
                if err != nil { return }

                guard let outChannel = outBuf.floatChannelData?[0] else { return }
                let outLen = Int(outBuf.frameLength)
                let resampled = Array(UnsafeBufferPointer(start: outChannel, count: outLen))
                self.bufferLock.lock()
                self.pcmBuffer.append(contentsOf: resampled)
                self.bufferLock.unlock()
            }
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            onError?("Audio engine failed: \(error.localizedDescription)")
            cleanup()
        }
    }

    func stopRecording() {
        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }

        // Drain captureQueue: tap callbacks already enqueued before
        // stop()+removeTap() will finish their resample+append work
        // before this sync returns. Guarantees we see all in-flight
        // samples — no time-based guess required.
        captureQueue.sync { }

        bufferLock.lock()
        let samples = pcmBuffer
        pcmBuffer.removeAll(keepingCapacity: false)
        bufferLock.unlock()

        let durationSec = Double(samples.count) / sampleRate
        print("[VoiceInput] stopRecording: \(samples.count) samples (\(String(format: "%.2f", durationSec))s)")

        guard !samples.isEmpty else {
            onFinalResult?("")
            return
        }

        guard let kit = whisperKit else {
            onError?("Model not ready yet")
            return
        }

        let lang = languageCode
        Task { [weak self] in
            guard let self else { return }
            do {
                let options = DecodingOptions(
                    verbose: false,
                    task: .transcribe,                      // never translate
                    language: lang,                         // nil = auto-detect
                    temperature: 0.0,
                    temperatureFallbackCount: 0,            // accept first result, no fallback loops (big speedup)
                    usePrefillPrompt: true,
                    detectLanguage: lang == nil,            // auto-detect only when no language pinned
                    skipSpecialTokens: true,
                    withoutTimestamps: true,
                    suppressBlank: true,
                    compressionRatioThreshold: 2.4,
                    logProbThreshold: -1.0,
                    noSpeechThreshold: 0.6,                 // silence gate — returns empty on silent input
                    chunkingStrategy: .none
                )
                print("[VoiceInput] Starting transcription (lang=\(lang ?? "auto"))")
                let t0 = CACurrentMediaTime()
                let results = try await kit.transcribe(audioArray: samples, decodeOptions: options)
                let dt = CACurrentMediaTime() - t0
                let text = results.map { $0.text }.joined(separator: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                print("[VoiceInput] Transcribed in \(String(format: "%.2fs", dt)): '\(text)'")
                await MainActor.run {
                    self.onFinalResult?(text)
                }
            } catch {
                NSLog("[VoiceInput] Transcribe failed: %@", error.localizedDescription)
                await MainActor.run {
                    self.onError?("Transcribe failed: \(error.localizedDescription)")
                }
            }
        }
    }

    func cancel() {
        cleanup()
        bufferLock.lock()
        pcmBuffer.removeAll(keepingCapacity: false)
        bufferLock.unlock()
    }

    private func cleanup() {
        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }
    }
}
