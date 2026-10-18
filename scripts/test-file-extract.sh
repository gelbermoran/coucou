#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-file-extract.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
cp tests/FileTextExtractorTests.swift "$TEST_DIR/main.swift"
swiftc NotchBuddy/Sources/App/FileTextExtractor.swift "$TEST_DIR/main.swift" \
    -o "$TEST_DIR/file-extract-tests"
"$TEST_DIR/file-extract-tests"
