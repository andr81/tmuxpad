#!/usr/bin/env bash
# Integration tests for tmuxpad-host.sh against sshd + tmux in Docker.
#
#   host/tests/run.sh [-k SUBSTR]
#   TMUXPAD_TEST_BASE=ubuntu:22.04 host/tests/run.sh
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
FILTER=
while (($#)); do
	case $1 in
	-k) FILTER=${2:?-k needs a substring}; shift 2 ;;
	*) echo "usage: ${0##*/} [-k SUBSTR]" >&2; exit 2 ;;
	esac
done

BASE=${TMUXPAD_TEST_BASE:-ubuntu:24.04}
IMAGE=tmuxpad-test:${BASE//[:\/]/-}

echo "building $IMAGE from $BASE"
docker build -q --build-arg BASE="$BASE" -t "$IMAGE" "$HERE/docker" >/dev/null || exit 1

TMP=$(mktemp -d)
CID=
cleanup() {
	[[ -f $TMP/bg.pids ]] && while read -r pid; do kill "$pid" 2>/dev/null; done <"$TMP/bg.pids"
	[[ -n $CID ]] && docker rm -f "$CID" >/dev/null 2>&1
	rm -rf "$TMP"
}
trap cleanup EXIT

ssh-keygen -q -t ed25519 -N '' -f "$TMP/key" || exit 1
KEY=$TMP/key
CID=$(docker run -d --rm -p 127.0.0.1::22 -e AUTHORIZED_KEY="$(cat "$TMP/key.pub")" "$IMAGE") || exit 1
PORT=$(docker port "$CID" 22 | head -n1)
PORT=${PORT##*:}
FAILED=$TMP/failed

# shellcheck source=host/tests/lib.sh
. "$HERE/lib.sh"

for ((i = 0; i < 60; i++)); do
	r true 2>/dev/null && break
	sleep 0.5
done
r true || { echo "sshd in $CID did not come up" >&2; exit 1; }
echo "container ${CID:0:12} on port $PORT, $(r 'tmux -V')"

# installed the way the app installs it (§7)
r 'mkdir -p ~/.local/bin && cat > ~/.local/bin/tmuxpad-host.sh && chmod +x ~/.local/bin/tmuxpad-host.sh' \
	<"$ROOT/host/tmuxpad-host.sh" || exit 1

for f in "$HERE"/cases/*.sh; do
	# shellcheck source=/dev/null
	. "$f"
done

passed=0 failed=0
# fd 3: ssh in reset and the tests must not eat the list
while read -r _ _ t <&3; do
	[[ $t == test_* && $t == *"$FILTER"* ]] || continue
	printf '%s ... ' "$t"
	: >"$FAILED"
	reset </dev/null >/dev/null 2>&1
	("$t") </dev/null
	code=$?
	if [[ $code == 0 && ! -s $FAILED ]]; then
		echo PASS
		((passed++))
	else
		echo FAIL
		[[ -s $FAILED ]] && cat "$FAILED"
		[[ $code != 0 && ! -s $FAILED ]] && echo "  FAIL: exit $code"
		((failed++))
	fi
done 3< <(declare -F)
kill_bg

echo "$passed passed, $failed failed"
((failed == 0))
