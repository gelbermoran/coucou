#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-agent-pure.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
cp tests/AgentPureTests.swift "$TEST_DIR/main.swift"
swiftc NotchBuddy/Sources/App/AgentPure.swift "$TEST_DIR/main.swift" -o "$TEST_DIR/agent-pure-tests"
"$TEST_DIR/agent-pure-tests"
