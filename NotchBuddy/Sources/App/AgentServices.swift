import Foundation
import EventKit
import UserNotifications
import AppKit

// MARK: - Errors

struct AgentError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

// MARK: - Calendar and Reminders (macOS EventKit: Google, iCloud, Outlook accounts added to the Mac)

struct AgendaItem: Identifiable, Sendable {
    let id = UUID()
    let start: Date
    let end: Date
    let title: String
    let location: String?
    let calendar: String
    let allDay: Bool
}

struct TaskItem: Identifiable, Sendable {
    let id = UUID()
    let title: String
    let due: Date?
    let list: String
}

@MainActor
final class CalendarService {
    static let shared = CalendarService()
    private let store = EKEventStore()
    private init() {}

    /// Asks for calendar access. An accessory app has to be active for macOS to show the prompt.
    private func ensureEventsAccess() async throws {
        let before = EKEventStore.authorizationStatus(for: .event)
        AgentLog.log("calendar", "events authorization status=\(before.rawValue) (3=full access, 2=denied, 0=not asked)")
        if before != .fullAccess {
            NSApp.activate(ignoringOtherApps: true)
            let granted = (try? await store.requestFullAccessToEvents()) ?? false
            AgentLog.log("calendar", "events access request → \(granted)")
            guard granted else {
                throw AgentError(String(localized: "Coucou has no calendar access. Allow it in System Settings → Privacy & Security → Calendars."))
            }
        }
    }

    private func ensureRemindersAccess() async throws {
        let before = EKEventStore.authorizationStatus(for: .reminder)
        AgentLog.log("calendar", "reminders authorization status=\(before.rawValue)")
        if before != .fullAccess {
            NSApp.activate(ignoringOtherApps: true)
            let granted = (try? await store.requestFullAccessToReminders()) ?? false
            AgentLog.log("calendar", "reminders access request → \(granted)")
            guard granted else {
                throw AgentError(String(localized: "Coucou has no Reminders access. Allow it in System Settings → Privacy & Security → Reminders."))
            }
        }
    }

    // MARK: Agenda

    func agenda(from: Date, to: Date) async throws -> [AgendaItem] {
        try await ensureEventsAccess()
        store.refreshSourcesIfNecessary()
        let pred = store.predicateForEvents(withStart: from, end: to, calendars: nil)
        let events = store.events(matching: pred).sorted { $0.startDate < $1.startDate }
        AgentLog.log("calendar", "query \(from) → \(to): \(events.count) event(s) in \(store.calendars(for: .event).count) calendar(s)")
        return events.prefix(60).map {
            AgendaItem(start: $0.startDate, end: $0.endDate, title: $0.title ?? "—", location: $0.location,
                       calendar: $0.calendar.title, allDay: $0.isAllDay)
        }
    }

    func events(from: Date, to: Date) async throws -> String {
        let items = try await agenda(from: from, to: to)
        if items.isEmpty { return "No events between \(AgentDate.display(from)) and \(AgentDate.display(to))." }
        return items.map { e in
            var line = "\(AgentDate.display(e.start))–\(e.allDay ? "all day" : e.end.formatted(date: .omitted, time: .shortened)) | \(e.title)"
            if let loc = e.location, !loc.isEmpty { line += " | \(loc)" }
            return line + " | calendar: \(e.calendar)"
        }.joined(separator: "\n")
    }

    func createEvent(title: String, start: Date, end: Date, location: String?, notes: String?) async throws -> String {
        try await ensureEventsAccess()
        guard let calendar = store.defaultCalendarForNewEvents else {
            throw AgentError(String(localized: "There is no calendar to save the event in."))
        }
        let ev = EKEvent(eventStore: store)
        ev.title = title
        ev.startDate = start
        ev.endDate = end
        ev.location = location
        ev.notes = notes
        ev.calendar = calendar
        ev.addAlarm(EKAlarm(relativeOffset: -600))   // 10 minutes before
        try store.save(ev, span: .thisEvent)
        AgentLog.log("calendar", "event saved id=\(ev.eventIdentifier ?? "?") in \"\(calendar.title)\"")
        return "Event created in calendar \"\(calendar.title)\": \(title), \(AgentDate.display(start))."
    }

    // MARK: Tasks (Reminders app)

    func tasks() async throws -> [TaskItem] {
        try await ensureRemindersAccess()
        let pred = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
        // Convert inside the callback: EKReminder itself must not cross threads
        let items: [TaskItem] = await withCheckedContinuation { cont in
            // @Sendable: EventKit calls back on its own queue, so this must not run as main-actor code
            store.fetchReminders(matching: pred) { @Sendable found in
                let mapped = (found ?? []).map { r in
                    TaskItem(title: r.title ?? "—",
                             due: r.dueDateComponents.flatMap { Calendar.current.date(from: $0) },
                             list: r.calendar.title)
                }
                cont.resume(returning: mapped)
            }
        }
        AgentLog.log("calendar", "pending reminders: \(items.count)")
        return items.sorted { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) }
    }

    func tasksText() async throws -> String {
        let items = try await tasks()
        if items.isEmpty { return "No pending tasks or reminders." }
        return items.prefix(40).map { t in
            "• \(t.title)" + (t.due.map { " — due \(AgentDate.display($0))" } ?? "") + " (\(t.list))"
        }.joined(separator: "\n")
    }

    func addToReminders(title: String, due: Date?, notes: String?, alarm: Bool = true) async throws -> String {
        try await ensureRemindersAccess()
        guard let list = store.defaultCalendarForNewReminders() else {
            throw AgentError(String(localized: "There is no Reminders list to save in."))
        }
        let r = EKReminder(eventStore: store)
        r.title = title
        r.notes = notes
        r.calendar = list
        if let due {
            r.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: due)
            if alarm { r.addAlarm(EKAlarm(absoluteDate: due)) }
        }
        try store.save(r, commit: true)
        AgentLog.log("calendar", "reminder saved in \"\(list.title)\": \(title)")
        return "Added to Reminders (\(list.title)): \(title)" + (due.map { ", due \(AgentDate.display($0))" } ?? "")
    }
}

// MARK: - "Remind me in X": local notification that also wakes Mochi when the app is running

@MainActor
final class ReminderScheduler: NSObject, UNUserNotificationCenterDelegate {
    static let shared = ReminderScheduler()
    private override init() { super.init() }

    func install() { UNUserNotificationCenter.current().delegate = self }

    func schedule(message: String, at date: Date) async throws -> String {
        let center = UNUserNotificationCenter.current()
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        guard granted else {
            throw AgentError(String(localized: "Coucou cannot send notifications. Allow them in System Settings → Notifications."))
        }
        guard date.timeIntervalSinceNow > 1 else { throw AgentError("That time is already in the past.") }
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Reminder")
        content.body = message
        content.userInfo = ["coucouReminder": true]
        let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        try await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: trigger))
        AgentLog.log("reminder", "alert scheduled for \(date): \(message)")
        // Also list it in the Reminders app so it is visible there (no second alarm: Mochi's alert fires)
        var visibleIn = ""
        do {
            _ = try await CalendarService.shared.addToReminders(title: message, due: date, notes: nil, alarm: false)
            visibleIn = " It also appears in the Reminders app."
        } catch {
            AgentLog.log("reminder", "not added to the Reminders app: \(error.localizedDescription)")
        }
        return "Reminder set for \(AgentDate.display(date)): \(message).\(visibleIn)"
    }

    // App is running: show Mochi's fun alert instead of a plain banner.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        let isReminder = notification.request.content.userInfo["coucouReminder"] as? Bool == true
        let body = notification.request.content.body
        if isReminder {
            await MainActor.run { TimerEngine.shared.reminderAlert(body) }
            return []
        }
        return [.banner]
    }
}

// MARK: - Email through Maileroo (plain, or one of your templates)

enum Maileroo {
    static var isConfigured: Bool {
        let k = KeychainStore.shared
        return (k.get("maileroo-api-key")?.isEmpty == false) && (k.get("maileroo-from")?.isEmpty == false)
    }

    /// Template mode: the assistant fills the template variables you list in Settings.
    static var templateID: Int? {
        Int(UserDefaults.standard.string(forKey: "mailerooTemplateID")?.trimmingCharacters(in: .whitespaces) ?? "")
    }
    static var templateVariables: [String] {
        CustomAPITemplate.parseVariables(UserDefaults.standard.string(forKey: "mailerooVariables") ?? "")
    }
    /// How the user wants emails written and sent (tone, language, signature…).
    static var instructions: String {
        (UserDefaults.standard.string(forKey: "emailInstructions") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func send(to: [String], subject: String, body: String?, data: [String: String]) async throws -> String {
        let k = KeychainStore.shared
        guard let key = k.get("maileroo-api-key"), !key.isEmpty, let from = k.get("maileroo-from"), !from.isEmpty else {
            throw AgentError(String(localized: "Maileroo is not configured. Add the sending key and sender in Settings → Assistant."))
        }
        let template = templateID
        let endpoint = template == nil ? "https://smtp.maileroo.com/api/v2/emails" : "https://smtp.maileroo.com/api/v2/emails/template"
        guard let url = URL(string: endpoint) else { throw AgentError("Bad URL") }
        var fromObj: [String: Any] = ["address": from]
        if let name = k.get("maileroo-from-name"), !name.isEmpty { fromObj["display_name"] = name }
        var payload: [String: Any] = ["from": fromObj, "to": to.map { ["address": $0] }, "subject": subject]
        if let template {
            payload["template_id"] = template
            payload["template_data"] = data
        } else {
            payload["plain"] = body ?? ""
        }
        var req = URLRequest(url: url, timeoutInterval: 30)
        req.httpMethod = "POST"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)
        AgentLog.log("email", "POST \(endpoint) to=\(to.joined(separator: ",")) subject=\(AgentLog.clip(subject, 80)) template=\(template.map(String.init) ?? "none") data=\(AgentLog.clip(String(describing: data), 200))")

        let (respData, response) = try await URLSession.shared.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        let text = String(data: respData.prefix(500), encoding: .utf8) ?? ""
        AgentLog.log("email", "← HTTP \(code) \(AgentLog.clip(text, 300))")
        let json = (try? JSONSerialization.jsonObject(with: respData)) as? [String: Any]
        guard (200..<300).contains(code), (json?["success"] as? Bool) != false else {
            throw AgentError((json?["message"] as? String) ?? "Maileroo error (HTTP \(code))")
        }
        return "Email sent to \(to.joined(separator: ", "))."
    }
}

// MARK: - Custom actions: any HTTP request you define (WhatsApp, Slack, a webhook, n8n…)
// Each action becomes a tool the assistant can call. You choose its variables ({{message}}, {{to}}…);
// the assistant fills them. The list lives in the Keychain because the headers carry tokens.

struct CustomAction: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String = "send_whatsapp"
    var description: String = "Send a WhatsApp message"
    var variables: String = "to, message"
    var method: String = "POST"
    var url: String = ""
    var headers: String = ""        // one "Name: value" per line; may contain {{variables}}
    var body: String = ""           // JSON with {{variables}}
    var defaults: String = ""       // one "variable=value" per line, used when the assistant gives none
    var confirm: Bool = true

    var toolName: String { CustomAPITemplate.toolName(name) }
    var variableNames: [String] { CustomAPITemplate.parseVariables(variables) }
    var defaultValues: [String: String] {
        var d: [String: String] = [:]
        for line in defaults.split(whereSeparator: \.isNewline) {
            let p = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if p.count == 2, !p[0].isEmpty, !p[1].isEmpty { d[p[0]] = p[1] }
        }
        return d
    }
    var host: String { URL(string: CustomAPITemplate.renderURL(url, values: Dictionary(uniqueKeysWithValues: variableNames.map { ($0, "x") })))?.host ?? url }
    var isUsable: Bool { !url.trimmingCharacters(in: .whitespaces).isEmpty }

    /// Meta WhatsApp Cloud API, ready to fill in.
    static var whatsAppPreset: CustomAction {
        CustomAction(name: "send_whatsapp", description: "Send a WhatsApp message to a phone number",
                     variables: "to, message", method: "POST",
                     url: "https://graph.facebook.com/v21.0/PHONE_NUMBER_ID/messages",
                     headers: "Authorization: Bearer YOUR_ACCESS_TOKEN\nContent-Type: application/json",
                     body: #"{"messaging_product":"whatsapp","to":"{{to}}","type":"text","text":{"body":"{{message}}"}}"#,
                     defaults: "", confirm: true)
    }
}

enum CustomActions {
    private static let key = "custom-actions"

    static func load() -> [CustomAction] {
        if let raw = KeychainStore.shared.get(key), let data = raw.data(using: .utf8),
           let list = try? JSONDecoder().decode([CustomAction].self, from: data) { return list }
        return migrateLegacy()
    }

    static func save(_ list: [CustomAction]) {
        if let data = try? JSONEncoder().encode(list), let s = String(data: data, encoding: .utf8) {
            KeychainStore.shared.set(key, value: s)
        }
        AgentLog.log("actions", "saved \(list.count) custom action(s): \(list.map(\.toolName).joined(separator: ", "))")
    }

    /// The first version had one fixed WhatsApp API: turn it into an action.
    private static func migrateLegacy() -> [CustomAction] {
        struct Legacy: Codable { var method: String; var url: String; var headers: String; var body: String }
        guard let raw = KeychainStore.shared.get("whatsapp-api-config"), let data = raw.data(using: .utf8),
              let old = try? JSONDecoder().decode(Legacy.self, from: data), !old.url.isEmpty else { return [] }
        var action = CustomAction.whatsAppPreset
        action.method = old.method; action.url = old.url; action.headers = old.headers; action.body = old.body
        if !(old.body.contains("{{to}}") || old.url.contains("{{to}}")) { action.variables = "message" }
        if let to = KeychainStore.shared.get("whatsapp-default-to"), !to.isEmpty { action.defaults = "to=\(to)" }
        save([action])
        return [action]
    }

    static func find(toolName: String) -> CustomAction? {
        load().first { $0.toolName == toolName && $0.isUsable }
    }

    /// Runs the request. Never logs headers or the body template, only the method, host and status.
    static func run(_ action: CustomAction, values: [String: String]) async throws -> String {
        let urlString = CustomAPITemplate.renderURL(action.url, values: values)
        guard let url = URL(string: urlString), let scheme = url.scheme?.lowercased(),
              scheme == "https" || (scheme == "http" && ["localhost", "127.0.0.1"].contains(url.host ?? "")) else {
            throw AgentError(String(localized: "The API URL must be https://."))
        }
        var req = URLRequest(url: url, timeoutInterval: 30)
        req.httpMethod = action.method.uppercased()
        for (name, value) in CustomAPITemplate.parseHeaders(CustomAPITemplate.renderHeaders(action.headers, values: values)) {
            req.setValue(value, forHTTPHeaderField: name)
        }
        if req.httpMethod != "GET", !action.body.isEmpty {
            req.httpBody = CustomAPITemplate.renderBody(action.body, values: values).data(using: .utf8)
            if req.value(forHTTPHeaderField: "Content-Type") == nil { req.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        }
        AgentLog.log("api", "\(action.toolName): \(req.httpMethod ?? "") \(url.host ?? "") values=\(AgentLog.clip(String(describing: values), 300))")
        let (data, response) = try await URLSession.shared.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        let text = String(data: data.prefix(600), encoding: .utf8) ?? ""
        AgentLog.log("api", "\(action.toolName): ← HTTP \(code) \(AgentLog.clip(text, 400))")
        guard (200..<300).contains(code) else { throw AgentError("HTTP \(code): \(text)") }
        return "Done (HTTP \(code)). \(AgentLog.clip(text, 200))"
    }
}
