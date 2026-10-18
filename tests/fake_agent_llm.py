#!/usr/bin/env python3
"""Fake OpenAI-compatible server (MiniMax style) for testing Coucou's tool loop.

POST /v1/chat/completions
  - first request  → answers with tool_calls (start_timer + a custom action) and <think> in content
  - after the tool results → final text
POST /hook → records the body Coucou sends to the custom action in /tmp/coucou-hook.json
Run: python3 tests/fake_agent_llm.py 8765
"""
import json, sys
from http.server import BaseHTTPRequestHandler, HTTPServer

class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def _send(self, obj, code=200):
        data = json.dumps(obj).encode()
        self.send_response(code); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data))); self.end_headers(); self.wfile.write(data)
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))) or b"{}")
        if self.path.endswith("/hook"):
            open("/tmp/coucou-hook.json", "w").write(json.dumps(body, ensure_ascii=False))
            return self._send({"ok": True})
        msgs = body.get("messages", [])
        open("/tmp/coucou-llm-request.json", "w").write(json.dumps(body, ensure_ascii=False))
        if any(m.get("role") == "tool" for m in msgs):
            results = [m["content"] for m in msgs if m.get("role") == "tool"]
            return self._send({"choices": [{"finish_reason": "stop", "message": {
                "role": "assistant", "content": "<think>listo</think>Hecho: " + " | ".join(results)}}]})
        calls = [
            {"id": "call_1", "type": "function", "function": {"name": "start_timer", "arguments": json.dumps({"seconds": 4, "label": "fake"})}},
            {"id": "call_2", "type": "function", "function": {"name": "send_ping", "arguments": json.dumps({"message": "Hola \"mundo\"\nlinea 2"})}},
        ]
        self._send({"choices": [{"finish_reason": "tool_calls", "message": {
            "role": "assistant", "content": "<think>necesito herramientas</think>", "tool_calls": calls}}]})

HTTPServer(("127.0.0.1", int(sys.argv[1]) if len(sys.argv) > 1 else 8765), H).serve_forever()
