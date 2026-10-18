import Foundation
import AVFoundation
import Combine
import SwiftUI

// MARK: - MiniMaxVoice
// Voice for the chat: speech-to-text with MiniMax `asr-1.0` and spoken answers with `speech-2.8-hd`.
// Everything is in Spanish. The MiniMax API key is the one saved in Settings → Chat (Keychain).

enum MiniMaxVoiceError: LocalizedError {
    case missingKey
    case microphoneDenied
    case recordingFailed
    case empty
    case api(String)

    var errorDescription: String? {
        switch self {
        case .missingKey:
            return String(localized: "Add your MiniMax API key in Settings → Chat to use voice.")
        case .microphoneDenied:
            return String(localized: "Coucou has no microphone access. Allow it in System Settings → Privacy & Security → Microphone.")
        case .recordingFailed:
            return String(localized: "Couldn't start the recording.")
        case .empty:
            return String(localized: "I didn't hear anything. Try again.")
        case .api(let msg):
            return msg
        }
    }
}

enum MiniMaxVoice {
    static let baseURL = "https://api.minimax.io/v1"
    static let asrModel = "asr-1.0"
    static let ttsModel = "speech-2.8-hd"
    static let defaultVoiceID = "male-qn-qingse"

    private static var apiKey: String? {
        guard let k = KeychainStore.shared.get("minimax-api-key"), !k.isEmpty else { return nil }
        return k
    }

    // MARK: Speech to text

    /// Transcribes a recorded audio file (wav/mp3/m4a, ≤ 500 s, ≤ 50 MB) to Spanish text.
    static func transcribe(fileURL: URL) async throws -> String {
        guard let key = apiKey else { throw MiniMaxVoiceError.missingKey }
        guard let url = URL(string: "\(baseURL)/speech_to_text") else { throw MiniMaxVoiceError.recordingFailed }
        let audio = try Data(contentsOf: fileURL)

        let boundary = "coucou-\(UUID().uuidString)"
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".data(using: .utf8)!)
        }
        field("model", asrModel)
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(fileURL.lastPathComponent)\"\r\nContent-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(audio)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        var req = URLRequest(url: url, timeoutInterval: 60)
        req.httpMethod = "POST"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("es", forHTTPHeaderField: "language")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard code == 200 else {
            let msg = ((json?["error"] as? [String: Any])?["message"] as? String)
                ?? ((json?["base_resp"] as? [String: Any])?["status_msg"] as? String)
                ?? "HTTP \(code)"
            throw MiniMaxVoiceError.api(msg)
        }
        let text = (json?["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else { throw MiniMaxVoiceError.empty }
        return text
    }

    // MARK: Text to speech

    /// Synthesizes `text` and returns MP3 data.
    static func synthesize(text: String, voiceID: String) async throws -> Data {
        guard let key = apiKey else { throw MiniMaxVoiceError.missingKey }
        guard let url = URL(string: "\(baseURL)/t2a_v2") else { throw MiniMaxVoiceError.recordingFailed }
        let payload: [String: Any] = [
            "model": ttsModel,
            "text": text,
            "stream": false,
            "language_boost": "Spanish",
            "voice_setting": ["voice_id": voiceID, "speed": 1.0, "vol": 1.0, "pitch": 0],
            "audio_setting": ["sample_rate": 32000, "bitrate": 128000, "format": "mp3", "channel": 1],
        ]
        var req = URLRequest(url: url, timeoutInterval: 60)
        req.httpMethod = "POST"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: req)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let base = json?["base_resp"] as? [String: Any]
        let status = (base?["status_code"] as? Int) ?? ((response as? HTTPURLResponse)?.statusCode == 200 ? 0 : -1)
        guard status == 0 else {
            throw MiniMaxVoiceError.api((base?["status_msg"] as? String) ?? "HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        guard let hex = (json?["data"] as? [String: Any])?["audio"] as? String, !hex.isEmpty,
              let audio = Data(hexString: hex) else {
            throw MiniMaxVoiceError.api(String(localized: "MiniMax returned no audio."))
        }
        return audio
    }

    /// Plain text to read aloud: no code blocks, links or Markdown marks.
    static func speakable(_ markdown: String) -> String {
        var t = markdown
        t = t.replacingOccurrences(of: "```[\\s\\S]*?```", with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: "https?://\\S+", with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: "[*_`#>]+", with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(t.prefix(2500))
    }
}

private extension Data {
    init?(hexString: String) {
        let chars = Array(hexString.utf8)
        guard chars.count % 2 == 0 else { return nil }
        var out = Data(capacity: chars.count / 2)
        func nibble(_ c: UInt8) -> UInt8? {
            switch c {
            case 48...57:  return c - 48
            case 97...102: return c - 87
            case 65...70:  return c - 55
            default:       return nil
            }
        }
        var i = 0
        while i < chars.count {
            guard let hi = nibble(chars[i]), let lo = nibble(chars[i + 1]) else { return nil }
            out.append(hi << 4 | lo)
            i += 2
        }
        self = out
    }
}

// MARK: - VoiceController
// Records the microphone (stops by itself after a pause), transcribes, sends the text through the
// normal chat, and reads the answer aloud. All timers exist only while recording or speaking,
// so the idle cost is nil.

@MainActor
final class VoiceController: NSObject, ObservableObject, AVAudioPlayerDelegate {
    static let shared = VoiceController()

    enum Phase { case idle, recording, transcribing, speaking }
    @Published private(set) var phase: Phase = .idle

    /// Read the answers aloud (also when the question was typed).
    @Published var speakReplies: Bool = UserDefaults.standard.bool(forKey: "voiceSpeakReplies") {
        didSet { UserDefaults.standard.set(speakReplies, forKey: "voiceSpeakReplies") }
    }
    @Published var voiceID: String = UserDefaults.standard.string(forKey: "voiceID") ?? MiniMaxVoice.defaultVoiceID {
        didSet { UserDefaults.standard.set(voiceID, forKey: "voiceID") }
    }

    private var recorder: AVAudioRecorder?
    private var player: AVAudioPlayer?
    private var meterTimer: Timer?
    private var recordingURL: URL?
    private var heardSpeech = false
    private var silentTicks = 0
    private var recordingTicks = 0
    private var awaitingReply = false
    private var historySub: AnyCancellable?
    private var settleWork: DispatchWorkItem?

    private override init() { super.init() }

    // MARK: Entry point of the mic button

    /// Idle → start recording; recording → stop and send; speaking → stop talking.
    func toggle() {
        switch phase {
        case .idle:         Task { await startRecording() }
        case .recording:    finishRecording()
        case .speaking:     stopSpeaking()
        case .transcribing: break
        }
    }

    // MARK: Recording

    private func startRecording() async {
        let state = AppState.shared
        guard KeychainStore.shared.get("minimax-api-key")?.isEmpty == false else {
            fail(MiniMaxVoiceError.missingKey, state: state); return
        }
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        guard granted else { fail(MiniMaxVoiceError.microphoneDenied, state: state); return }

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("coucou-voice-\(UUID().uuidString).wav")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        do {
            let rec = try AVAudioRecorder(url: url, settings: settings)
            rec.isMeteringEnabled = true
            guard rec.record() else { throw MiniMaxVoiceError.recordingFailed }
            recorder = rec
            recordingURL = url
        } catch {
            fail(MiniMaxVoiceError.recordingFailed, state: state); return
        }
        stopSpeaking()
        heardSpeech = false; silentTicks = 0; recordingTicks = 0
        phase = .recording
        state.stateOverride = .thinking
        meterTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.meterTick() }
        }
    }

    /// Stops by itself ~1.6 s after the user stops talking, or after 60 s.
    private func meterTick() {
        guard phase == .recording, let rec = recorder else { return }
        rec.updateMeters()
        let level = rec.averagePower(forChannel: 0)
        recordingTicks += 1
        if level > -35 { heardSpeech = true; silentTicks = 0 }
        else if heardSpeech && level < -45 { silentTicks += 1 }
        if (heardSpeech && silentTicks >= 11) || recordingTicks >= 400 { finishRecording() }
    }

    private func finishRecording() {
        guard phase == .recording else { return }
        meterTimer?.invalidate(); meterTimer = nil
        recorder?.stop(); recorder = nil
        let state = AppState.shared
        guard heardSpeech, let url = recordingURL else {
            phase = .idle
            state.stateOverride = nil
            if let u = recordingURL { try? FileManager.default.removeItem(at: u) }
            fail(MiniMaxVoiceError.empty, state: state)
            return
        }
        phase = .transcribing
        state.stateOverride = .thinking
        Task {
            defer { try? FileManager.default.removeItem(at: url) }
            do {
                let text = try await MiniMaxVoice.transcribe(fileURL: url)
                send(text, state: state)
            } catch {
                fail(error, state: state)
            }
        }
    }

    // MARK: Chat round trip

    private func send(_ text: String, state: AppState) {
        AgentLog.log("voice", "transcribed: \(AgentLog.clip(text, 300))")
        phase = .idle
        awaitingReply = true
        watchForReply()
        state.view = .prompt
        state.chatHistory.append(ChatMessage(role: .user, content: text))
        state.stateOverride = .thinking
        // The hint only goes to the model: the chat shows what the user said.
        let query = text + "\n\n(Respuesta hablada: contesta en español, breve y conversacional, sin Markdown ni listas.)"
        Task { await ClaudeService.shared.chat(query: query, context: state.promptContext, state: state) }
    }

    /// Speaks the next finished assistant message (after a voice question, or always if enabled).
    private func watchForReply() {
        guard historySub == nil else { return }
        historySub = AppState.shared.$chatHistory.sink { [weak self] _ in
            DispatchQueue.main.async { self?.scheduleSettle() }
        }
    }

    private func scheduleSettle() {
        guard awaitingReply || speakReplies else { return }
        settleWork?.cancel()
        // Streamed answers change many times: speak once the text stops changing.
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.speakLastReplyIfReady() }
        }
        settleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9, execute: work)
    }

    private var lastSpokenID: UUID?

    private func speakLastReplyIfReady() {
        let state = AppState.shared
        guard let last = state.chatHistory.last, last.role == .assistant,
              !last.content.isEmpty, state.stateOverride != .thinking,
              last.id != lastSpokenID, phase == .idle else { return }
        guard awaitingReply || speakReplies else { return }
        awaitingReply = false
        lastSpokenID = last.id
        let text = MiniMaxVoice.speakable(last.content)
        guard !text.isEmpty else { return }
        speak(text)
    }

    // MARK: Speaking

    func speak(_ text: String) {
        AgentLog.log("voice", "speak: \(AgentLog.clip(text, 200))")
        let state = AppState.shared
        phase = .speaking
        let voice = voiceID.trimmingCharacters(in: .whitespaces).isEmpty ? MiniMaxVoice.defaultVoiceID : voiceID
        Task {
            do {
                let audio = try await MiniMaxVoice.synthesize(text: text, voiceID: voice)
                guard phase == .speaking else { return }   // cancelled while synthesizing
                let p = try AVAudioPlayer(data: audio)
                p.delegate = self
                player = p
                p.play()
            } catch {
                phase = .idle
                fail(error, state: state)
            }
        }
    }

    func stopSpeaking() {
        player?.stop(); player = nil
        if phase == .speaking { phase = .idle }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.player = nil
            if self.phase == .speaking { self.phase = .idle }
        }
    }

    private func fail(_ error: Error, state: AppState) {
        phase = .idle
        awaitingReply = false
        state.stateOverride = .error
        state.noteMessage = error.localizedDescription
        state.view = .note
    }
}

// MARK: - Views

/// Mic button for the chat box: tap to talk, tap again to send, tap while it speaks to stop.
struct VoiceMicButton: View {
    @ObservedObject private var voice = VoiceController.shared
    var accent: Color

    var body: some View {
        Button { voice.toggle() } label: {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(voice.phase == .idle ? Color(hex: "#8A8F98") : accent)
                .frame(width: 24, height: 24)
        }
        .buttonStyle(.plain)
        .help(String(localized: "Talk to Mochi"))
        .disabled(voice.phase == .transcribing)
    }

    private var icon: String {
        switch voice.phase {
        case .idle:         return "mic.fill"
        case .recording:    return "stop.circle.fill"
        case .transcribing: return "ellipsis.circle"
        case .speaking:     return "speaker.wave.2.fill"
        }
    }
}

/// Settings block for the voice options.
struct VoiceSettingsGroup: View {
    @ObservedObject private var voice = VoiceController.shared

    var body: some View {
        GroupBox("Voice (MiniMax)") {
            VStack(alignment: .leading, spacing: 10) {
                Text("Talk to Mochi with the mic button in the chat. Speech is transcribed with MiniMax asr-1.0 and answers are read aloud with speech-2.8-hd, in Spanish. It uses your MiniMax API key.")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                Toggle("Read every answer aloud", isOn: $voice.speakReplies)
                TextField("Voice ID", text: $voice.voiceID)
                    .textFieldStyle(.roundedBorder)
                Text("Answers to your voice questions are always read aloud. Change the voice ID to use another MiniMax voice.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            .padding(.vertical, 4)
        }
    }
}
