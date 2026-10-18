import Foundation

// MARK: - CLIChat
// Chat through the official `claude` and `codex` command-line tools, signed in with the user's
// subscription (Claude Pro/Max, ChatGPT). Coucou never sees, reads or stores the session token:
// the CLI owns the login (browser SSO) and Coucou only runs it and reads its exit code.
// Not available in the App Store build (the sandbox cannot launch other programs).

enum CLIChatError: LocalizedError {
    case unavailable
    case notInstalled(String)
    case notSignedIn(String)
    case failed(String)
    case timedOut

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return String(localized: "Subscription chat needs the direct-download build of Coucou.")
        case .notInstalled(let name):
            return String(localized: "The \(name) command was not found. Install it, then sign in from Settings → Chat.")
        case .notSignedIn(let name):
            return String(localized: "Not signed in to \(name). Open Settings → Chat and press Sign in.")
        case .failed(let msg):
            return msg
        case .timedOut:
            return String(localized: "The CLI took too long to answer.")
        }
    }
}

final class CLIChat: @unchecked Sendable {
    static let shared = CLIChat()
    private init() {}

    private let lock = NSLock()
    private var cachedPATH: String?

    /// Executable name and the arguments for each action, per provider.
    private struct Tool {
        let exe: String
        let display: String
        let login: [String]
        let status: [String]
    }

    private func tool(for provider: ChatProvider) -> Tool? {
        switch provider {
        case .claudeCLI: return Tool(exe: "claude", display: "Claude Code",
                                     login: ["auth", "login"], status: ["auth", "status"])
        case .codexCLI:  return Tool(exe: "codex", display: "Codex",
                                     login: ["login"], status: ["login", "status"])
        default:         return nil
        }
    }

    // MARK: Public API

    /// True when the CLI is installed and reports an active login (exit code 0).
    func isSignedIn(_ provider: ChatProvider) async throws -> Bool {
        guard let t = tool(for: provider) else { throw CLIChatError.unavailable }
        let exe = try await executable(t)
        let r = try await run(exe, t.status, stdin: nil, timeout: 20)
        return r.status == 0
    }

    /// Runs the CLI's own login, which opens the browser sign-in window. Returns once it finishes.
    func signIn(_ provider: ChatProvider) async throws -> Bool {
        guard let t = tool(for: provider) else { throw CLIChatError.unavailable }
        let exe = try await executable(t)
        _ = try await run(exe, t.login, stdin: nil, timeout: 300)
        return try await isSignedIn(provider)
    }

    /// Sends one prompt (the whole conversation, rendered as text) and returns the answer.
    func ask(_ provider: ChatProvider, model: String, prompt: String) async throws -> String {
        guard let t = tool(for: provider) else { throw CLIChatError.unavailable }
        let exe = try await executable(t)

        var args: [String]
        switch provider {
        case .claudeCLI:
            // Print mode: no tool that can write or run commands is allowed from the notch chat.
            args = ["-p", "--output-format", "text"]
            if !model.isEmpty { args += ["--model", model] }
            args += ["--disallowedTools", "Bash", "Edit", "Write", "NotebookEdit"]
        default:
            args = ["exec", "--skip-git-repo-check", "--sandbox", "read-only"]
            if !model.isEmpty, model != "default" { args += ["-m", model] }
            args.append("-")   // read the prompt from stdin
        }

        let r = try await run(exe, args, stdin: prompt, timeout: 180)
        let out = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if r.status != 0 {
            let err = r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = (err + " " + out).lowercased()
            if lower.contains("login") || lower.contains("not logged") || lower.contains("unauthorized")
                || lower.contains("401") || lower.contains("authenticat") {
                throw CLIChatError.notSignedIn(t.display)
            }
            throw CLIChatError.failed(err.isEmpty ? String(localized: "\(t.display) exited with code \(r.status).") : String(err.suffix(400)))
        }
        guard !out.isEmpty else { throw CLIChatError.failed(String(localized: "\(t.display) returned an empty answer.")) }
        return out
    }

    // MARK: Process plumbing

    private struct Result { let status: Int32; let stdout: String; let stderr: String }

    /// A neutral, empty working directory: the CLI never sees a project from the notch chat.
    private var workDir: URL {
        let url = HookServer.supportDir.appendingPathComponent("cli-chat", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        return url
    }

    private func executable(_ t: Tool) async throws -> URL {
        #if APPSTORE
        throw CLIChatError.unavailable
        #else
        let path = await loginPATH()
        for dir in path.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(dir)).appendingPathComponent(t.exe)
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        throw CLIChatError.notInstalled(t.exe)
        #endif
    }

    /// GUI apps start with a minimal PATH; ask the user's login shell for the real one (once).
    private func loginPATH() async -> String {
        let cached = lock.withLock { cachedPATH }
        if let cached { return cached }
        var parts = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin",
                     NSHomeDirectory() + "/.local/bin", NSHomeDirectory() + "/.claude/local",
                     NSHomeDirectory() + "/.npm-global/bin"]
        if let r = try? await run(URL(fileURLWithPath: "/bin/zsh"), ["-lic", "printf %s \"$PATH\""],
                                  stdin: nil, timeout: 8, usePATH: false),
           r.status == 0, let last = r.stdout.split(separator: "\n").last {
            parts = last.split(separator: ":").map(String.init) + parts
        }
        let joined = parts.joined(separator: ":")
        lock.withLock { cachedPATH = joined }
        return joined
    }

    private func run(_ exe: URL, _ args: [String], stdin: String?, timeout: TimeInterval,
                     usePATH: Bool = true) async throws -> Result {
        #if APPSTORE
        throw CLIChatError.unavailable
        #else
        let pathValue = usePATH ? await loginPATH() : nil
        return try await withCheckedThrowingContinuation { cont in
            let p = Process()
            p.executableURL = exe
            p.arguments = args
            p.currentDirectoryURL = workDir
            var env = ProcessInfo.processInfo.environment
            if let pathValue { env["PATH"] = pathValue }
            env["COUCOU_CHAT"] = "1"   // nb-hook exits at once: this chat must not show up as a coding session
            env["NO_COLOR"] = "1"
            p.environment = env

            let outPipe = Pipe(), errPipe = Pipe(), inPipe = Pipe()
            p.standardOutput = outPipe
            p.standardError = errPipe
            p.standardInput = inPipe

            do { try p.run() } catch {
                cont.resume(throwing: CLIChatError.failed(error.localizedDescription))
                return
            }

            // Drain both pipes concurrently so a chatty CLI can never fill a buffer and stall.
            let group = DispatchGroup()
            var outData = Data(), errData = Data()
            group.enter()
            DispatchQueue.global().async { outData = outPipe.fileHandleForReading.readDataToEndOfFile(); group.leave() }
            group.enter()
            DispatchQueue.global().async { errData = errPipe.fileHandleForReading.readDataToEndOfFile(); group.leave() }

            if let stdin, let data = stdin.data(using: .utf8) {
                inPipe.fileHandleForWriting.write(data)
            }
            try? inPipe.fileHandleForWriting.close()

            var timedOut = false
            let killer = DispatchWorkItem { timedOut = true; if p.isRunning { p.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)

            DispatchQueue.global().async {
                p.waitUntilExit()
                killer.cancel()
                group.wait()
                if timedOut { cont.resume(throwing: CLIChatError.timedOut); return }
                cont.resume(returning: Result(status: p.terminationStatus,
                                              stdout: String(decoding: outData, as: UTF8.self),
                                              stderr: String(decoding: errData, as: UTF8.self)))
            }
        }
        #endif
    }
}
