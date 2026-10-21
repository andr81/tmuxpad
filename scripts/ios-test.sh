#!/usr/bin/env bash
# AppTests in an iPad simulator, against the Docker bench (host/tests/bench.sh).
#
#   scripts/ios-test.sh [--no-bench] [xcodebuild args...]
#   scripts/ios-test.sh -only-testing:AppTests/ServerStoreTests
#   TMUXPAD_SIM="iPad Air 11-inch (M3)" scripts/ios-test.sh --no-bench
#
# TMUXPAD_SIM is a simulator UDID or name; without it the first available iPad.
# Runs under the system bash 3.2 of macOS.
set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
BENCH=$ROOT/host/tests/bench.sh
RESULT=$ROOT/build/TestResults.xcresult

use_bench=1
only_ui=
args=()
for a in "$@"; do
	case $a in
	--no-bench) use_bench= ;;
	-only-testing:AppUITests | -only-testing:AppUITests/*)
		[[ -z $only_ui ]] && only_ui=1
		args+=("$a")
		;;
	-only-testing:*)
		only_ui=0
		args+=("$a")
		;;
	*) args+=("$a") ;;
	esac
done
[[ $only_ui == 1 ]] && use_bench=

# pick_sim: prints the UDID of TMUXPAD_SIM or of the first available iPad.
pick_sim() {
	local uuid_re='[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}'
	local want=${TMUXPAD_SIM:-} lines
	if [[ -n $want ]] && echo "$want" | grep -Eqx "$uuid_re"; then
		echo "$want"
		return 0
	fi
	lines=$(xcrun simctl list devices available | grep -E '^[[:space:]]+iPad')
	if [[ -n $want ]]; then
		lines=$(echo "$lines" | grep -F "    $want (")
	fi
	echo "$lines" | grep -Eo "\($uuid_re\)" | head -n 1 | tr -d '()'
}

cd "$ROOT" || exit 1
xcodegen generate --quiet || { echo "xcodegen failed" >&2; exit 1; }

udid=$(pick_sim)
if [[ -z $udid ]]; then
	echo "no iPad simulator found${TMUXPAD_SIM:+ for TMUXPAD_SIM=$TMUXPAD_SIM}" >&2
	exit 1
fi

if [[ -n $use_bench ]]; then
	trap '"$BENCH" down' EXIT
	env_lines=$("$BENCH" up) || { echo "bench did not come up" >&2; exit 1; }
	eval "$env_lines"
	# xcodebuild strips TEST_RUNNER_ and passes the rest to the test process.
	export TEST_RUNNER_TMUXPAD_BENCH_PORT=$TMUXPAD_BENCH_PORT
	export TEST_RUNNER_TMUXPAD_BENCH_USER=$TMUXPAD_BENCH_USER
	TEST_RUNNER_TMUXPAD_BENCH_KEY_B64=$(base64 <"$TMUXPAD_BENCH_KEY" | tr -d '\n')
	export TEST_RUNNER_TMUXPAD_BENCH_KEY_B64
fi

rm -rf "$RESULT"
# SwiftTerm's build plugin (git info, terminfo table) needs approval; in Xcode it is one click.
xcodebuild test -project TmuxPad.xcodeproj -scheme TmuxPad \
	-destination "platform=iOS Simulator,id=$udid" -skipPackagePluginValidation \
	-resultBundlePath "$RESULT" -quiet ${args[@]+"${args[@]}"}
