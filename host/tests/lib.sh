# shellcheck shell=bash
# shellcheck disable=SC2034 # globals for the test cases
# Helpers for the tmuxpad-host.sh test bench: ssh into the container the way
# the app does, background tmux clients, assertions. Sourced by run.sh.

PORT=${PORT:-}
KEY=${KEY:-}
TMP=${TMP:-}
CLIENT_A=11111111-1111-4111-8111-111111111111
CLIENT_B=22222222-2222-4222-8222-222222222222

# per-test globals, reset before every test by run.sh
CLIENT=$CLIENT_A
PROJECTS=projects
CMD=claude

SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
	-o ConnectTimeout=5 -o LogLevel=ERROR -i "$KEY" -p "$PORT")

# q VALUE - single-quote VALUE for the remote shell
q() { printf "'%s'" "${1//\'/\'\\\'\'}"; }

# hostcmd SUB ARGS... - the exec string of §5 of the spec
hostcmd() {
	local s=env a
	[[ -n $CLIENT ]] && s+=" TMUXPAD_CLIENT=$(q "$CLIENT")"
	[[ -n $PROJECTS ]] && s+=" TMUXPAD_PROJECTS=$(q "$PROJECTS")"
	[[ -n $CMD ]] && s+=" TMUXPAD_CMD=$(q "$CMD")"
	# shellcheck disable=SC2016 # $HOME is for the remote shell
	s+=' "$HOME"/.local/bin/tmuxpad-host.sh'
	for a in "$@"; do s+=" $(q "$a")"; done
	printf '%s' "$s"
}

# r CMD... - a raw command in the container
r() { timeout 20 ssh "${SSH_OPTS[@]}" dev@127.0.0.1 -- "$*"; }

# h SUB ARGS... - a host script subcommand, called the way the app calls it
h() { timeout 20 ssh "${SSH_OPTS[@]}" dev@127.0.0.1 -- "$(hostcmd "$@")"; }

# attach_bg NAME [SUB] - a tmux client in the background through `SUB NAME`
# (attach by default), with a pty; prints the PID of the local ssh
attach_bg() {
	timeout 120 ssh -tt -n "${SSH_OPTS[@]}" dev@127.0.0.1 "$(hostcmd "${2:-attach}" "$1")" >/dev/null 2>&1 &
	local pid=$!
	# tests run in subshells: the file is what reset and the trap see
	echo "$pid" >>"$TMP/bg.pids"
	echo "$pid"
}

# tmux_bg ARGS... - a plain tmux client (not through the script) in the background
tmux_bg() {
	timeout 120 ssh -tt -n "${SSH_OPTS[@]}" dev@127.0.0.1 "tmux $*" >/dev/null 2>&1 &
	local pid=$!
	echo "$pid" >>"$TMP/bg.pids"
	echo "$pid"
}

kill_bg() {
	local pid
	if [[ -f $TMP/bg.pids ]]; then
		while read -r pid; do kill "$pid" 2>/dev/null; done <"$TMP/bg.pids"
		rm -f "$TMP/bg.pids"
	fi
}

# wait_clients NAME N - wait up to 5 s for exactly N tmux clients on NAME
wait_clients() {
	local n i
	for ((i = 0; i < 25; i++)); do
		n=$(r "tmux list-clients -t =$1 -F '#{client_pid}' 2>/dev/null | wc -l")
		[[ $n == "$2" ]] && return 0
		sleep 0.2
	done
	fail "session $1: expected $2 clients, got ${n:-?}"
}

# wait_log [N] - wait up to 5 s for N lines (default 1) in ~/claude-args.log
wait_log() {
	local want=${1:-1} n i
	for ((i = 0; i < 25; i++)); do
		n=$(r 'cat ~/claude-args.log 2>/dev/null | wc -l')
		((n >= want)) && return 0
		sleep 0.2
	done
	fail "claude-args.log: expected $want lines, got ${n:-?}"
}

reset() {
	kill_bg
	CLIENT=$CLIENT_A PROJECTS=projects CMD=claude
	r 'tmux kill-server 2>/dev/null; rm -rf ~/.tmuxpad ~/.claude ~/claude-args.log ~/.tmux.conf ~/proj-link ~/projects ~/elsewhere;
		mkdir -p ~/projects/api ~/projects/web ~/projects/my.app; touch ~/projects/README.md'
}

# ---------------------------------------------------------------- assertions

fail() {
	echo "  FAIL: $1" >>"$FAILED"
	return 1
}

assert_eq() {
	[[ $1 == "$2" ]] || fail "${3:-values differ}: expected [$1], got [$2]"
}

# assert_exit CODE CMD... - run CMD, compare its exit code
assert_exit() {
	local want=$1 out code
	shift
	out=$("$@" 2>&1)
	code=$?
	[[ $code == "$want" ]] || fail "$*: expected exit $want, got $code; output: $out"
}

assert_contains() {
	[[ $1 == *"$2"* ]] || fail "expected [$2] in [$1]"
}

assert_not_contains() {
	[[ $1 != *"$2"* ]] || fail "did not expect [$2] in [$1]"
}
