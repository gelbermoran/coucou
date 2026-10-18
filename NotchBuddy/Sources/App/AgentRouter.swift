import Foundation

// MARK: - AgentRouter
// Clear, simple commands (timers, Pomodoro, reminders, agenda, tasks) run right here without a language model:
// instant, free, and they work with every provider. Anything else goes to the model, which can use tools.

@MainActor
enum AgentRouter {
    /// True when the message was handled locally.
    static func handle(_ query: String, state: AppState) async -> Bool {
        guard AgentTools.enabled, let intent = AgentIntentParser.parse(query) else { return false }
        AgentLog.log("intent", "matched \(intent) for: \(AgentLog.clip(query, 200))")

        let reply: String
        switch intent {
        case .timer(let seconds, let label):
            TimerEngine.shared.startCountdown(seconds: seconds, label: label)
            reply = String(localized: "⏱ Timer started: \(TimerEngine.format(seconds)).")

        case .pomodoro(let work, let short, let long, let cycles):
            let d = UserDefaults.standard
            func pref(_ k: String, _ f: Int) -> Int { (d.object(forKey: k) as? Int) ?? f }
            let w = work ?? pref("pomodoroWork", 25), s = short ?? pref("pomodoroShort", 5)
            let l = long ?? pref("pomodoroLong", 15), c = cycles ?? pref("pomodoroCycles", 4)
            TimerEngine.shared.startPomodoro(work: w, shortBreak: s, longBreak: l, cycles: c, label: "")
            reply = String(localized: "🍅 Pomodoro started: \(w) min focus, \(s) min break, \(c) blocks.")

        case .cancelTimer:
            TimerEngine.shared.cancel()
            reply = String(localized: "⏹ Timer stopped.")

        case .reminder(let message, let at):
            do {
                _ = try await ReminderScheduler.shared.schedule(message: message, at: at)
                reply = String(localized: "⏰ I'll remind you \(AgentDate.display(at)): \(message)")
            } catch {
                reply = "⚠️ " + error.localizedDescription
            }

        case .agenda(let from, let to, let title):
            AgendaStore.shared.load(from: from, to: to, title: title)
            do {
                let items = try await CalendarService.shared.agenda(from: from, to: to)
                if items.isEmpty {
                    reply = String(localized: "📅 Nothing scheduled \(title).")
                } else {
                    let lines = items.map { e in
                        "• " + (e.allDay ? String(localized: "all day") : e.start.formatted(date: .omitted, time: .shortened)) + " — " + e.title
                    }
                    reply = "📅 " + title + "\n" + lines.joined(separator: "\n")
                }
            } catch {
                reply = "⚠️ " + error.localizedDescription
            }

        case .tasks:
            do {
                let items = try await CalendarService.shared.tasks()
                if items.isEmpty {
                    reply = String(localized: "✅ No pending tasks.")
                } else {
                    reply = "✅ " + String(localized: "Pending") + "\n" + items.prefix(20).map { t in
                        "• " + t.title + (t.due.map { " — " + AgentDate.display($0) } ?? "")
                    }.joined(separator: "\n")
                }
            } catch {
                reply = "⚠️ " + error.localizedDescription
            }
        }

        AgentLog.log("intent", "reply: \(AgentLog.clip(reply, 300))")
        state.chatHistory.append(ChatMessage(role: .assistant, content: reply))
        state.stateOverride = nil
        state.view = .prompt
        NotificationCenter.default.post(name: .triggerEmote, object: BotEmote.happy)
        return true
    }
}
