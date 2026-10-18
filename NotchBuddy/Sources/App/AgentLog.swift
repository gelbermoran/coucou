import Foundation
import AppKit

// MARK: - AgentLog
// Everything Mochi does as an assistant goes to ~/Library/Logs/NotchBuddy/agent.log:
// each chat turn, what was sent to the model, the tool calls it asked for, the result of each tool,
// confirmations, timers and permissions. API keys and request headers are never written.

enum AgentLog {
    static let fileName = "agent.log"
    private static let queue = DispatchQueue(label: "coucou.agentlog")

    static var fileURL: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/NotchBuddy/\(fileName)")
    }

    /// `category` is a short tag: chat, llm, tool, confirm, timer, calendar, email, api, voice, intent…
    nonisolated static func log(_ category: String, _ message: String) {
        let text = "[\(category)] \(clip(message, 1200))"
        queue.async { appendAppLog(fileName, text, timestampFormat: "yyyy-MM-dd HH:mm:ss.SSS") }
    }

    nonisolated static func clip(_ s: String, _ max: Int) -> String {
        let one = s.replacingOccurrences(of: "\n", with: " ⏎ ")
        return one.count > max ? String(one.prefix(max)) + "…(+\(one.count - max))" : one
    }

    /// The last `lines` lines, newest last.
    static func tail(_ lines: Int = 40) -> String {
        queue.sync {
            guard let data = try? Data(contentsOf: fileURL), let text = String(data: data, encoding: .utf8) else { return "" }
            return text.split(separator: "\n", omittingEmptySubsequences: true).suffix(lines).joined(separator: "\n")
        }
    }

    static func clear() {
        queue.sync { try? FileManager.default.removeItem(at: fileURL) }
    }

    @MainActor static func reveal() {
        if !FileManager.default.fileExists(atPath: fileURL.path) { log("log", "agent log opened") }
        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
    }
}
