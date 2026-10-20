#!/usr/bin/env bash
# swift test for TmuxPadCore against the Docker bench (host/tests/bench.sh).
#
#   TmuxPadCore/scripts/test.sh [swift test args...]
#   TmuxPadCore/scripts/test.sh --filter HostAPIIntegrationTests
set -u

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
BENCH=$ROOT/host/tests/bench.sh

trap '"$BENCH" down' EXIT
env_lines=$("$BENCH" up) || { echo "bench did not come up" >&2; exit 1; }
eval "$env_lines"
swift test --package-path "$ROOT/TmuxPadCore" "$@"
