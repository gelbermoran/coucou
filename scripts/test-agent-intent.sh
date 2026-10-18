#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-agent-intent.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
cp tests/AgentIntentTests.swift "$TEST_DIR/main.swift"
swiftc NotchBuddy/Sources/App/AgentIntent.swift "$TEST_DIR/main.swift" -o "$TEST_DIR/agent-intent-tests"
"$TEST_DIR/agent-intent-tests"
