import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
    private(set) var islandController: IslandWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Ignore SIGPIPE — prevents crash when nb-hook closes socket before we write response
        signal(SIGPIPE, SIG_IGN)
        // Warm up Keychain cache on main thread BEFORE any poller or view touches it
        _ = KeychainStore.shared
        NSApp.setActivationPolicy(.accessory)
        setupMenuBarItem()
        setupIsland()
    }

    // MARK: - Menu bar

    private func setupMenuBarItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem?.button else { return }
        button.image = NSImage(named: "MenuBarIcon") ?? NSImage(systemSymbolName: "circle.fill", accessibilityDescription: "Coucou")
        button.image?.size = NSSize(width: 24, height: 18)
        button.image?.accessibilityDescription = "Coucou"
        button.image?.isTemplate = true

        let menu = NSMenu()
        menu.addItem(withTitle: String(localized: "Open Coucou"), action: #selector(openIsland), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: String(localized: "Settings…"), action: #selector(openSettings), keyEquivalent: ",")
        menu.addItem(withTitle: String(localized: "Open assistant log"), action: #selector(openAgentLog), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: String(localized: "Quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        statusItem?.menu = menu

        // Countdown in the menu bar while a timer runs
        TimerEngine.shared.onMenuTitle = { [weak self] title in
            self?.statusItem?.button?.title = title.map { " " + $0 } ?? ""
            self?.statusItem?.button?.imagePosition = title == nil ? .imageOnly : .imageLeading
        }
        ReminderScheduler.shared.install()
    }

    // MARK: - Actions

    @objc private func openAgentLog() { AgentLog.reveal() }

    @objc private func openIsland() {
        islandController?.expand(to: .overview)
    }

    private var settingsWindow: NSWindow?

    @objc private func openSettingsFromNotification(_ notification: Notification) {
        if let section = notification.object as? String {
            UserDefaults.standard.set(section, forKey: "settingsSection")
        }
        openSettings()
    }

    @objc private func openSettings() {
        // The island floats above every window; fold it away so it can't cover Settings.
        if AppState.shared.mode == .expanded { islandController?.collapse() }

        if let w = settingsWindow, w.isVisible {
            placeBelowIsland(w)
            // Show in the Dock / Cmd-Tab while Settings is open (see below)
            NSApp.setActivationPolicy(.regular)
            w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return
        }
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 560),
                           styleMask: [.titled, .closable, .miniaturizable, .resizable],
                           backing: .buffered, defer: false)
        win.title = String(localized: "Settings — Coucou")
        let host = NSHostingView(rootView: SettingsView())
        host.sizingOptions = [.minSize]
        win.contentView = host
        win.contentMinSize = NSSize(width: 640, height: 420)
        win.isReleasedWhenClosed = false
        win.hidesOnDeactivate = false
        placeBelowIsland(win)
        settingsWindow = win
        // Coucou is a menu-bar app without a Dock icon, so its windows vanish behind the next app you
        // switch to and there is no way back. While Settings is open it behaves like a normal app
        // (Dock icon, Cmd-Tab); when the window closes it goes back to living in the notch.
        NSApp.setActivationPolicy(.regular)
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: win, queue: .main) { _ in
            NSApp.setActivationPolicy(.accessory)
        }
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Centres the window horizontally and keeps its title bar clear of the island panel
    /// (320 pt tall at the top of the notch screen), shrinking it to fit if needed.
    private func placeBelowIsland(_ win: NSWindow) {
        let screen = IslandWindowController.notchScreen() ?? NSScreen.main ?? win.screen
        guard let screen else { win.center(); return }
        let visible = screen.visibleFrame
        let islandBottom = screen.frame.maxY - 320 - 12   // island panel height + margin
        let top = min(visible.maxY, islandBottom)
        var frame = win.frame
        frame.size.height = min(frame.height, max(top - visible.minY - 12, win.minSize.height))
        frame.origin.x = visible.midX - frame.width / 2
        frame.origin.y = max(visible.minY + 12, top - frame.height)
        win.setFrame(frame, display: true)
    }

    // MARK: - Island setup

    private func setupIsland() {
        islandController = IslandWindowController()
        islandController?.showWindow(nil)
        islandController?.fsm.launch()
        HookServer.shared.start()
        IntegrationGate.shared.bind(to: AppState.shared)
        N8nPoller.shared.start()
        VercelPoller.shared.start()
        ResendPoller.shared.start()
        GithubPoller.shared.start()
        StripePoller.shared.start()
        CalcomPoller.shared.start()
        NotionPoller.shared.start()
        NotificationCenter.default.addObserver(self, selector: #selector(openSettingsFromNotification(_:)),
                                               name: .openFullSettings, object: nil)
        #if !APPSTORE
        _ = MusicController.shared
        #endif
        #if DEBUG
        // Debug builds only: `-debugChats 1` exercises the multi-chat store and logs what it finds
        if UserDefaults.standard.bool(forKey: "debugChats") {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                let st = AppState.shared, cs = ChatSessions.shared
                @MainActor func report(_ what: String) {
                    AgentLog.log("debug", "\(what): history=\(st.chatHistory.map { $0.content }) listed=\(cs.listed.map { $0.title.isEmpty ? "(empty)" : $0.title })")
                }
                report("start")
                st.chatHistory.append(ChatMessage(role: .user, content: "primer chat pregunta"))
                st.chatHistory.append(ChatMessage(role: .assistant, content: "respuesta uno"))
                report("after chat 1")
                cs.newChat()
                report("after newChat")
                st.chatHistory.append(ChatMessage(role: .user, content: "segundo chat"))
                st.chatHistory.append(ChatMessage(role: .action, content: "⏱ Timer ✓"))
                report("after chat 2")
                if let first = cs.listed.first(where: { $0.title.hasPrefix("primer") }) { cs.switchTo(first.id) }
                report("switched back to 1")
                cs.clearCurrent()
                report("cleared chat 1")
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("NotchBuddy/chats.json")
                let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
                AgentLog.log("debug", "chats.json exists=\(FileManager.default.fileExists(atPath: url.path)) perms=\(String(describing: attrs?[.posixPermissions]))")
            }
        }
        #endif
        #if DEBUG
        // Debug builds only: `-debugOpenSettings 1` opens Settings, then closes it, logging the activation policy
        if UserDefaults.standard.bool(forKey: "debugOpenSettings") {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                AgentLog.log("debug", "policy before = \(NSApp.activationPolicy().rawValue) (1=accessory, 0=regular)")
                self.openSettings()
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                AgentLog.log("debug", "policy with Settings open = \(NSApp.activationPolicy().rawValue), window visible = \(self.settingsWindow?.isVisible ?? false)")
                self.settingsWindow?.close()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                AgentLog.log("debug", "policy after closing = \(NSApp.activationPolicy().rawValue)")
            }
        }
        #endif
        #if DEBUG
        // Debug builds only: `open Coucou.app --args -debugCommand "timer 5 seconds"` runs a chat message at launch
        if let cmd = UserDefaults.standard.string(forKey: "debugCommand"), !cmd.isEmpty {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                AgentLog.log("debug", "running debugCommand: \(cmd)")
                AppState.shared.chatHistory.append(ChatMessage(role: .user, content: cmd))
                await ClaudeService.shared.chat(query: cmd, context: nil, state: AppState.shared)
            }
        }
        #endif
    }
}
