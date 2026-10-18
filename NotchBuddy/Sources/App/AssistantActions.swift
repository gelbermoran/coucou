import SwiftUI

// MARK: - AssistantActions
// The direct actions of the assistant (no language model involved) and the notes that show in the chat
// so you can always see what Mochi did.

@MainActor
enum AssistantActions {
    /// Adds a small "Mochi did this" line to the chat.
    static func note(_ text: String) {
        AppState.shared.chatHistory.append(ChatMessage(role: .action, content: text))
    }

    /// One line per executed tool: what it was and whether it worked.
    static func note(tool: String, result: String) {
        let failed = result.hasPrefix("Error:") || result.hasPrefix("The user declined")
        let label: String
        switch tool {
        case "get_calendar_events":      label = "📅 " + String(localized: "Calendar checked")
        case "create_calendar_event":    label = "🗓 " + String(localized: "Event")
        case "remind_me":                label = "⏰ " + String(localized: "Reminder")
        case "add_to_reminders_app":     label = "✅ " + String(localized: "Task added")
        case "list_tasks":               label = "✅ " + String(localized: "Tasks checked")
        case "start_timer":              label = "⏱ " + String(localized: "Timer")
        case "start_pomodoro":           label = "🍅 " + String(localized: "Pomodoro")
        case "cancel_timer":             label = "⏹ " + String(localized: "Timer stopped")
        case "send_email":               label = "✉️ " + String(localized: "Email")
        default:                         label = "⚡ " + tool
        }
        if failed {
            note("⚠️ \(label): " + AgentLog.clip(result.replacingOccurrences(of: "Error: ", with: ""), 110))
        } else {
            note("\(label) ✓")
        }
    }

    // MARK: Direct commands (also used by the chips)

    static func startTimer(minutes: Int) {
        TimerEngine.shared.startCountdown(seconds: minutes * 60, label: "")
        AgentLog.log("direct", "timer \(minutes) min")
    }

    static func startPomodoro() {
        let d = UserDefaults.standard
        func pref(_ k: String, _ f: Int) -> Int { (d.object(forKey: k) as? Int) ?? f }
        TimerEngine.shared.startPomodoro(work: pref("pomodoroWork", 25), shortBreak: pref("pomodoroShort", 5),
                                         longBreak: pref("pomodoroLong", 15), cycles: pref("pomodoroCycles", 4), label: "")
        AgentLog.log("direct", "pomodoro default")
    }

    static func openAgenda(from: Date, to: Date, title: String) {
        AgendaStore.shared.load(from: from, to: to, title: title)
        AppState.shared.view = .agenda
        NotificationCenter.default.post(name: .hookExpand, object: IslandView.agenda)
    }

    static func openToday() {
        let cal = Calendar.current
        let start = cal.startOfDay(for: Date())
        openAgenda(from: start, to: cal.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86400),
                   title: String(localized: "Today"))
    }
}

// MARK: - Agenda + tasks data

@MainActor
final class AgendaStore: ObservableObject {
    static let shared = AgendaStore()
    @Published var title = ""
    @Published var items: [AgendaItem] = []
    @Published var tasks: [TaskItem] = []
    @Published var loading = false
    @Published var error: String?
    private var range: (Date, Date)?

    func load(from: Date, to: Date, title: String) {
        range = (from, to)
        self.title = title
        refresh()
    }

    func refresh() {
        guard let range else { return }
        loading = true
        error = nil
        Task {
            do { items = try await CalendarService.shared.agenda(from: range.0, to: range.1) }
            catch { items = []; self.error = error.localizedDescription }
            tasks = (try? await CalendarService.shared.tasks()) ?? []
            loading = false
        }
    }
}

// MARK: - Card: agenda on the left, tasks on the right

struct AgendaCardView: View {
    @ObservedObject var state: AppState
    @ObservedObject private var store = AgendaStore.shared

    var body: some View {
        ZStack(alignment: .leading) {
            CardBackground(wash: nil)
            HStack(alignment: .top, spacing: 14) {
                column(title: "📅 " + store.title) {
                    if let e = store.error {
                        Text(e).font(.system(size: 11)).foregroundColor(Color(hex: "#F4505E"))
                    } else if store.items.isEmpty && !store.loading {
                        Text("Nothing scheduled.").font(.system(size: 12)).foregroundColor(Color(hex: "#8A8F98"))
                    }
                    ForEach(store.items) { item in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(item.allDay ? String(localized: "all day") : item.start.formatted(date: .omitted, time: .shortened))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(Color(hex: "#8A8F98"))
                                .frame(width: 58, alignment: .leading)
                            Text(item.title).font(.system(size: 12.5)).lineLimit(1)
                        }
                    }
                }
                Divider().opacity(0.15)
                column(title: "✅ " + String(localized: "Tasks")) {
                    if store.tasks.isEmpty && !store.loading {
                        Text("No pending tasks.").font(.system(size: 12)).foregroundColor(Color(hex: "#8A8F98"))
                    }
                    ForEach(store.tasks) { t in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("•").foregroundColor(Color(hex: "#8A8F98"))
                            VStack(alignment: .leading, spacing: 0) {
                                Text(t.title).font(.system(size: 12.5)).lineLimit(1)
                                if let due = t.due {
                                    Text(AgentDate.display(due)).font(.system(size: 10)).foregroundColor(Color(hex: "#8A8F98"))
                                }
                            }
                        }
                    }
                }
            }
            .padding(.leading, 84)
            .padding(.trailing, 14)
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private func column<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title).font(.system(size: 12, weight: .semibold))
                Spacer()
                if store.loading { ProgressView().scaleEffect(0.5).frame(width: 12, height: 12) }
            }
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 4) { content() }
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Quick actions shown in an empty chat

struct AssistantChips: View {
    @ObservedObject var state: AppState
    @ObservedObject private var timer = TimerEngine.shared

    var body: some View {
        ChipFlowLayout(spacing: 6) {
            chip("📅", String(localized: "Agenda")) { AssistantActions.openToday() }
            chip("✅", String(localized: "Tasks")) {
                AgendaStore.shared.load(from: Calendar.current.startOfDay(for: Date()),
                                        to: Calendar.current.startOfDay(for: Date()).addingTimeInterval(86400),
                                        title: String(localized: "Today"))
                state.view = .agenda
            }
            if timer.session == nil {
                chip("🍅", String(localized: "Pomodoro")) { AssistantActions.startPomodoro() }
                chip("⏱", String(localized: "5 min")) { AssistantActions.startTimer(minutes: 5) }
                chip("⏱", String(localized: "25 min")) { AssistantActions.startTimer(minutes: 25) }
            } else {
                chip("⏹", String(localized: "Stop timer")) { timer.cancel() }
            }
        }
        .padding(.horizontal, 10)
    }

    private func chip(_ icon: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(icon).font(.system(size: 11))
                Text(label).font(.system(size: 11.5, weight: .medium)).foregroundColor(Color(hex: "#C8CDD4"))
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Color.white.opacity(0.07))
            .overlay(Capsule().stroke(Color.white.opacity(0.1), lineWidth: 1))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
