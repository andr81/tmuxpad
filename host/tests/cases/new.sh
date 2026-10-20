# shellcheck shell=bash

UUID_RE='^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'

# uuid_of NAME - the UUID in ~/.tmuxpad/NAME.claude
uuid_of() { r "cut -f1 ~/.tmuxpad/$1.claude"; }

# transcript UUID [DIR] - a transcript where Claude Code would put it
transcript() {
	local d=${2:-/home/dev/projects/api}
	d=${d//[\/.]/-}
	r "mkdir -p ~/.claude/projects/$d && touch ~/.claude/projects/$d/$1.jsonl"
}

test_new_creates_session() {
	local out uuid
	out=$(h new api api)
	assert_eq 0 $? "exit code"
	assert_eq '' "$out" "stdout"
	wait_log || return 1
	assert_eq /home/dev/projects/api "$(r "tmux display -p -t =api: '#{session_path}'")" "session path"
	assert_eq on "$(r 'tmux show -v -t =api: mouse')" "mouse"
	uuid=$(uuid_of api)
	[[ $uuid =~ $UUID_RE ]] || fail "uuid [$uuid]"
	assert_eq "$uuid	api" "$(r 'cat ~/.tmuxpad/api.claude')" "api.claude"
	assert_eq "/home/dev/projects/api|-n api --session-id $uuid|token=none" "$(r 'cat ~/claude-args.log')" "stub log"
}

test_new_conflict() {
	h new api api
	wait_log || return 1
	assert_exit 3 h new api api
	sleep 1
	assert_eq 1 "$(r 'wc -l < ~/claude-args.log')" "log lines"
}

test_new_bad_names() {
	assert_exit 2 h new 'a b' api
	assert_exit 2 h new .hidden api
	assert_exit 2 h new api nothere
	assert_exit 2 h new api ../api
	assert_exit 2 h new api
	assert_exit 2 h new "$(printf 'a%.0s' {1..65})" api
	assert_exit 2 h new api "$(printf 'p%.0s' {1..129})"
	assert_eq 0 "$(r 'tmux list-sessions 2>/dev/null | wc -l')" "sessions"
}

test_new_resume_after_reboot() {
	local uuid
	h new api api
	wait_log || return 1
	uuid=$(uuid_of api)
	r 'tmux kill-session -t =api'
	transcript "$uuid"
	assert_exit 0 h new api api
	wait_log 2 || return 1
	assert_eq "/home/dev/projects/api|--resume $uuid|token=none" "$(r 'tail -n1 ~/claude-args.log')" "resume"
	assert_eq "$uuid	api" "$(r 'cat ~/.tmuxpad/api.claude')" "api.claude unchanged"
}

test_new_fresh_uuid_without_transcript() {
	local old uuid
	h new api api
	wait_log || return 1
	old=$(uuid_of api)
	r 'tmux kill-session -t =api'
	assert_exit 0 h new api api
	wait_log 2 || return 1
	uuid=$(uuid_of api)
	[[ $uuid =~ $UUID_RE && $uuid != "$old" ]] || fail "new uuid [$uuid], old [$old]"
	assert_eq "/home/dev/projects/api|-n api --session-id $uuid|token=none" "$(r 'tail -n1 ~/claude-args.log')" "fresh"
}

test_new_other_project_gets_new_uuid() {
	local old uuid
	h new x api
	wait_log || return 1
	old=$(uuid_of x)
	transcript "$old"
	r 'tmux kill-session -t =x'
	assert_exit 0 h new x web
	wait_log 2 || return 1
	uuid=$(uuid_of x)
	[[ $uuid =~ $UUID_RE && $uuid != "$old" ]] || fail "new uuid [$uuid], old [$old]"
	assert_eq "$uuid	web" "$(r 'cat ~/.tmuxpad/x.claude')" "x.claude"
	assert_eq "/home/dev/projects/web|-n x --session-id $uuid|token=none" "$(r 'tail -n1 ~/claude-args.log')" "other project"
}

test_new_old_claude_unnamed() {
	local uuid
	CMD=/opt/claude-old/bin/claude h new api api
	wait_log || return 1
	uuid=$(uuid_of api)
	assert_eq "/home/dev/projects/api|--session-id $uuid|token=none" "$(r 'cat ~/claude-args.log')" "no -n"
}

test_new_custom_cmd() {
	local i cur
	CMD='sleep 1000' h new api api
	for ((i = 0; i < 25; i++)); do
		cur=$(r "tmux display -p -t =api: '#{pane_current_command}'")
		[[ $cur == sleep ]] && break
		sleep 0.2
	done
	assert_eq sleep "$cur" "pane command"
	assert_exit 1 r 'test -e ~/.tmuxpad/api.claude'
	assert_exit 1 r 'test -e ~/claude-args.log'
}

test_new_rejects_quote() {
	CMD="it's" assert_exit 2 h new api api
	assert_exit 1 r 'tmux has-session -t =api'
}

test_new_sources_env() {
	printf 'tok_1\n' | h auth >/dev/null
	h new api api
	wait_log || return 1
	assert_contains "$(r 'cat ~/claude-args.log')" '|token=tok_1'
}

test_new_exit_keeps_session() {
	local i cur
	CMD='sleep 1000' h new api api
	for ((i = 0; i < 25; i++)); do
		cur=$(r "tmux display -p -t =api: '#{pane_current_command}'")
		[[ $cur == sleep ]] && break
		sleep 0.2
	done
	r 'tmux send-keys -t =api: C-c'
	sleep 2
	assert_exit 0 r 'tmux has-session -t =api'
	assert_eq bash "$(r "tmux display -p -t =api: '#{pane_current_command}'")" "pane runs the shell again"
}

test_new_name_limits() {
	local long
	long=$(printf 'a%.0s' {1..64})
	assert_exit 0 h new "$long" api
	assert_exit 0 h new -x api
	wait_log 2 || return 1
	assert_contains "$(r 'cat ~/claude-args.log')" '|-n -x --session-id '
	r "mkdir ~/projects/_$(printf 'p%.0s' {1..127})"
	assert_exit 0 h new deep "_$(printf 'p%.0s' {1..127})"
}

test_new_cleans_up_on_failure() {
	r 'touch ~/.tmuxpad'
	assert_exit 1 h new api api
	assert_exit 1 r 'tmux has-session -t =api'
}
