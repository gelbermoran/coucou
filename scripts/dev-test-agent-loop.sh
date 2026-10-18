#!/usr/bin/env bash
# Dev check of the assistant's tool-calling loop against a fake MiniMax-style server.
# Needs a Debug build of the Mac app (cd NotchBuddy && xcodegen && xcodebuild -scheme NotchBuddy -configuration Debug build).
# It launches the app with debug-only flags (no Keychain, fake key), asks for a timer and a webhook call,
# and checks agent.log and the request the webhook received.
set -euo pipefail
cd "$(dirname "$0")/.."
APP=$(ls -dt ~/Library/Developer/Xcode/DerivedData/NotchBuddy-*/Build/Products/Debug/Coucou.app | head -1)
LOG=~/Library/Logs/NotchBuddy/agent.log
pkill -f fake_agent_llm.py || true; pkill -x Coucou || true; sleep 1
python3 tests/fake_agent_llm.py 8765 & FAKE=$!
trap 'kill $FAKE 2>/dev/null || true; pkill -x Coucou || true' EXIT
sleep 1; rm -f "$LOG" /tmp/coucou-hook.json
ACT='[{"id":"11111111-1111-1111-1111-111111111111","name":"send_ping","description":"Send a ping message to my webhook","variables":"message","method":"POST","url":"http://127.0.0.1:8765/hook","headers":"Content-Type: application/json","body":"{\"text\":\"{{message}}\",\"source\":\"coucou\"}","defaults":"","confirm":false}]'
KC=$(python3 -c "import json,sys,base64;print(base64.b64encode(json.dumps({'minimax-api-key':'fake','custom-actions':sys.argv[1]}).encode()).decode())" "$ACT")
open "$APP" --args -chatProvider minimax -minimaxBaseURL http://127.0.0.1:8765/v1 -debugKeychain "$KC" -debugCommand "haz un ping a mi webhook y pon un timer"
for _ in $(seq 1 30); do grep -qE "final answer|\[error\]" "$LOG" 2>/dev/null && break; sleep 1; done
cut -c1-220 "$LOG"
ok=1
grep -q "CALL start_timer" "$LOG" || { echo "FAIL: start_timer was not called"; ok=0; }
grep -q "CALL send_ping" "$LOG" || { echo "FAIL: send_ping was not called"; ok=0; }
grep -q "final answer" "$LOG" || { echo "FAIL: no final answer"; ok=0; }
python3 - <<'PY' || ok=0
import json,sys
b=json.load(open('/tmp/coucou-hook.json'))
if b.get('text')!='Hola "mundo"\nlinea 2' or b.get('source')!='coucou':
    print("FAIL: webhook body is wrong:", b); sys.exit(1)
print("webhook body ok:", b)
PY
[ $ok = 1 ] && echo "Agent loop OK" || { echo "Agent loop FAILED"; exit 1; }
