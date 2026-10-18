import Foundation

var failed = 0
func check(_ name: String, _ ok: Bool) {
    print(ok ? "  ✓ \(name)" : "  ✗ \(name)")
    if !ok { failed += 1 }
}

// Fixed clock: Wednesday 2026-10-07 10:00 in Bogota (UTC-5), week starting on Monday.
var cal = Calendar(identifier: .gregorian)
cal.timeZone = TimeZone(identifier: "America/Bogota")!
cal.firstWeekday = 2
cal.locale = Locale(identifier: "en_US_POSIX")
func D(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0) -> Date {
    cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
}
let now = D(2026, 10, 7, 10, 0)
func P(_ s: String) -> AgentIntent? { AgentIntentParser.parse(s, now: now, calendar: cal) }
func isNil(_ s: String) -> Bool { P(s) == nil }
func timer(_ s: String, _ secs: Int, _ label: String = "") {
    check("timer: \(s)", P(s) == .timer(seconds: secs, label: label))
}
func rem(_ s: String, _ msg: String, _ at: Date) {
    check("reminder: \(s)", P(s) == .reminder(message: msg, at: at))
}
func agenda(_ s: String, _ from: Date, _ to: Date, _ title: String) {
    check("agenda: \(s)", P(s) == .agenda(from: from, to: to, title: title))
}

// --- Timers
timer("temporizador de 10 minutos", 600)
timer("pon un temporizador de 90 segundos", 90)
timer("cuenta regresiva de 5 minutos", 300)
timer("cuenta atrás 2 min", 120)
timer("ponme un timer de 1 hora y media", 5400)
timer("avísame en 15 minutos", 900)
timer("timer 25 min para estudiar", 1500, "estudiar")
timer("set a 10 minute timer", 600)
timer("countdown 30 seconds", 30)
timer("timer for 1 hour 15 minutes", 4500)
timer("Oye Mochi, pon un temporizador de media hora por favor", 1800)
timer("TEMPORIZADOR DE UN CUARTO DE HORA", 900)
timer("temporizador de 1h30", 5400)
timer("please set a timer for two hours", 7200)
timer("pon un temporizador de veinte minutos", 1200)
timer("temporizador de treinta y cinco minutos", 2100)
timer("timer for half an hour", 1800)
timer("temporizador de 1 hora 15 minutos", 4500)
timer("avisame en 10 minutos para sacar la pasta", 600, "sacar la pasta")
timer("temporizador de 1 minuto y medio", 90)
check("timer limit 24 h ok", P("temporizador de 24 horas") == .timer(seconds: 86400, label: ""))
check("timer over 24 h → nil", isNil("temporizador de 25 horas"))
check("timer 0 s → nil", isNil("temporizador de 0 segundos"))
check("timer without duration → nil", isNil("pon un temporizador"))

// --- Pomodoro
check("pomodoro: inicia un pomodoro", P("inicia un pomodoro") == .pomodoro(work: nil, shortBreak: nil, longBreak: nil, cycles: nil))
check("pomodoro de 25 minutos", P("pomodoro de 25 minutos") == .pomodoro(work: 25, shortBreak: nil, longBreak: nil, cycles: nil))
check("pomodoro 50/10", P("empieza una sesión pomodoro 50/10") == .pomodoro(work: 50, shortBreak: 10, longBreak: nil, cycles: nil))
check("start a pomodoro", P("start a pomodoro") == .pomodoro(work: nil, shortBreak: nil, longBreak: nil, cycles: nil))
check("pomodoro 4 ciclos", P("pomodoro 4 ciclos") == .pomodoro(work: nil, shortBreak: nil, longBreak: nil, cycles: 4))
check("pomodoro 30 con descanso de 5", P("pomodoro de 30 con descanso de 5") == .pomodoro(work: 30, shortBreak: 5, longBreak: nil, cycles: nil))
check("pomodoro 25/5/15", P("pomodoro 25/5/15") == .pomodoro(work: 25, shortBreak: 5, longBreak: 15, cycles: nil))
check("pomodoro long break", P("start a pomodoro of 25 with long break of 20") == .pomodoro(work: 25, shortBreak: nil, longBreak: 20, cycles: nil))

// --- Cancel
for s in ["cancela el temporizador", "para el pomodoro", "detén la cuenta regresiva", "stop the timer", "cancel pomodoro"] {
    check("cancel: \(s)", P(s) == .cancelTimer)
}

// --- Reminders
rem("recuérdame llamar a Juan en 20 minutos", "llamar a Juan", now.addingTimeInterval(1200))
rem("recuérdame mañana a las 9 enviar el informe", "enviar el informe", D(2026, 10, 8, 9, 0))
rem("ponme un recordatorio para beber agua a las 5 pm", "beber agua", D(2026, 10, 7, 17, 0))
rem("recordatorio: comprar leche el viernes a las 18:30", "comprar leche", D(2026, 10, 9, 18, 30))
rem("remind me to call mom at 5pm", "call mom", D(2026, 10, 7, 17, 0))
rem("remind me in 2 hours to check the oven", "check the oven", now.addingTimeInterval(7200))
rem("remind me tomorrow at 9am about the meeting", "the meeting", D(2026, 10, 8, 9, 0))
rem("recuérdame a las 8 de la mañana tomar la pastilla", "tomar la pastilla", D(2026, 10, 8, 8, 0))   // 8 am already passed → tomorrow
rem("recuérdame a las 7 de la noche cenar", "cenar", D(2026, 10, 7, 19, 0))
rem("recuérdame a las 11 llamar al banco", "llamar al banco", D(2026, 10, 7, 11, 0))                // 7–11 still ahead today → am
rem("recuérdame a las 9 llamar al banco", "llamar al banco", D(2026, 10, 7, 21, 0))                 // 9 am passed, 9 pm ahead
rem("recuérdame a las 3 revisar el correo", "revisar el correo", D(2026, 10, 7, 15, 0))            // 1–6 → pm
rem("recuérdame al mediodía comer", "comer", D(2026, 10, 7, 12, 0))
rem("remind me at midnight to sleep", "sleep", D(2026, 10, 8, 0, 0))
rem("remind me at 5:15pm to stretch", "stretch", D(2026, 10, 7, 17, 15))
rem("recuérdame hoy a las 15:00 la reunión", "la reunión", D(2026, 10, 7, 15, 0))
rem("recuérdame pasado mañana a las 10 pagar la luz", "pagar la luz", D(2026, 10, 9, 10, 0))
rem("recuérdame el miércoles a las 8 am sacar la basura", "sacar la basura", D(2026, 10, 14, 8, 0))   // today's 8 am passed → next week
rem("recuérdame en 3 días a las 9 pagar", "pagar", D(2026, 10, 10, 9, 0))
rem("remind me on the 15th at 9am to pay rent", "pay rent", D(2026, 10, 15, 9, 0))
rem("recuérdame el 3 a las 9 am pagar", "pagar", D(2026, 11, 3, 9, 0))
rem("recuérdame a las 5 y media cerrar caja", "cerrar caja", D(2026, 10, 7, 17, 30))
rem("recordatorio a las 6 pm", "Recordatorio", D(2026, 10, 7, 18, 0))
rem("remind me at 6pm", "Reminder", D(2026, 10, 7, 18, 0))
check("reminder without time → nil", isNil("recuérdame llamar a Juan"))
check("reminder for today but past → nil", isNil("recuérdame hoy a las 8 am llamar"))
check("reminder day only → nil", isNil("recuérdame mañana llamar a Juan"))

// --- Agenda
agenda("qué tengo hoy", D(2026, 10, 7), D(2026, 10, 8), "hoy")
agenda("mi agenda de mañana", D(2026, 10, 8), D(2026, 10, 9), "mañana")
agenda("qué tengo el miércoles", D(2026, 10, 7), D(2026, 10, 8), "el miércoles")
agenda("mi agenda", D(2026, 10, 7), D(2026, 10, 8), "hoy")
agenda("qué reuniones tengo esta semana", now, D(2026, 10, 12), "esta semana")
agenda("muéstrame mi calendario", D(2026, 10, 7), D(2026, 10, 8), "hoy")
agenda("what's on my calendar today", D(2026, 10, 7), D(2026, 10, 8), "today")
agenda("what do I have tomorrow", D(2026, 10, 8), D(2026, 10, 9), "tomorrow")
agenda("show my agenda", D(2026, 10, 7), D(2026, 10, 8), "today")
agenda("my schedule for Friday", D(2026, 10, 9), D(2026, 10, 10), "Friday")
agenda("qué tengo pasado mañana", D(2026, 10, 9), D(2026, 10, 10), "pasado mañana")
agenda("qué tengo el próximo lunes", D(2026, 10, 12), D(2026, 10, 13), "el próximo lunes")
agenda("what do I have this week", now, D(2026, 10, 12), "this week")
agenda("what do I have on the day after tomorrow", D(2026, 10, 9), D(2026, 10, 10), "the day after tomorrow")
agenda("qué tengo el martes", D(2026, 10, 13), D(2026, 10, 14), "el martes")

// --- Tasks
for s in ["mis tareas", "mis recordatorios", "qué tengo pendiente", "muéstrame mis pendientes", "show my tasks", "my reminders", "what's pending"] {
    check("tasks: \(s)", P(s) == .tasks)
}

// --- Must NOT fire
let negatives = [
    "explícame qué es un pomodoro", "qué es una cuenta regresiva", "cuánto dura un pomodoro", "cómo funciona un temporizador",
    "the timer example in my code", "escribe una función de temporizador en Swift", "resume mi agenda de ayer",
    "agéndame una reunión con Juan mañana a las 3", "envía un correo a Ana con el informe", "mándale un whatsapp a mamá",
    "hola", "what is a pomodoro", "explain the pomodoro technique", "why does my timer drift",
    "temporizador", "pomodoro", "remind me to call mom", "qué tengo que hacer para aprobar el examen",
    "cancela mi suscripción", "stop talking",
]
for s in negatives { check("nil: \(s)", isNil(s)) }
check("nil: long text", isNil("pon un temporizador de 10 minutos " + String(repeating: "y además cuéntame algo muy largo ", count: 8)))
check("nil: multi-line with code", isNil("pon un temporizador de 10 minutos\nfunc timer() {\n  print(1)\n}"))
check("nil: empty", isNil("   "))

if failed > 0 { print("\(failed) FAILED"); exit(1) }
print("All tests passed.")
