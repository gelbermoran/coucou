import SwiftUI
import AppKit

// MARK: - Settings → Assistant
// What Mochi can do for you: calendar, reminders, timers, email (Maileroo) and your own HTTP actions
// (WhatsApp, a webhook, n8n…). Keys and API headers live in the Keychain.

struct AssistantSettingsView: View {
    @AppStorage("agentToolsEnabled") private var toolsEnabled: Bool = true
    @AppStorage("pomodoroWork") private var pomodoroWork: Int = 25
    @AppStorage("pomodoroShort") private var pomodoroShort: Int = 5
    @AppStorage("pomodoroLong") private var pomodoroLong: Int = 15
    @AppStorage("pomodoroCycles") private var pomodoroCycles: Int = 4
    @AppStorage("mailerooTemplateID") private var templateID: String = ""
    @AppStorage("mailerooVariables") private var templateVariables: String = ""
    @AppStorage("emailInstructions") private var emailInstructions: String = ""
    @ObservedObject private var timer = TimerEngine.shared

    @State private var mailKey = KeychainStore.shared.get("maileroo-api-key") ?? ""
    @State private var mailFrom = KeychainStore.shared.get("maileroo-from") ?? ""
    @State private var mailName = KeychainStore.shared.get("maileroo-from-name") ?? ""

    @State private var actions: [CustomAction] = CustomActions.load()
    @State private var message = ""
    @State private var logText = AgentLog.tail(25)

    var body: some View {
        GroupBox("Assistant") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Let Mochi act for me", isOn: $toolsEnabled)
                Text("Mochi can read your calendar, set reminders and timers, and prepare emails and messages. Anything that sends a message or creates an event always waits for your click.")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                Text("Simple commands (timers, Pomodoro, reminders, agenda, tasks) work with any model. Emails, meetings and custom actions need Anthropic, OpenAI, Google or MiniMax.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            .padding(.vertical, 4)
        }

        GroupBox("Timers and Pomodoro") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Count the last 5 seconds aloud", isOn: $timer.spokenCountdown)
                Stepper("Focus: \(pomodoroWork) min", value: $pomodoroWork, in: 1...120)
                Stepper("Short break: \(pomodoroShort) min", value: $pomodoroShort, in: 1...60)
                Stepper("Long break: \(pomodoroLong) min", value: $pomodoroLong, in: 1...90)
                Stepper("Focus blocks: \(pomodoroCycles)", value: $pomodoroCycles, in: 1...12)
                Button("Test the countdown (8 s)") {
                    timer.startCountdown(seconds: 8, label: String(localized: "Test"))
                }
                .buttonStyle(.bordered)
                Text("Try \"timer 10 minutes\", \"pomodoro\" or \"remind me to drink water in 20 minutes\" in the chat or with the mic. A timer ends with a jingle and a fun alert.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            .padding(.vertical, 4)
        }

        GroupBox("Calendar and Reminders") {
            VStack(alignment: .leading, spacing: 10) {
                Text("Uses the Calendar and Reminders apps of your Mac, so Google, iCloud and Outlook calendars work if they are added there.")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                HStack {
                    Button("Check calendar access") {
                        Task {
                            do {
                                let n = try await CalendarService.shared.agenda(from: Date(), to: Date().addingTimeInterval(7 * 86400)).count
                                message = String(localized: "✓ Calendar access granted. \(n) events in the next 7 days.")
                            } catch {
                                message = "❌ " + error.localizedDescription
                            }
                        }
                    }
                    .buttonStyle(.bordered)
                    Button("Check Reminders access") {
                        Task {
                            do {
                                let n = try await CalendarService.shared.tasks().count
                                message = String(localized: "✓ Reminders access granted. \(n) pending.")
                            } catch {
                                message = "❌ " + error.localizedDescription
                            }
                        }
                    }
                    .buttonStyle(.bordered)
                    Button("Open System Settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .buttonStyle(.bordered)
                }
                if !message.isEmpty { Text(message).font(.system(size: 11)).foregroundColor(.secondary) }
            }
            .padding(.vertical, 4)
        }

        GroupBox("Email (Maileroo)") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Mochi sends email through the Maileroo API. Create a sending key in your Maileroo dashboard (Domains → Sending Keys).")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                SecureField("Sending key", text: $mailKey).textFieldStyle(.roundedBorder)
                TextField("Sender address (you@yourdomain.com)", text: $mailFrom).textFieldStyle(.roundedBorder)
                TextField("Sender name (optional)", text: $mailName).textFieldStyle(.roundedBorder)

                Divider()
                Text("Template (optional)").font(.system(size: 11, weight: .semibold))
                TextField("Template ID (empty = plain text emails)", text: $templateID).textFieldStyle(.roundedBorder)
                TextField("Template variables, e.g. name, message", text: $templateVariables).textFieldStyle(.roundedBorder)
                Text("With a template ID, Mochi fills these variables and Maileroo builds the email from your template. Without it, Mochi writes a plain text email.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)

                Text("How should Mochi write and send emails?").font(.system(size: 11, weight: .semibold))
                TextEditor(text: $emailInstructions)
                    .font(.system(size: 12))
                    .frame(height: 70)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
                Text("Example: Write in Spanish, formal tone, short. Sign as Gelber Moran, Parquesoft Pasto.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)

                Button("Save") {
                    KeychainStore.shared.set("maileroo-api-key", value: mailKey.trimmingCharacters(in: .whitespacesAndNewlines))
                    KeychainStore.shared.set("maileroo-from", value: mailFrom.trimmingCharacters(in: .whitespacesAndNewlines))
                    KeychainStore.shared.set("maileroo-from-name", value: mailName.trimmingCharacters(in: .whitespacesAndNewlines))
                    AgentLog.log("email", "settings saved (template=\(templateID.isEmpty ? "none" : templateID), variables=\(templateVariables))")
                    message = String(localized: "✓ Maileroo saved.")
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.vertical, 4)
        }

        GroupBox("Custom actions") {
            VStack(alignment: .leading, spacing: 10) {
                Text("Teach Mochi to call any HTTP API: WhatsApp, a webhook, n8n, Slack… Give the action a name, say when to use it, list its variables, and write the request. Use {{variable}} in the URL, headers and body: Mochi fills them. Values are escaped so they cannot break your JSON.")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)

                ForEach($actions) { $action in
                    DisclosureGroup {
                        actionEditor($action)
                    } label: {
                        HStack {
                            Text(action.name.isEmpty ? String(localized: "New action") : action.name)
                                .font(.system(size: 12, weight: .semibold))
                            if !action.isUsable {
                                Text("incomplete").font(.system(size: 10)).foregroundColor(.orange)
                            }
                        }
                    }
                }

                HStack {
                    Menu("Add action") {
                        Button("WhatsApp (Meta Cloud API)") { actions.append(.whatsAppPreset) }
                        Button("Blank action") {
                            actions.append(CustomAction(name: "my_action", description: "", variables: "message",
                                                        method: "POST", url: "", headers: "Content-Type: application/json",
                                                        body: #"{"text":"{{message}}"}"#))
                        }
                    }
                    Button("Save actions") {
                        CustomActions.save(actions)
                        message = String(localized: "✓ Actions saved.")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(.vertical, 4)
        }

        GroupBox("Activity log") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Everything Mochi does is written to agent.log: what it sent to the model, the actions it asked for and their results. API keys are never logged.")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                ScrollView {
                    Text(logText.isEmpty ? String(localized: "Nothing logged yet.") : logText)
                        .font(.system(size: 10, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(height: 140)
                .background(Color(NSColor.textBackgroundColor))
                .cornerRadius(6)
                HStack {
                    Button("Refresh") { logText = AgentLog.tail(25) }.buttonStyle(.bordered)
                    Button("Open in Finder") { AgentLog.reveal() }.buttonStyle(.bordered)
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(AgentLog.tail(200), forType: .string)
                        message = String(localized: "✓ Log copied.")
                    }.buttonStyle(.bordered)
                    Button("Clear") { AgentLog.clear(); logText = "" }.buttonStyle(.bordered)
                }
            }
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder private func actionEditor(_ action: Binding<CustomAction>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Name (e.g. send_whatsapp)", text: action.name).textFieldStyle(.roundedBorder)
            TextField("When should Mochi use it?", text: action.description).textFieldStyle(.roundedBorder)
            TextField("Variables, e.g. to, message", text: action.variables).textFieldStyle(.roundedBorder)
            Picker("Method", selection: action.method) {
                ForEach(["POST", "PUT", "PATCH", "GET"], id: \.self) { Text($0).tag($0) }
            }
            .pickerStyle(.segmented)
            TextField("URL (https://…)", text: action.url).textFieldStyle(.roundedBorder)
            Text("Headers, one per line").font(.system(size: 11, weight: .semibold))
            TextEditor(text: action.headers)
                .font(.system(size: 11, design: .monospaced))
                .frame(height: 56)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
            Text("Body (JSON)").font(.system(size: 11, weight: .semibold))
            TextEditor(text: action.body)
                .font(.system(size: 11, design: .monospaced))
                .frame(height: 80)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
            Text("Default values, one per line: variable=value").font(.system(size: 11, weight: .semibold))
            TextEditor(text: action.defaults)
                .font(.system(size: 11, design: .monospaced))
                .frame(height: 40)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
            Toggle("Ask me before running it", isOn: action.confirm)
            Button("Remove action", role: .destructive) {
                actions.removeAll { $0.id == action.wrappedValue.id }
                CustomActions.save(actions)
            }
            .buttonStyle(.bordered)
        }
        .padding(.vertical, 6)
    }
}
