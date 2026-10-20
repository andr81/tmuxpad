#!/usr/bin/env bash
# A long-lived sshd + tmux container for the Swift tests of TmuxPadCore: the
# same image and key setup as run.sh, state in host/tests/.bench/.
#
#   eval "$(host/tests/bench.sh up)"   # prints export lines, logs to stderr
#   host/tests/bench.sh down
#   TMUXPAD_TEST_BASE=ubuntu:22.04 host/tests/bench.sh up
set -u

HERE=$(cd "$(dirname "$0")" && pwd -P)
STATE=$HERE/.bench
BASE=${TMUXPAD_TEST_BASE:-ubuntu:24.04}
IMAGE=tmuxpad-test:${BASE//[:\/]/-}

log() { echo "bench: $*" >&2; }

# with_timeout SECONDS CMD...: GNU timeout, else gtimeout (Homebrew
# coreutils on macOS), else no limit at all.
with_timeout() {
	if command -v timeout >/dev/null 2>&1; then
		timeout "$@"
	elif command -v gtimeout >/dev/null 2>&1; then
		gtimeout "$@"
	else
		echo "warning: no timeout/gtimeout, running without a time limit (brew install coreutils)" >&2
		shift
		"$@"
	fi
}

alive() {
	[[ -f $STATE/cid && -f $STATE/port && -f $STATE/key ]] || return 1
	[[ $(docker inspect -f '{{.State.Running}}' "$(cat "$STATE/cid")" 2>/dev/null) == true ]]
}

ssh_ok() {
	with_timeout 10 ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
		-o ConnectTimeout=5 -o LogLevel=ERROR -o BatchMode=yes \
		-i "$STATE/key" -p "$(cat "$STATE/port")" dev@127.0.0.1 true </dev/null >/dev/null 2>&1
}

print_env() {
	echo "export TMUXPAD_BENCH_PORT=$(cat "$STATE/port")"
	echo "export TMUXPAD_BENCH_KEY=$STATE/key"
	echo "export TMUXPAD_BENCH_USER=dev"
}

up() {
	if alive; then
		log "reusing container $(head -c 12 "$STATE/cid") on port $(cat "$STATE/port")"
		print_env
		return 0
	fi
	down_quiet
	log "building $IMAGE from $BASE"
	docker build -q --build-arg BASE="$BASE" -t "$IMAGE" "$HERE/docker" >/dev/null || return 1
	mkdir -p "$STATE"
	ssh-keygen -q -t ed25519 -N '' -C tmuxpad-bench -f "$STATE/key" || return 1
	local cid port i
	cid=$(docker run -d --rm -p 127.0.0.1::22 -e AUTHORIZED_KEY="$(cat "$STATE/key.pub")" "$IMAGE") || return 1
	echo "$cid" >"$STATE/cid"
	port=$(docker port "$cid" 22 | head -n1)
	echo "${port##*:}" >"$STATE/port"
	for ((i = 0; i < 60; i++)); do
		ssh_ok && break
		sleep 0.5
	done
	ssh_ok || { log "sshd in ${cid:0:12} did not come up"; return 1; }
	log "container ${cid:0:12} on port $(cat "$STATE/port")"
	print_env
}

down_quiet() {
	[[ -f $STATE/cid ]] && docker rm -f "$(cat "$STATE/cid")" >/dev/null 2>&1
	rm -rf "$STATE"
}

case ${1:-} in
up) up ;;
down) down_quiet ;;
*) echo "usage: ${0##*/} up|down" >&2; exit 2 ;;
esac
