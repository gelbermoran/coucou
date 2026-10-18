import Foundation

var failed = 0
func check(_ name: String, _ ok: Bool) {
    print(ok ? "  ✓ \(name)" : "  ✗ \(name)")
    if !ok { failed += 1 }
}

// --- Dates the model sends
let cal = Calendar.current
let withOffset = AgentDate.parse("2026-10-05T15:00:00-05:00")
check("ISO with offset", withOffset != nil)
check("ISO with offset = 20:00 UTC", withOffset.map { $0.timeIntervalSince1970 } == 1791230400)
let local = AgentDate.parse("2026-10-05T15:00:00")
check("ISO without offset is local", local.map { cal.component(.hour, from: $0) } == 15)
check("date and time with space", AgentDate.parse("2026-10-05 09:30").map { cal.component(.minute, from: $0) } == 30)
check("date only", AgentDate.parse("2026-10-05") != nil)
check("fractional seconds", AgentDate.parse("2026-10-05T15:00:00.250Z") != nil)
check("garbage → nil", AgentDate.parse("mañana a las nueve") == nil)

// --- API template: the model's text must never break the JSON body
let template = #"{"messaging_product":"whatsapp","to":"{{to}}","type":"text","text":{"body":"{{message}}"}}"#
let nasty = "Hola \"mundo\"\nlinea 2 \\ y un emoji 🎉 }, \"admin\": true"
let vals = ["message": nasty, "to": "573001234567"]
let body = CustomAPITemplate.renderBody(template, values: vals)
let obj = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any]
check("body stays valid JSON with quotes/newlines/backslashes", obj != nil)
check("message round-trips exactly", ((obj?["text"] as? [String: Any])?["body"] as? String) == nasty)
check("no injected extra key", obj?["admin"] == nil && ((obj?["text"] as? [String: Any])?["admin"]) == nil)
check("recipient filled", obj?["to"] as? String == "573001234567")
check("URL values are percent-encoded",
      CustomAPITemplate.renderURL("https://api.example.com/v1/{{to}}/messages", values: ["to": "+57 300"]).contains("%20"))
check("header variable filled", CustomAPITemplate.renderHeaders("Authorization: Bearer {{token}}", values: ["token": "abc"]) == "Authorization: Bearer abc")

// --- Headers
let h = CustomAPITemplate.parseHeaders("Authorization: Bearer abc:def\nContent-Type: application/json\n\n  bad line\nX-Empty:")
check("headers parsed", h.count == 2 || h.count == 3)
check("value keeps its colon", h.first(where: { $0.0 == "Authorization" })?.1 == "Bearer abc:def")

// --- Variables and tool names
check("variables parsed", CustomAPITemplate.parseVariables("to, message ,  name") == ["to", "message", "name"])
check("variables drop invalid and duplicates", CustomAPITemplate.parseVariables("to, to, 9bad, ok_1, a b") == ["to", "ok_1"])
check("tool name sanitized", CustomAPITemplate.toolName("Enviar WhatsApp!") == "enviar_whatsapp")
check("empty tool name has a fallback", CustomAPITemplate.toolName("¡¡") == "custom_action")

// --- Tool calls written inside the text
let xml = "<think>pienso</think>Voy a leer.<minimax:tool_call><invoke name=\"start_timer\"><parameter name=\"minutes\">25</parameter><parameter name=\"label\">estudiar</parameter></invoke></minimax:tool_call>"
let xc = TextToolCalls.extract(from: xml)
check("xml tool call name", xc.first?.name == "start_timer")
check("xml numeric parameter", xc.first?.arguments["minutes"] as? Double == 25)
check("xml string parameter", xc.first?.arguments["label"] as? String == "estudiar")
let js = TextToolCalls.extract(from: "<tool_call>{\"name\":\"remind_me\",\"arguments\":{\"message\":\"agua\",\"in_minutes\":10}}</tool_call>")
check("json tool call", js.first?.name == "remind_me" && js.first?.arguments["in_minutes"] as? Int == 10)
check("plain text has no calls", TextToolCalls.extract(from: "Hola, ¿qué tal?").isEmpty)
check("markup stripped", TextToolCalls.stripMarkup(xml) == "Voy a leer.")

if failed > 0 { print("\(failed) FAILED"); exit(1) }
print("All tests passed.")
