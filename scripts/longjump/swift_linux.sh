#!/usr/bin/env bash
# Build / test LongJumpKit on Linux in the official Swift Docker image -- no Mac needed.
# Package.swift exposes only LongJumpKit (+ its tests) on Linux.
#
#   scripts/longjump/swift_linux.sh test                         # swift test (debug)
#   scripts/longjump/swift_linux.sh test --filter NumericsTests
#   scripts/longjump/swift_linux.sh test -c release -Xswiftc -enable-testing   # image tests: faster
#   scripts/longjump/swift_linux.sh build
#
# SWIFT_IMAGE (default swift:5.10-noble, the oldest Swift the Mac's Xcode 15 may use) and
# SWIFT_BUILD_PATH (default .build-linux) override the defaults.  The real-case parity tests read
# testdata/longjump/ (scripts/longjump/dump_longjump_fixtures.py) and skip when it is missing.
set -euo pipefail
IMAGE=${SWIFT_IMAGE:-swift:5.10-noble}
REPO=$(cd "$(dirname "$0")/../.." && pwd)
BUILD=${SWIFT_BUILD_PATH:-.build-linux}
COMMAND=${1:-test}
shift || true
# LONGJUMP_FIXTURES=/path/to/testdata/longjump: use those fixtures (e.g. from a git worktree,
# which has no testdata of its own); mounted read-only.
FIXTURES=()
if [[ -n "${LONGJUMP_FIXTURES:-}" ]]; then
    FIXTURES=(-v "$LONGJUMP_FIXTURES":/fixtures:ro -e LONGJUMP_FIXTURES=/fixtures)
fi
exec docker run --rm --user "$(id -u):$(id -g)" -e HOME=/tmp "${FIXTURES[@]}" \
    -v "$REPO":/repo -w /repo "$IMAGE" swift "$COMMAND" --build-path "$BUILD" "$@"
