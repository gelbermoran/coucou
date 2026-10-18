import Foundation

// Deterministic, dependency-free interpreter for assistant commands (Spanish and English).
// `parse` returns nil unless the text is clearly one of the supported commands; anything else
// goes to the language model. Design rule: a false positive is worse than a false negative, so
// every matcher is whitelist-based (all words of the sentence must be understood).

enum AgentIntent: Equatable {
    case timer(seconds: Int, label: String)
    case pomodoro(work: Int?, shortBreak: Int?, longBreak: Int?, cycles: Int?)   // minutes; nil = use preferences
    case cancelTimer
    case reminder(message: String, at: Date)
    case agenda(from: Date, to: Date, title: String)   // `to` is exclusive (24:00 / next Monday 00:00)
    case tasks
}

enum AgentIntentParser {
    static func parse(_ text: String, now: Date = Date(), calendar: Calendar = .current) -> AgentIntent? {
        guard let all = tokenize(text) else { return nil }
        let t = stripPolite(all)
        guard !t.isEmpty else { return nil }
        let n = t.map { $0.n }
        if isCancel(n) { return .cancelTimer }
        if let i = parsePomodoro(n) { return i }
        if let i = parseTimer(t) { return i }
        if isTasks(n) { return .tasks }
        if let i = parseAgenda(n, now: now, cal: calendar) { return i }
        if let i = parseReminder(t, now: now, cal: calendar) { return i }
        return nil
    }

    // MARK: - Tokens

    /// `n` = lowercase, accent-free token (used for matching); `orig` = what the user typed (used for labels).
    /// Glued number/letter runs ("7pm", "1h30") are split into several tokens sharing the same `src`.
    private struct Tok { var orig: String; var n: String; var src: Int }

    private static func tokenize(_ text: String) -> [Tok]? {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty || s.count > 200 { return nil }                      // long text: not a command
        if s.contains("\n") || s.contains("\r") { return nil }           // multi-line / code: not a command
        for bad in ["`", "{", "}", "=>", "</", "();"] where s.contains(bad) { return nil }
        s = s.replacingOccurrences(of: #"(?i)\b([ap])\.\s?m\b\.?"#, with: "$1m", options: .regularExpression)
        var out: [Tok] = []
        let edge = CharacterSet(charactersIn: "\"“”‘’'¿¡()[]")
        for (idx, raw) in s.split(whereSeparator: { $0.isWhitespace }).enumerated() {
            let rawS = String(raw)
            let folded = rawS.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
            let chars = Array(folded.replacingOccurrences(of: "'", with: "").replacingOccurrences(of: "’", with: ""))
            var pieces: [String] = []
            var cur = ""
            func kind(_ c: Character) -> Int { c.isNumber ? 1 : (c.isLetter ? 2 : 1) }   // kept separators belong to digit runs
            for (k, c) in chars.enumerated() {
                if c.isLetter || c.isNumber {
                    if let last = cur.last, kind(last) != kind(c) { pieces.append(cur); cur = "" }
                    cur.append(c)
                } else if ".,:/".contains(c), k > 0, k < chars.count - 1, chars[k - 1].isNumber, chars[k + 1].isNumber {
                    cur.append(c)
                } else if !cur.isEmpty {
                    pieces.append(cur); cur = ""
                }
            }
            if !cur.isEmpty { pieces.append(cur) }
            let orig = rawS.trimmingCharacters(in: edge)
            for p in pieces { out.append(Tok(orig: orig, n: p, src: idx)) }
        }
        return out.isEmpty ? nil : out
    }

    private static let politeSeqs: [[String]] = [
        ["por", "favor"], ["please"], ["pls"], ["oye", "mochi"], ["hey", "mochi"], ["hola", "mochi"], ["hi", "mochi"],
        ["oye"], ["hey"], ["hola"], ["mochi"], ["porfa"], ["porfis"], ["gracias"], ["thanks"], ["thank", "you"],
        ["ok"], ["okay"], ["vale"], ["could", "you"], ["can", "you"], ["would", "you"], ["will", "you"],
        ["me", "puedes"], ["me", "podrias"], ["puedes"], ["podrias"],
    ]

    private static func stripPolite(_ toks: [Tok]) -> [Tok] {
        var t = toks
        var changed = true
        while changed && !t.isEmpty {
            changed = false
            for seq in politeSeqs where t.count > seq.count {
                if Array(t.prefix(seq.count)).map({ $0.n }) == seq { t.removeFirst(seq.count); changed = true; break }
                if Array(t.suffix(seq.count)).map({ $0.n }) == seq { t.removeLast(seq.count); changed = true; break }
            }
        }
        return t
    }

    private static func joinOrig(_ ts: [Tok]) -> String {
        var parts: [String] = []
        var last = -1
        for t in ts where t.src != last { parts.append(t.orig); last = t.src }
        return parts.joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: " .,;:!?¿¡\"'"))
    }

    // MARK: - Numbers and durations

    private static let smallNums: [String: Int] = [
        "un": 1, "uno": 1, "una": 1, "one": 1, "dos": 2, "two": 2, "tres": 3, "three": 3, "cuatro": 4, "four": 4,
        "cinco": 5, "five": 5, "seis": 6, "six": 6, "siete": 7, "seven": 7, "ocho": 8, "eight": 8, "nueve": 9, "nine": 9,
        "diez": 10, "ten": 10, "once": 11, "eleven": 11, "doce": 12, "twelve": 12, "trece": 13, "thirteen": 13,
        "catorce": 14, "fourteen": 14, "quince": 15, "fifteen": 15, "dieciseis": 16, "sixteen": 16,
        "diecisiete": 17, "seventeen": 17, "dieciocho": 18, "eighteen": 18, "diecinueve": 19, "nineteen": 19,
        "veinte": 20, "twenty": 20, "veintiuno": 21, "veintiun": 21, "veintidos": 22, "veintitres": 23,
        "veinticuatro": 24, "veinticinco": 25, "veintiseis": 26, "veintisiete": 27, "veintiocho": 28, "veintinueve": 29,
    ]
    private static let tensNums: [String: Int] = [
        "treinta": 30, "thirty": 30, "cuarenta": 40, "forty": 40, "cincuenta": 50, "fifty": 50, "sesenta": 60, "sixty": 60,
        "setenta": 70, "seventy": 70, "ochenta": 80, "eighty": 80, "noventa": 90, "ninety": 90,
        "cien": 100, "ciento": 100, "hundred": 100,
    ]

    private static func isDigits(_ s: String) -> Bool {
        guard let f = s.first, f.isNumber else { return false }
        return !s.contains(":") && !s.contains("/")
    }

    /// Number (digits or basic words) at `i`. Returns the value and the index after it.
    private static func numberAt(_ n: [String], _ i: Int, article: Bool) -> (v: Double, next: Int)? {
        guard i < n.count else { return nil }
        let w = n[i]
        if isDigits(w) {
            guard let v = Double(w.replacingOccurrences(of: ",", with: ".")) else { return nil }
            return (v, i + 1)
        }
        if article && (w == "a" || w == "an") { return (1, i + 1) }
        if let v = smallNums[w] { return (Double(v), i + 1) }
        if let t = tensNums[w] {
            if t < 100 {
                if i + 2 < n.count, n[i + 1] == "y", let u = smallNums[n[i + 2]], u < 10 { return (Double(t + u), i + 3) }
                if i + 1 < n.count, let u = smallNums[n[i + 1]], u < 10 { return (Double(t + u), i + 2) }
            }
            return (Double(t), i + 1)
        }
        return nil
    }

    private static func unitSecs(_ w: String) -> Double? {
        switch w {
        case "s", "seg", "segs", "segundo", "segundos", "sec", "secs", "second", "seconds": return 1
        case "m", "min", "mins", "minuto", "minutos", "minute", "minutes": return 60
        case "h", "hr", "hrs", "hora", "horas", "hour", "hours": return 3600
        default: return nil
        }
    }

    private static func segmentAt(_ n: [String], _ i: Int) -> (secs: Double, unit: Double, end: Int)? {
        guard i < n.count else { return nil }
        // "media hora", "half (an) hour"
        if n[i] == "media", i + 1 < n.count, n[i + 1] == "hora" { return (1800, 0, i + 2) }
        if n[i] == "half" {
            var k = i + 1
            if k < n.count, n[k] == "an" { k += 1 }
            if k < n.count, n[k] == "hour" { return (1800, 0, k + 1) }
        }
        // "(un) cuarto de hora", "(a) quarter (of) (an) hour"
        var k = i
        if k < n.count, n[k] == "un" || n[k] == "a" { k += 1 }
        if k + 2 < n.count, n[k] == "cuarto", n[k + 1] == "de", n[k + 2] == "hora" { return (900, 0, k + 3) }
        if k < n.count, n[k] == "quarter" {
            k += 1
            if k < n.count, n[k] == "of" { k += 1 }
            if k < n.count, n[k] == "an" { k += 1 }
            if k < n.count, n[k] == "hour" { return (900, 0, k + 1) }
        }
        // number + unit, with optional "y medio/a" / "and a half"
        guard let num = numberAt(n, i, article: true), num.next < n.count, let u = unitSecs(n[num.next]) else { return nil }
        var secs = num.v * u
        var e = num.next + 1
        if e + 1 < n.count, n[e] == "y", n[e + 1] == "medio" || n[e + 1] == "media" { secs += u / 2; e += 2 }
        else if e + 2 < n.count, n[e] == "and", n[e + 1] == "a", n[e + 2] == "half" { secs += u / 2; e += 3 }
        else if e + 1 < n.count, n[e] == "and", n[e + 1] == "half" { secs += u / 2; e += 2 }
        return (secs, u, e)
    }

    /// Duration starting at `i` ("1 hora 15 minutos", "1h30", "hora y media"…). Returns seconds and the end index.
    private static func durationAt(_ n: [String], _ i: Int) -> (secs: Double, end: Int)? {
        var j = i
        var total = 0.0
        var found = false
        var lastUnit = 0.0
        while j < n.count {
            var start = j
            if found, n[j] == "y" || n[j] == "and" || n[j] == "con", j + 1 < n.count { start = j + 1 }
            if let s = segmentAt(n, start) { total += s.secs; lastUnit = s.unit; j = s.end; found = true; continue }
            // "1h30": bare number after hours means minutes
            if found, lastUnit == 3600, start == j, isDigits(n[j]), let v = Int(n[j]), v < 60 {
                total += Double(v * 60); lastUnit = 60; j += 1; continue
            }
            break
        }
        return found ? (total, j) : nil
    }

    // MARK: - Timer

    private static let timerPre: Set<String> = [
        "pon", "ponme", "pone", "poner", "poneme", "inicia", "iniciar", "empieza", "empezar", "comienza", "comenzar",
        "arranca", "activa", "activar", "crea", "crear", "configura", "programa", "quiero", "necesito", "dame", "hazme", "haz",
        "set", "start", "begin", "create", "make", "give", "me", "i", "need", "want", "to", "a", "an", "the",
        "un", "una", "el", "nuevo", "nueva", "new", "mi", "my",
    ]
    private static let timerConnectors: Set<String> = ["de", "of", "for", "por", "para", "en", "in", "a", "durante"]

    private static func timerKeyword(_ n: [String]) -> (idx: Int, end: Int)? {
        for i in 0..<n.count {
            if ["temporizador", "timer", "countdown"].contains(n[i]) { return (i, i + 1) }
            if i + 1 < n.count, n[i] == "cuenta", n[i + 1] == "regresiva" || n[i + 1] == "atras" { return (i, i + 2) }
            if i + 1 < n.count, n[i] == "count", n[i + 1] == "down" { return (i, i + 2) }
        }
        return nil
    }

    private static func parseTimer(_ t: [Tok]) -> AgentIntent? {
        let n = t.map { $0.n }
        var found: (secs: Double, end: Int)?
        if n[0] == "avisame" || n[0] == "alertame" {
            guard n.count >= 3, n[1] == "en", let d = durationAt(n, 2) else { return nil }
            found = d
        } else {
            guard let kw = timerKeyword(n) else { return nil }
            let pre = Array(n[0..<kw.idx])
            for s in 0...pre.count {
                guard pre[0..<s].allSatisfy({ timerPre.contains($0) }) else { break }
                if s == pre.count {                      // duration after the keyword
                    var j = kw.end
                    while j < n.count, timerConnectors.contains(n[j]) { j += 1 }
                    if let d = durationAt(n, j) { found = d }
                    else if let b = numberAt(n, j, article: false), isDigits(n[j]),
                            b.next == n.count || n[b.next] == "para" || n[b.next] == "for" {
                        found = (b.v * 60, b.next)       // "timer 25": bare number = minutes
                    }
                } else if let d = durationAt(n, s), d.end == kw.idx {   // "set a 10 minute timer"
                    found = (d.secs, kw.end)
                }
                if found != nil { break }
            }
        }
        guard let f = found, f.secs >= 1, f.secs <= 86400 else { return nil }
        var label = ""
        if f.end < n.count {
            guard n[f.end] == "para" || n[f.end] == "for", f.end + 1 < n.count else { return nil }
            label = joinOrig(Array(t[(f.end + 1)...]))
            guard !label.isEmpty, label.count <= 80 else { return nil }
        }
        return .timer(seconds: Int(f.secs.rounded()), label: label)
    }

    // MARK: - Pomodoro

    private static func parsePomodoro(_ n: [String]) -> AgentIntent? {
        guard n.contains(where: { $0 == "pomodoro" || $0 == "pomodoros" }) else { return nil }
        let verbs: Set<String> = ["inicia", "iniciar", "empieza", "empezar", "comienza", "comenzar", "arranca", "arrancar",
                                  "lanza", "pon", "ponme", "pone", "poner", "activa", "activar", "crea", "crear", "start",
                                  "begin", "launch", "set", "run", "dame"]
        let filler: Set<String> = ["un", "una", "uno", "a", "an", "the", "el", "mi", "my", "nuevo", "nueva", "new", "sesion",
                                   "sesiones", "session", "sessions", "de", "of", "with", "con", "y", "and", "for", "ahora",
                                   "now", "timer", "temporizador", "pomodoro", "me", "otro", "another", "quiero", "necesito",
                                   "want", "need", "i", "to"]
        let breakWords: Set<String> = ["descanso", "descansos", "pausa", "break", "breaks", "rest"]
        let cycleWords: Set<String> = ["ciclos", "ciclo", "cycles", "cycle", "rondas", "ronda", "rounds", "round", "pomodoros", "pomodoro"]
        var work: Int?, sb: Int?, lb: Int?, cycles: Int?
        var kind: Int?                                   // 0 = short break, 1 = long break
        var hasVerb = false, hasConfig = false
        var i = 0
        while i < n.count {
            let w = n[i]
            if verbs.contains(w) { hasVerb = true; i += 1; continue }
            if breakWords.contains(w) { if kind == nil { kind = 0 }; i += 1; continue }
            if w == "largo" || w == "long" { kind = 1; i += 1; continue }
            if w == "corto" || w == "short" { kind = 0; i += 1; continue }
            if w.contains("/") {                         // "50/10" or "25/5/15"
                let parts = w.split(separator: "/").map { Int($0) }
                guard parts.count >= 2, parts.count <= 3, !parts.contains(where: { $0 == nil }),
                      work == nil, sb == nil, lb == nil else { return nil }
                work = parts[0]; sb = parts[1]; if parts.count == 3 { lb = parts[2] }
                hasConfig = true; i += 1; continue
            }
            if filler.contains(w) { i += 1; continue }       // before numbers: "un/una" are articles here
            if let num = numberAt(n, i, article: false), num.v > 0, num.v == num.v.rounded() {
                var val = Int(num.v)
                var j = num.next
                var isCycles = false
                if j < n.count {
                    if let u = unitSecs(n[j]) {
                        guard u >= 60 else { return nil }
                        if u == 3600 { val *= 60 }
                        j += 1
                    } else if cycleWords.contains(n[j]) { isCycles = true; j += 1 }
                }
                if !isCycles, j + 1 < n.count, n[j] == "de" || n[j] == "of", breakWords.contains(n[j + 1]) {
                    kind = 0; j += 2
                    if j < n.count, n[j] == "largo" || n[j] == "long" { kind = 1; j += 1 }
                    else if j < n.count, n[j] == "corto" || n[j] == "short" { j += 1 }
                }
                if isCycles {
                    guard cycles == nil else { return nil }
                    cycles = val
                } else if let k = kind {
                    if k == 0 { guard sb == nil else { return nil }; sb = val } else { guard lb == nil else { return nil }; lb = val }
                    kind = nil
                } else {
                    guard work == nil else { return nil }
                    work = val
                }
                hasConfig = true; i = j; continue
            }
            return nil
        }
        guard hasVerb || hasConfig else { return nil }
        if let w = work, !(1...180).contains(w) { return nil }
        if let b = sb, !(1...90).contains(b) { return nil }
        if let b = lb, !(1...120).contains(b) { return nil }
        if let c = cycles, !(1...20).contains(c) { return nil }
        return .pomodoro(work: work, shortBreak: sb, longBreak: lb, cycles: cycles)
    }

    // MARK: - Cancel

    private static func isCancel(_ n: [String]) -> Bool {
        let verbs: Set<String> = ["cancela", "cancelar", "para", "parar", "deten", "detener", "stop", "cancel", "apaga", "apagar",
                                  "quita", "elimina", "borra", "termina", "finaliza", "aborta", "abort", "end", "kill"]
        let nouns: Set<String> = ["temporizador", "temporizadores", "timer", "timers", "pomodoro", "pomodoros", "countdown"]
        let filler: Set<String> = ["el", "la", "los", "las", "mi", "mis", "my", "the", "all", "todos", "todas", "actual", "current",
                                   "running", "activo", "activa", "active", "ahora", "now", "en", "curso", "de", "del", "cuenta",
                                   "regresiva", "atras", "count", "down"]
        guard let f = n.first, verbs.contains(f), n.count >= 2 else { return false }
        let rest = Array(n.dropFirst())
        let hasNoun = rest.contains(where: { nouns.contains($0) }) || (rest.contains("cuenta") && (rest.contains("regresiva") || rest.contains("atras")))
        return hasNoun && rest.allSatisfy { nouns.contains($0) || filler.contains($0) }
    }

    // MARK: - Tasks

    private static func isTasks(_ n: [String]) -> Bool {
        let anchors: Set<String> = ["tareas", "tarea", "pendientes", "pendiente", "recordatorios", "tasks", "reminders", "pending", "todo"]
        let vocab: Set<String> = anchors.union([
            "mis", "mi", "mostrar", "muestrame", "muestra", "ver", "dime", "dame", "ensename", "revisa", "consulta", "que", "tengo",
            "hay", "cuales", "son", "lista", "de", "las", "los", "todas", "por", "hacer", "show", "me", "my", "what", "whats", "are",
            "is", "there", "list", "of", "view", "see", "tell", "give", "check", "all", "the", "do", "i", "have", "upcoming", "open", "to",
        ])
        return n.contains(where: { anchors.contains($0) }) && n.allSatisfy { vocab.contains($0) }
    }

    // MARK: - Days

    private enum DayRef {
        case today, tomorrow, dayAfter
        case weekday(Int, next: Bool)       // Calendar weekday number: 1 = Sunday … 7 = Saturday
        case thisWeek, nextWeek
        case inDays(Int)
        case monthDay(Int)
    }

    private static let weekdays: [String: Int] = [
        "domingo": 1, "lunes": 2, "martes": 3, "miercoles": 4, "jueves": 5, "viernes": 6, "sabado": 7,
        "sunday": 1, "monday": 2, "tuesday": 3, "wednesday": 4, "thursday": 5, "friday": 6, "saturday": 7,
    ]

    private static func dayExpr(_ n: [String], _ i: Int, monthDay: Bool) -> (day: DayRef, count: Int)? {
        let w = n[i]
        func at(_ k: Int) -> String { i + k < n.count ? n[i + k] : "" }
        switch w {
        case "hoy", "today": return (.today, 1)
        case "tomorrow": return (.tomorrow, 1)
        case "manana":
            if i > 0, n[i - 1] == "la" { return nil }                  // "por la mañana" is a period, not a day
            return (.tomorrow, 1)
        case "pasado": if at(1) == "manana" { return (.dayAfter, 2) }
        case "day": if at(1) == "after", at(2) == "tomorrow" { return (.dayAfter, 3) }
        case "esta", "this": if at(1) == "semana" || at(1) == "week" { return (.thisWeek, 2) }
        case "proxima", "next": if at(1) == "semana" || at(1) == "week" { return (.nextWeek, 2) }
        case "la": if at(1) == "proxima", at(2) == "semana" { return (.nextWeek, 3) }
        default: break
        }
        // weekday with optional "el / on / este / this / próximo / next"
        var j = i
        var nxt = false
        while j < n.count, ["el", "on", "este", "this", "proximo", "next"].contains(n[j]) {
            if n[j] == "proximo" || n[j] == "next" { nxt = true }
            j += 1
        }
        if j < n.count, let wd = weekdays[n[j]] { return (.weekday(wd, next: nxt), j - i + 1) }
        // "en 3 días", "in 2 weeks"
        if w == "en" || w == "in", let num = numberAt(n, i + 1, article: false), num.v == num.v.rounded(), num.next < n.count {
            switch n[num.next] {
            case "dia", "dias", "day", "days": return (.inDays(Int(num.v)), num.next - i + 1)
            case "semana", "semanas", "week", "weeks": return (.inDays(Int(num.v) * 7), num.next - i + 1)
            default: break
            }
        }
        if monthDay {
            // "el 15"
            if w == "el", isDigits(at(1)), let d = Int(at(1)), (1...31).contains(d) {
                let nx = at(2)
                if nx == "" || (unitSecs(nx) == nil && nx != "am" && nx != "pm" && nx != "de") { return (.monthDay(d), 2) }
            }
            // "on the 15th", "the 15th", "15th"
            var k = i
            if n[k] == "on" { k += 1 }
            if k < n.count, n[k] == "the" { k += 1 }
            if k + 1 < n.count, isDigits(n[k]), let d = Int(n[k]), (1...31).contains(d), ["th", "st", "nd", "rd"].contains(n[k + 1]) {
                return (.monthDay(d), k + 2 - i)
            }
        }
        return nil
    }

    private static func weekdayOffset(_ target: Int, next: Bool, now: Date, cal: Calendar) -> Int {
        let today = cal.component(.weekday, from: now)
        var diff = (target - today + 7) % 7
        if next && diff == 0 { diff = 7 }
        return diff
    }

    private static func startOfNextWeek(now: Date, cal: Calendar) -> Date {
        let sod = cal.startOfDay(for: now)
        let sinceMonday = (cal.component(.weekday, from: now) + 5) % 7     // week starts on Monday
        return cal.date(byAdding: .day, value: 7 - sinceMonday, to: sod) ?? sod
    }

    // MARK: - Agenda

    private static func parseAgenda(_ n: [String], now: Date, cal: Calendar) -> AgentIntent? {
        var rest: [String] = []
        var day: DayRef?
        var i = 0
        while i < n.count {
            if let d = dayExpr(n, i, monthDay: false) {
                guard day == nil else { return nil }
                day = d.day; i += d.count
            } else { rest.append(n[i]); i += 1 }
        }
        let vocab: Set<String> = [
            "que", "tengo", "tenemos", "hay", "mi", "mis", "el", "la", "los", "las", "de", "del", "para", "en", "muestrame", "muestra",
            "mostrar", "ver", "dime", "dame", "ensename", "revisa", "consulta", "cual", "cuales", "es", "son", "algo", "agenda",
            "calendario", "reuniones", "citas", "eventos", "compromisos", "actividades", "planes", "programado",
            "what", "whats", "do", "i", "have", "got", "on", "my", "the", "for", "show", "me", "view", "see", "tell", "give", "check",
            "calendar", "schedule", "meetings", "appointments", "events", "is", "there", "any", "in", "planned", "scheduled", "upcoming",
        ]
        let anchors: Set<String> = ["agenda", "calendario", "calendar", "schedule", "reuniones", "citas", "meetings", "appointments",
                                    "events", "eventos", "compromisos", "actividades", "planes"]
        guard !rest.isEmpty, rest.allSatisfy({ vocab.contains($0) }) else { return nil }
        let hasAnchor = rest.contains(where: { anchors.contains($0) })
            || (rest.contains("que") && rest.contains("tengo"))
            || ((rest.contains("what") || rest.contains("whats")) && (rest.contains("have") || rest.contains("on") || rest.contains("got")))
        guard hasAnchor else { return nil }

        let es = Set(["que", "tengo", "tenemos", "hay", "mi", "mis", "hoy", "manana", "pasado", "semana", "muestrame", "muestra", "mostrar",
                      "ver", "dime", "dame", "calendario", "reuniones", "citas", "eventos", "compromisos", "el", "la", "los", "las", "del",
                      "cuales", "proximo", "proxima", "esta", "lunes", "martes", "miercoles", "jueves", "viernes", "sabado", "domingo"])
        let en = Set(["what", "whats", "show", "my", "do", "i", "have", "got", "on", "calendar", "schedule", "today", "tomorrow", "this",
                      "next", "for", "view", "see", "tell", "give", "me", "meetings", "appointments", "events", "the", "is", "there", "any",
                      "week", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday", "day", "after"])
        let english = n.filter { en.contains($0) }.count > n.filter { es.contains($0) }.count

        let sod = cal.startOfDay(for: now)
        func shift(_ k: Int) -> Date { cal.date(byAdding: .day, value: k, to: sod) ?? sod }
        func full(_ k: Int, _ title: String) -> AgentIntent { .agenda(from: shift(k), to: shift(k + 1), title: title) }
        let namesES = ["domingo", "lunes", "martes", "miércoles", "jueves", "viernes", "sábado"]
        let namesEN = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
        switch day ?? .today {
        case .today: return full(0, english ? "today" : "hoy")
        case .tomorrow: return full(1, english ? "tomorrow" : "mañana")
        case .dayAfter: return full(2, english ? "the day after tomorrow" : "pasado mañana")
        case .weekday(let wd, let nxt):
            let off = weekdayOffset(wd, next: nxt, now: now, cal: cal)
            let name = english ? namesEN[wd - 1] : namesES[wd - 1]
            return full(off, english ? (nxt ? "next \(name)" : name) : (nxt ? "el próximo \(name)" : "el \(name)"))
        case .thisWeek:
            return .agenda(from: now, to: startOfNextWeek(now: now, cal: cal), title: english ? "this week" : "esta semana")
        case .nextWeek:
            let s = startOfNextWeek(now: now, cal: cal)
            return .agenda(from: s, to: cal.date(byAdding: .day, value: 7, to: s) ?? s, title: english ? "next week" : "la próxima semana")
        case .inDays(let k):
            return full(k, english ? "in \(k) days" : "en \(k) días")
        case .monthDay: return nil
        }
    }

    // MARK: - Reminder

    private enum Period { case am, pm, morning, afternoon, evening, night, dawn }
    private struct Clock { var h: Int; var m: Int; var period: Period? }

    private static let reminderPre: Set<String> = [
        "pon", "ponme", "pone", "poneme", "crea", "creame", "anade", "agrega", "agregame", "programa", "programame", "set", "add",
        "create", "make", "un", "una", "a", "me", "nuevo", "nueva", "new", "quiero", "necesito", "dame", "i", "want", "need", "would",
        "like", "to", "hazme", "haz", "give",
    ]

    private static func findTrigger(_ n: [String]) -> (after: Int, es: Bool)? {
        for i in 0..<min(n.count, 7) {
            let w = n[i]
            let isTrigger = ["recuerdame", "recordame", "recordatorio", "reminder"].contains(w) || (w == "remind" && i + 1 < n.count && n[i + 1] == "me")
            if isTrigger {
                guard n[0..<i].allSatisfy({ reminderPre.contains($0) }) else { return nil }
                let es = w != "reminder" && w != "remind"
                return (i + (w == "remind" ? 2 : 1), es)
            }
        }
        return nil
    }

    private static func periodHint(_ n: [String], _ i: Int) -> (Period, Int)? {
        func at(_ k: Int) -> String { i + k < n.count ? n[i + k] : "" }
        if n[i] == "tonight" { return (.night, 1) }
        if n[i] == "esta" {
            switch at(1) {
            case "noche": return (.night, 2)
            case "tarde": return (.afternoon, 2)
            case "manana": return (.morning, 2)
            default: return nil
            }
        }
        if n[i] == "this" {
            switch at(1) {
            case "evening": return (.evening, 2)
            case "afternoon": return (.afternoon, 2)
            case "morning": return (.morning, 2)
            default: return nil
            }
        }
        return nil
    }

    private static func clockAt(_ n: [String], _ i: Int) -> (clock: Clock, end: Int)? {
        var j = i
        var prep = false
        if n[j] == "at" { j += 1; prep = true }
        else if n[j] == "a" || n[j] == "para", j + 1 < n.count, n[j + 1] == "las" || n[j + 1] == "la" { j += 2; prep = true }
        else if n[j] == "al", j + 1 < n.count, n[j + 1] == "mediodia" || n[j + 1] == "medianoche" { j += 1; prep = true }
        guard j < n.count else { return nil }
        if n[j] == "mediodia" || n[j] == "noon" { return (Clock(h: 12, m: 0, period: .pm), j + 1) }
        if n[j] == "medianoche" || n[j] == "midnight" { return (Clock(h: 0, m: 0, period: nil), j + 1) }

        var h: Int, m = 0, hasColon = false, k: Int
        let tok = n[j]
        if tok.contains(":") {
            let p = tok.split(separator: ":").map { Int($0) }
            guard p.count == 2, let hh = p[0], let mm = p[1], mm < 60 else { return nil }
            h = hh; m = mm; hasColon = true; k = j + 1
        } else if isDigits(tok), let v = Int(tok) {
            h = v; k = j + 1
        } else if prep, let num = numberAt(n, j, article: false), num.v == num.v.rounded(), (1...12).contains(Int(num.v)) {
            h = Int(num.v); k = num.next
        } else { return nil }
        guard h <= 23 else { return nil }

        var period: Period?
        if !hasColon {
            if k + 1 < n.count, n[k] == "y", n[k + 1] == "media" { m = 30; k += 2 }
            else if k + 1 < n.count, n[k] == "y", n[k + 1] == "cuarto" { m = 15; k += 2 }
            else if k + 1 < n.count, n[k] == "menos", n[k + 1] == "cuarto" { m = 45; h = h == 0 ? 23 : h - 1; k += 2 }
        }
        if k < n.count, n[k] == "am" || n[k] == "pm" {
            period = n[k] == "am" ? .am : .pm; k += 1
        } else if k + 2 < n.count, ["de", "por", "en"].contains(n[k]), n[k + 1] == "la" {
            switch n[k + 2] {
            case "manana": period = .morning; k += 3
            case "tarde": period = .afternoon; k += 3
            case "noche": period = .night; k += 3
            case "madrugada": period = .dawn; k += 3
            default: break
            }
        } else if k + 2 < n.count, n[k] == "in", n[k + 1] == "the" {
            switch n[k + 2] {
            case "morning": period = .morning; k += 3
            case "afternoon": period = .afternoon; k += 3
            case "evening": period = .evening; k += 3
            default: break
            }
        } else if k + 1 < n.count, n[k] == "at", n[k + 1] == "night" { period = .night; k += 2 }
        if !prep && !hasColon && period == nil { return nil }               // bare number is not a time
        if period == .am || period == .pm, !(1...12).contains(h) { return nil }
        return (Clock(h: h, m: m, period: period), k)
    }

    /// 24-hour value when unambiguous; nil for hours 7–11 without any indication.
    private static func resolveHour(_ c: Clock) -> Int? {
        let h = c.h
        if h >= 13 || h == 0 { return h }
        switch c.period {
        case .am?, .morning?, .dawn?: return h == 12 ? 0 : h
        case .pm?, .afternoon?, .evening?: return h == 12 ? 12 : h + 12
        case .night?: return h == 12 ? 0 : (h >= 6 ? h + 12 : h)          // "9 de la noche" = 21, "2 de la noche" = 2
        case nil: break
        }
        if h == 12 { return 12 }
        if h <= 6 { return h + 12 }          // 1–6 without am/pm: afternoon/evening
        return nil                            // 7–11: decided against `now`
    }

    private static func parseReminder(_ t: [Tok], now: Date, cal: Calendar) -> AgentIntent? {
        let n = t.map { $0.n }
        guard let trig = findTrigger(n) else { return nil }
        var removed = Set<Int>(0..<trig.after)
        var i = trig.after
        while i < n.count, ["que", "de", "para", "to", "about", "sobre", "that", "of", "for"].contains(n[i]) { removed.insert(i); i += 1 }

        var dur: Double?
        var day: DayRef?
        var clock: Clock?
        var hint: Period?
        while i < n.count {
            var consumed = 0
            if n[i] == "en" || n[i] == "in" || (n[i] == "dentro" && i + 1 < n.count && n[i + 1] == "de") {
                let from = n[i] == "dentro" ? i + 2 : i + 1
                if let d = durationAt(n, from) {
                    guard dur == nil else { return nil }
                    dur = d.secs; consumed = d.end - i
                }
            }
            if consumed == 0, let p = periodHint(n, i) {
                guard day == nil, hint == nil else { return nil }
                day = .today; hint = p.0; consumed = p.1
            }
            if consumed == 0, let d = dayExpr(n, i, monthDay: true) {
                switch d.day { case .thisWeek, .nextWeek: return nil; default: break }
                guard day == nil else { return nil }
                day = d.day; consumed = d.count
            }
            if consumed == 0, let c = clockAt(n, i) {
                guard clock == nil else { return nil }
                clock = c.clock; consumed = c.end - i
            }
            if consumed == 0 { i += 1; continue }
            for k in i..<(i + consumed) { removed.insert(k) }
            i += consumed
        }

        // Absolute date
        let sod = cal.startOfDay(for: now)
        func shift(_ k: Int) -> Date { cal.date(byAdding: .day, value: k, to: sod) ?? sod }
        func at(_ base: Date, _ h: Int, _ m: Int) -> Date { cal.date(bySettingHour: h, minute: m, second: 0, of: base) ?? base }
        var when: Date

        if let d = dur {
            guard day == nil, clock == nil, d >= 1, d <= 366 * 86400 else { return nil }
            when = now.addingTimeInterval(d.rounded())
        } else if var c = clock {
            if c.period == nil { c.period = hint }
            let known = resolveHour(c)
            switch day {
            case nil, .today?:
                let explicitToday: Bool = { if case .today? = day { return true } else { return false } }()
                let candidates: [Int] = known.map { [$0] } ?? [c.h, c.h + 12]
                guard let hit = candidates.map({ at(sod, $0, c.m) }).first(where: { $0 > now }) else {
                    if explicitToday { return nil }                          // asked for today but it already passed
                    when = at(shift(1), candidates[0], c.m)                  // no day given and it passed: tomorrow
                    break
                }
                when = hit
            case .tomorrow?: when = at(shift(1), known ?? c.h, c.m)
            case .dayAfter?: when = at(shift(2), known ?? c.h, c.m)
            case .inDays(let k)?: when = at(shift(k), known ?? c.h, c.m)
            case .weekday(let wd, let nxt)?:
                let off = weekdayOffset(wd, next: nxt, now: now, cal: cal)
                when = at(shift(off), known ?? c.h, c.m)
                if when <= now { when = at(shift(off + 7), known ?? c.h, c.m) }
            case .monthDay(let dd)?:
                var comps = cal.dateComponents([.year, .month], from: now)
                comps.day = dd
                func make(_ comps: DateComponents) -> Date? {
                    guard let d = cal.date(from: comps), cal.component(.day, from: d) == dd else { return nil }
                    return at(cal.startOfDay(for: d), known ?? c.h, c.m)
                }
                var cand = make(comps)
                if cand == nil || cand! <= now {
                    comps.month = (comps.month ?? 1) + 1
                    cand = make(comps)
                }
                guard let w = cand else { return nil }
                when = w
            case .thisWeek?, .nextWeek?: return nil
            }
        } else if case .inDays(let k)? = day {
            when = now.addingTimeInterval(Double(k) * 86400)
        } else {
            return nil                                                       // no time and no duration: let the model handle it
        }

        // Message
        var msg = t.enumerated().filter { !removed.contains($0.offset) }.map { $0.element }
        let lead: Set<String> = ["que", "de", "para", "to", "about", "sobre", "that", "of", "for", "y", "and"]
        let trail: Set<String> = ["a", "el", "la", "las", "los", "en", "in", "at", "on", "para", "for", "to", "y", "and", "de", "the", "por", "este", "this", "next", "proximo"]
        while let f = msg.first, lead.contains(f.n) { msg.removeFirst() }
        while let l = msg.last, trail.contains(l.n) { msg.removeLast() }
        var text = joinOrig(msg)
        if text.isEmpty { text = trig.es ? "Recordatorio" : "Reminder" }
        return .reminder(message: text, at: when)
    }
}
