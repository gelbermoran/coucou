import Foundation
import SwiftUI

// MARK: - Several chats
// Each chat keeps its own messages. The live conversation is still `AppState.chatHistory`; this store mirrors it
// into the current chat, lets you switch, start a new one or clear it, and (optionally) remembers them on this Mac
// in ~/Library/Application Support/NotchBuddy/chats.json (mode 0600).

struct StoredMessage: Codable, Equatable {
    var role: String       // "user" | "assistant" | "action"
    var content: String
}

struct ChatSession: Identifiable, Codable, Equatable {
    var id = UUID()
    var title: String = ""
    var updated: Date = Date()
    var messages: [StoredMessage] = []
}

@MainActor
final class ChatSessions: ObservableObject {
    static let shared = ChatSessions()

    @Published private(set) var sessions: [ChatSession] = []
    @Published private(set) var currentID: UUID

    /// Remember chats between launches (Settings → Chat). On by default.
    @Published var remember: Bool = (UserDefaults.standard.object(forKey: "rememberChats") as? Bool) ?? true {
        didSet {
            UserDefaults.standard.set(remember, forKey: "rememberChats")
            if remember { persistSoon() } else { try? FileManager.default.removeItem(at: Self.fileURL) }
        }
    }

    private var persistWork: DispatchWorkItem?

    private static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NotchBuddy", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        return base.appendingPathComponent("chats.json")
    }

    private init() {
        let fresh = ChatSession()
        currentID = fresh.id
        var loaded: [ChatSession] = []
        if (UserDefaults.standard.object(forKey: "rememberChats") as? Bool) ?? true,
           let data = try? Data(contentsOf: Self.fileURL),
           let list = try? JSONDecoder().decode([ChatSession].self, from: data) {
            loaded = list.filter { !$0.messages.isEmpty }
        }
        sessions = [fresh] + loaded      // every launch starts on a new, empty chat
    }

    var current: ChatSession? { sessions.first { $0.id == currentID } }

    /// Chats worth listing: those with messages, plus the current one.
    var listed: [ChatSession] {
        sessions.filter { !$0.messages.isEmpty || $0.id == currentID }
            .sorted { $0.updated > $1.updated }
    }

    // MARK: Mirror of the live conversation

    /// Called whenever `AppState.chatHistory` changes.
    func historyChanged() {
        guard let i = sessions.firstIndex(where: { $0.id == currentID }) else { return }
        let msgs = AppState.shared.chatHistory.filter { !$0.content.isEmpty }.map {
            StoredMessage(role: Self.name(of: $0.role), content: $0.content)
        }
        guard msgs != sessions[i].messages else { return }
        sessions[i].messages = msgs
        sessions[i].updated = Date()
        if sessions[i].title.isEmpty, let first = msgs.first(where: { $0.role == "user" }) {
            let t = first.content.trimmingCharacters(in: .whitespacesAndNewlines)
            sessions[i].title = String(t.prefix(34)) + (t.count > 34 ? "…" : "")
        }
        persistSoon()
    }

    private static func name(of r: ChatRole) -> String {
        switch r { case .user: return "user"; case .assistant: return "assistant"; case .action: return "action" }
    }
    private static func role(_ s: String) -> ChatRole {
        switch s { case "user": return .user; case "action": return .action; default: return .assistant }
    }

    // MARK: Actions

    /// Starts a new chat. If the current one is still empty, that is already a new chat.
    func newChat() {
        if let c = current, c.messages.isEmpty, AppState.shared.chatHistory.isEmpty { return }
        let fresh = ChatSession()
        sessions.insert(fresh, at: 0)
        load(fresh)
        AgentLog.log("chat", "new chat")
    }

    /// Empties the current chat (it stays the current one).
    func clearCurrent() {
        guard let i = sessions.firstIndex(where: { $0.id == currentID }) else { return }
        sessions[i].messages = []
        sessions[i].title = ""
        load(sessions[i])
        persistSoon()
        AgentLog.log("chat", "chat cleared")
    }

    func switchTo(_ id: UUID) {
        guard id != currentID, let s = sessions.first(where: { $0.id == id }) else { return }
        load(s)
        AgentLog.log("chat", "switched to chat \"\(s.title)\"")
    }

    func delete(_ id: UUID) {
        sessions.removeAll { $0.id == id }
        if id == currentID {
            let fresh = ChatSession()
            sessions.insert(fresh, at: 0)
            load(fresh)
        }
        persistSoon()
    }

    func deleteAll() {
        let fresh = ChatSession()
        sessions = [fresh]
        load(fresh)
        try? FileManager.default.removeItem(at: Self.fileURL)
        AgentLog.log("chat", "all chats deleted")
    }

    /// Makes `session` the live conversation: screen history and the model's memory.
    private func load(_ session: ChatSession) {
        let state = AppState.shared
        currentID = session.id
        VoiceController.shared.stopSpeaking()
        state.stateOverride = nil
        state.promptContext = nil
        state.chatHistory = session.messages.map { ChatMessage(role: Self.role($0.role), content: $0.content) }
        ClaudeService.shared.loadConversation(session.messages.filter { $0.role != "action" }
            .map { ($0.role, $0.content) })
    }

    // MARK: Persistence

    private func persistSoon() {
        guard remember else { return }
        persistWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.writeNow() }
        }
        persistWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    private func writeNow() {
        let toSave = sessions.filter { !$0.messages.isEmpty }
            .sorted { $0.updated > $1.updated }.prefix(50)
            .map { s -> ChatSession in var c = s; c.messages = Array(c.messages.suffix(200)); return c }
        guard let data = try? JSONEncoder().encode(Array(toSave)) else { return }
        let url = Self.fileURL
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

// MARK: - Chats popover

struct ChatsPopover: View {
    @ObservedObject var chats = ChatSessions.shared
    @Binding var isPresented: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(chats.listed) { s in
                        HStack(spacing: 6) {
                            Button {
                                chats.switchTo(s.id); isPresented = false
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(s.title.isEmpty ? String(localized: "New chat") : s.title)
                                            .font(.system(size: 12, weight: s.id == chats.currentID ? .semibold : .regular))
                                            .lineLimit(1)
                                        Text(s.updated.formatted(date: .abbreviated, time: .shortened))
                                            .font(.system(size: 10)).foregroundColor(Color(hex: "#8A8F98"))
                                    }
                                    Spacer()
                                    if s.id == chats.currentID {
                                        Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold))
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            Button { chats.delete(s.id) } label: {
                                Image(systemName: "trash").font(.system(size: 10)).foregroundColor(Color(hex: "#8A8F98"))
                            }
                            .buttonStyle(.plain)
                            .help(String(localized: "Delete this chat"))
                        }
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .background(s.id == chats.currentID ? Color.white.opacity(0.08) : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                }
            }
            .frame(maxHeight: 220)
            Divider().opacity(0.2)
            HStack {
                Button { chats.newChat(); isPresented = false } label: {
                    Label(String(localized: "New chat"), systemImage: "plus")
                }
                Spacer()
                Button(role: .destructive) { chats.clearCurrent(); isPresented = false } label: {
                    Label(String(localized: "Clear this chat"), systemImage: "eraser")
                }
            }
            .font(.system(size: 11.5))
            .buttonStyle(.plain)
            .foregroundColor(Color(hex: "#C8CDD4"))
        }
        .padding(12)
        .frame(width: 280)
        .background(Color(hex: "#16171B"))
    }
}

// MARK: - Actions popover (every function of the assistant, as buttons)

struct ActionsPopover: View {
    @ObservedObject var state: AppState
    @ObservedObject private var timer = TimerEngine.shared
    @Binding var isPresented: Bool
    /// Puts a ready-made sentence in the message box.
    let insert: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            section(String(localized: "Right now"))
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
                    chip("⏱", String(localized: "10 min")) { AssistantActions.startTimer(minutes: 10) }
                    chip("⏱", String(localized: "25 min")) { AssistantActions.startTimer(minutes: 25) }
                } else {
                    chip("⏹", String(localized: "Stop timer")) { timer.cancel() }
                }
            }

            section(String(localized: "Ask Mochi to…"))
            ChipFlowLayout(spacing: 6) {
                compose("⏰", String(localized: "Remind me"), String(localized: "Remind me to … in 20 minutes"))
                compose("🗓", String(localized: "Schedule"), String(localized: "Schedule a meeting with … tomorrow at 3 pm"))
                if Maileroo.isConfigured {
                    compose("✉️", String(localized: "Email"), String(localized: "Send an email to … saying …"))
                }
                ForEach(CustomActions.load().filter(\.isUsable)) { a in
                    compose("⚡", a.name, String(localized: "Use \(a.name): "))
                }
            }
        }
        .padding(12)
        .frame(width: 330)
        .background(Color(hex: "#16171B"))
    }

    private func section(_ title: String) -> some View {
        Text(title).font(.system(size: 10.5, weight: .semibold)).foregroundColor(Color(hex: "#8A8F98"))
    }

    private func chip(_ icon: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button { action(); isPresented = false } label: { chipLabel(icon, label) }.buttonStyle(.plain)
    }

    private func compose(_ icon: String, _ label: String, _ sentence: String) -> some View {
        Button { insert(sentence); isPresented = false } label: { chipLabel(icon, label) }.buttonStyle(.plain)
    }

    private func chipLabel(_ icon: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(icon).font(.system(size: 11))
            Text(label).font(.system(size: 11.5, weight: .medium)).foregroundColor(Color(hex: "#C8CDD4"))
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(Color.white.opacity(0.07))
        .overlay(Capsule().stroke(Color.white.opacity(0.1), lineWidth: 1))
        .clipShape(Capsule())
    }
}
