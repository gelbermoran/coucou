import Foundation

// MARK: - Pure helpers for the agent (no app dependencies, unit-tested)

/// Dates the model sends (ISO 8601, with or without offset).

enum AgentDate {
    static func parse(_ s: String) -> Date? {
        let t = s.trimmingCharacters(in: .whitespaces)
        let iso = ISO8601DateFormatter()
        for opts: ISO8601DateFormatter.Options in [[.withInternetDateTime, .withFractionalSeconds], [.withInternetDateTime]] {
            iso.formatOptions = opts
            if let d = iso.date(from: t) { return d }
        }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        for fmt in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd"] {
            f.dateFormat = fmt
            if let d = f.date(from: t) { return d }
        }
        return nil
    }

    /// Readable local date for confirmation cards and tool results.
    static func display(_ d: Date) -> String {
        d.formatted(date: .abbreviated, time: .shortened)
    }
}


/// Fills the user's API template with the values the assistant provides.
/// Values are JSON-escaped in the body, percent-encoded in the URL, so they can never break the request.
enum CustomAPITemplate {
    /// Escapes `value` so it can sit inside a JSON string in the template.
    static func jsonEscaped(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode(value), let s = String(data: data, encoding: .utf8) else { return value }
        return String(s.dropFirst().dropLast())
    }

    private static func fill(_ template: String, _ values: [String: String], _ transform: (String) -> String) -> String {
        var out = template
        for (k, v) in values { out = out.replacingOccurrences(of: "{{\(k)}}", with: transform(v)) }
        return out
    }

    static func renderBody(_ template: String, values: [String: String]) -> String {
        fill(template, values, jsonEscaped)
    }

    static func renderURL(_ template: String, values: [String: String]) -> String {
        fill(template, values) { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? $0 }
    }

    /// Headers are filled as plain text (a token variable, for example).
    static func renderHeaders(_ template: String, values: [String: String]) -> String {
        fill(template, values) { $0.replacingOccurrences(of: "\n", with: " ") }
    }

    /// "Name: value" per line.
    static func parseHeaders(_ text: String) -> [(String, String)] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            return parts.count == 2 && !parts[0].isEmpty ? (parts[0], parts[1]) : nil
        }
    }

    /// "to, message ,  name" → ["to", "message", "name"] (valid identifiers only, no duplicates).
    static func parseVariables(_ text: String) -> [String] {
        var seen = Set<String>()
        return text.split(whereSeparator: { $0 == "," || $0 == "\n" || $0 == ";" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil }
            .filter { seen.insert($0).inserted }
    }

    /// Tool name the model sees: lowercase letters, digits and underscores.
    static func toolName(_ raw: String) -> String {
        let t = raw.lowercased().replacingOccurrences(of: "[^a-z0-9_]+", with: "_", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return t.isEmpty ? "custom_action" : String(t.prefix(40))
    }
}

/// Some models write the tool call inside the text instead of `tool_calls`
/// (`<minimax:tool_call><invoke name="x"><parameter name="k">v</parameter></invoke></minimax:tool_call>`
/// or `<tool_call>{"name":"x","arguments":{…}}</tool_call>`). This reads both so the action still runs.
enum TextToolCalls {
    struct Call { let name: String; let arguments: [String: Any] }

    static func extract(from text: String) -> [Call] {
        var calls: [Call] = []
        // <invoke name="x"> <parameter name="k">v</parameter>… </invoke>
        if let invoke = try? NSRegularExpression(pattern: "<invoke\\s+name=\"([^\"]+)\"\\s*>([\\s\\S]*?)</invoke>"),
           let param = try? NSRegularExpression(pattern: "<parameter\\s+name=\"([^\"]+)\"\\s*>([\\s\\S]*?)</parameter>") {
            let ns = text as NSString
            for m in invoke.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                let name = ns.substring(with: m.range(at: 1))
                let body = ns.substring(with: m.range(at: 2)) as NSString
                var args: [String: Any] = [:]
                for p in param.matches(in: body as String, range: NSRange(location: 0, length: body.length)) {
                    let key = body.substring(with: p.range(at: 1))
                    let raw = body.substring(with: p.range(at: 2)).trimmingCharacters(in: .whitespacesAndNewlines)
                    if let d = Double(raw), !raw.hasPrefix("0") || raw == "0" || raw.contains(".") { args[key] = d } else { args[key] = raw }
                }
                calls.append(Call(name: name, arguments: args))
            }
        }
        // <tool_call>{json}</tool_call>
        if let tag = try? NSRegularExpression(pattern: "<tool_call>\\s*(\\{[\\s\\S]*?\\})\\s*</tool_call>") {
            let ns = text as NSString
            for m in tag.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                let json = ns.substring(with: m.range(at: 1))
                if let obj = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any],
                   let name = obj["name"] as? String {
                    calls.append(Call(name: name, arguments: (obj["arguments"] as? [String: Any]) ?? (obj["parameters"] as? [String: Any]) ?? [:]))
                }
            }
        }
        return calls
    }

    /// The text without the tool-call markup and without `<think>` blocks.
    static func stripMarkup(_ text: String) -> String {
        var t = text
        for pattern in ["<think>[\\s\\S]*?</think>", "<minimax:tool_call>[\\s\\S]*?</minimax:tool_call>", "<tool_call>[\\s\\S]*?</tool_call>"] {
            t = t.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
