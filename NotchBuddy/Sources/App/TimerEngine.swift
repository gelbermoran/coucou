import Foundation
import AVFoundation
import SwiftUI
import UserNotifications

// MARK: - TimerEngine
// Countdowns and Pomodoro. The 1 Hz ticker exists only while a timer runs (nothing runs otherwise).
// The last seconds are counted aloud; the end plays a synthesized jingle, a fun spoken line,
// a Mochi celebration and a system notification.

@MainActor
final class TimerEngine: NSObject, ObservableObject {
    static let shared = TimerEngine()

    enum Phase { case countdown, work, shortBreak, longBreak }

    struct Session {
        var label: String
        var phase: Phase
        var endDate: Date
        var phaseSeconds: Int
        var cycle: Int            // 1-based work block
        var cycles: Int           // 0 for a plain countdown
        var workMin: Int
        var shortMin: Int
        var longMin: Int
    }

    @Published private(set) var session: Session?
    @Published private(set) var remaining: Int = 0
    /// Fun message shown on the card when a phase ends.
    @Published private(set) var alertMessage: String?

    /// Menu bar text ("⏱ 12:34"), set by the app delegate. nil = clear.
    var onMenuTitle: ((String?) -> Void)?

    @Published var spokenCountdown: Bool = (UserDefaults.standard.object(forKey: "timerSpokenCountdown") as? Bool) ?? true {
        didSet { UserDefaults.standard.set(spokenCountdown, forKey: "timerSpokenCountdown") }
    }

    private var ticker: Timer?
    private var alertWork: DispatchWorkItem?
    private var lastSpokenSecond = -1
    private let synth = AVSpeechSynthesizer()
    private var jinglePlayer: AVAudioPlayer?

    private override init() { super.init() }

    // MARK: Start / stop

    func startCountdown(seconds: Int, label: String) {
        let secs = max(1, min(seconds, 24 * 3600))
        begin(Session(label: label, phase: .countdown, endDate: Date().addingTimeInterval(Double(secs)),
                      phaseSeconds: secs, cycle: 1, cycles: 0, workMin: 0, shortMin: 0, longMin: 0))
    }

    func startPomodoro(work: Int, shortBreak: Int, longBreak: Int, cycles: Int, label: String) {
        let w = max(1, min(work, 120)), s = max(1, min(shortBreak, 60)), l = max(1, min(longBreak, 90))
        let c = max(1, min(cycles, 12))
        begin(Session(label: label, phase: .work, endDate: Date().addingTimeInterval(Double(w * 60)),
                      phaseSeconds: w * 60, cycle: 1, cycles: c, workMin: w, shortMin: s, longMin: l))
    }

    func cancel() {
        AgentLog.log("timer", "CANCEL")
        stopTicker()
        session = nil
        remaining = 0
        alertMessage = nil
        onMenuTitle?(nil)
        synth.stopSpeaking(at: .immediate)
    }

    private func begin(_ s: Session) {
        AgentLog.log("timer", "START \(s.phase) label=\"\(s.label)\" \(s.phaseSeconds)s cycles=\(s.cycles)")
        stopTicker()
        alertMessage = nil
        session = s
        remaining = s.phaseSeconds
        lastSpokenSecond = -1
        requestNotificationPermission()
        SoundEngine.shared.play("pop")
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(ticker!, forMode: .common)
        updateMenuTitle()
        showCard()
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }

    // MARK: Tick

    private func tick() {
        guard let s = session else { stopTicker(); return }
        remaining = max(0, Int(ceil(s.endDate.timeIntervalSinceNow)))
        updateMenuTitle()
        if spokenCountdown, remaining >= 1, remaining <= 5, remaining != lastSpokenSecond, s.phaseSeconds > 10 {
            lastSpokenSecond = remaining
            speakQuick("\(remaining)")
        }
        if remaining <= 0 { phaseEnded() }
    }

    private func updateMenuTitle() {
        guard session != nil else { onMenuTitle?(nil); return }
        onMenuTitle?("⏱ " + Self.format(remaining))
    }

    static func format(_ secs: Int) -> String {
        let h = secs / 3600, m = (secs % 3600) / 60, s = secs % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }

    // MARK: Phase changes

    private func phaseEnded() {
        guard var s = session else { return }
        AgentLog.log("timer", "PHASE END \(s.phase) cycle=\(s.cycle)/\(s.cycles)")
        switch s.phase {
        case .countdown:
            finishAll(title: s.label.isEmpty ? String(localized: "Time's up!") : s.label,
                      line: Self.funLines.randomElement() ?? "")
        case .work:
            let isLast = s.cycle >= s.cycles
            s.phase = isLast ? .longBreak : .shortBreak
            let mins = isLast ? s.longMin : s.shortMin
            s.endDate = Date().addingTimeInterval(Double(mins * 60))
            s.phaseSeconds = mins * 60
            session = s
            lastSpokenSecond = -1
            remaining = s.phaseSeconds
            let line = isLast
                ? String(localized: "Last pomodoro done! Take a long \(mins) minute break, you earned it.")
                : String(localized: "Pomodoro \(s.cycle) done! \(mins) minute break: stretch, water, dance.")
            celebrate(title: String(localized: "Pomodoro done!"), line: line)
        case .shortBreak:
            s.phase = .work
            s.cycle += 1
            s.endDate = Date().addingTimeInterval(Double(s.workMin * 60))
            s.phaseSeconds = s.workMin * 60
            session = s
            lastSpokenSecond = -1
            remaining = s.phaseSeconds
            celebrate(title: String(localized: "Back to work!"),
                      line: String(localized: "Break over. Pomodoro \(s.cycle): \(s.workMin) minutes, let's go!"))
        case .longBreak:
            finishAll(title: String(localized: "Cycle complete!"),
                      line: String(localized: "All pomodoros done. You are a machine!"))
        }
    }

    private func finishAll(title: String, line: String) {
        stopTicker()
        session = nil
        remaining = 0
        onMenuTitle?(nil)
        celebrate(title: title, line: line)
    }

    // MARK: Fun alert

    private static var funLines: [String] {
        [String(localized: "Time's up! You nailed it, champ!"),
         String(localized: "Ding ding ding! Time is over, superstar!"),
         String(localized: "Done! Mochi is doing a little dance for you."),
         String(localized: "Boom! The clock has spoken. Great job!")]
    }

    /// A scheduled reminder came due: same fun alert, no second system notification.
    func reminderAlert(_ text: String) {
        celebrate(title: String(localized: "Reminder"), line: text, notify: false)
    }

    private func celebrate(title: String, line: String, notify: Bool = true) {
        AgentLog.log("timer", "ALERT \(title): \(line)")
        alertMessage = line
        playJingle()
        NotificationCenter.default.post(name: .triggerEmote, object: BotEmote.proud)
        showCard()
        if notify { sendNotification(title: title, body: line) }
        // Say the fun line: MiniMax voice when configured, system voice otherwise.
        if KeychainStore.shared.get("minimax-api-key")?.isEmpty == false {
            VoiceController.shared.speak(line)
        } else {
            speakQuick(line)
        }
        alertWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.alertMessage = nil
                if self?.session == nil { NotificationCenter.default.post(name: .islandCollapse, object: nil) }
            }
        }
        alertWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: work)
    }

    private func showCard() {
        AppState.shared.view = .timer
        NotificationCenter.default.post(name: .hookExpand, object: IslandView.timer)
    }

    // MARK: Sound

    private func speakQuick(_ text: String) {
        let u = AVSpeechUtterance(string: text)
        // Speak in the language the app is shown in
        let lang = (Bundle.main.preferredLocalizations.first ?? "en").hasPrefix("es") ? "es-ES" : "en-US"
        u.voice = AVSpeechSynthesisVoice(language: lang)
        u.rate = 0.5
        synth.speak(u)
    }

    private func playJingle() {
        guard let data = Self.jingleWAV() else { return }
        jinglePlayer = try? AVAudioPlayer(data: data)
        jinglePlayer?.volume = 0.7
        jinglePlayer?.play()
    }

    /// A short happy fanfare built in code: rising arpeggio, a "boing" glide and a shimmering chord.
    nonisolated static func jingleWAV() -> Data? {
        let rate = 44100.0
        var samples: [Int16] = []
        func tone(_ f0: Double, _ f1: Double, _ dur: Double, vol: Double, harmonics: [Double] = [1, 0.4, 0.2]) {
            let n = Int(dur * rate)
            var phase = 0.0
            for i in 0..<n {
                let t = Double(i) / Double(n)
                let f = f0 + (f1 - f0) * t
                phase += 2 * .pi * f / rate
                var v = 0.0
                for (k, h) in harmonics.enumerated() { v += h * sin(phase * Double(k + 1)) }
                let env = min(1, t * 20) * pow(1 - t, 1.6)   // quick attack, soft decay
                samples.append(Int16(max(-1, min(1, v / 1.6 * env * vol)) * 32000))
            }
        }
        func chord(_ freqs: [Double], _ dur: Double, vol: Double) {
            let n = Int(dur * rate)
            var phases = [Double](repeating: 0, count: freqs.count)
            for i in 0..<n {
                let t = Double(i) / Double(n)
                var v = 0.0
                for (k, f) in freqs.enumerated() {
                    phases[k] += 2 * .pi * f / rate
                    v += sin(phases[k]) + 0.3 * sin(phases[k] * 2)
                }
                let shimmer = 1 + 0.15 * sin(2 * .pi * 9 * Double(i) / rate)
                let env = min(1, t * 30) * pow(1 - t, 1.2)
                samples.append(Int16(max(-1, min(1, v / Double(freqs.count) / 1.4 * env * shimmer * vol)) * 32000))
            }
        }
        // C major arpeggio up, playful glide, then a bright chord
        for f in [523.25, 659.25, 783.99, 1046.5] { tone(f, f, 0.11, vol: 0.8) }
        tone(1046.5, 1568.0, 0.14, vol: 0.7)            // boing up
        tone(1318.5, 1046.5, 0.10, vol: 0.6)
        chord([523.25, 659.25, 783.99, 1046.5], 0.9, vol: 0.9)

        var d = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: UInt16) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 2)) }
        let byteCount = UInt32(samples.count * 2)
        d.append("RIFF".data(using: .ascii)!); u32(36 + byteCount)
        d.append("WAVEfmt ".data(using: .ascii)!); u32(16); u16(1); u16(1)
        u32(UInt32(rate)); u32(UInt32(rate) * 2); u16(2); u16(16)
        d.append("data".data(using: .ascii)!); u32(byteCount)
        samples.withUnsafeBufferPointer { d.append(Data(buffer: $0)) }
        return d
    }

    // MARK: System notification

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func sendNotification(title: String, body: String) {
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        c.sound = nil   // the jingle already played
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }
}

// MARK: - Card shown in the island

struct TimerCardView: View {
    @ObservedObject private var engine = TimerEngine.shared

    var body: some View {
        ZStack(alignment: .leading) {
            CardBackground(wash: nil)
            VStack(alignment: .leading, spacing: 6) {
                if let alert = engine.alertMessage {
                    Text(alert)
                        .font(.system(size: 15, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                        .transition(.scale.combined(with: .opacity))
                }
                if let s = engine.session {
                    Text(phaseTitle(s))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(Color(hex: "#8A8F98"))
                    Text(TimerEngine.format(engine.remaining))
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    ProgressView(value: Double(s.phaseSeconds - engine.remaining), total: Double(max(1, s.phaseSeconds)))
                        .tint(Color(hex: "#F4505E"))
                        .frame(maxWidth: 260)
                    SecondaryButton(String(localized: "Cancel")) { engine.cancel() }
                } else if engine.alertMessage == nil {
                    Text("No timer running.")
                        .font(.system(size: 13))
                        .foregroundColor(Color(hex: "#8A8F98"))
                }
            }
            .padding(.leading, 98)
            .padding(.trailing, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func phaseTitle(_ s: TimerEngine.Session) -> String {
        switch s.phase {
        case .countdown:  return s.label.isEmpty ? String(localized: "Countdown") : s.label
        case .work:       return String(localized: "Focus · pomodoro \(s.cycle) of \(s.cycles)")
        case .shortBreak: return String(localized: "Short break")
        case .longBreak:  return String(localized: "Long break")
        }
    }
}
