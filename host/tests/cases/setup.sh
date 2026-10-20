# shellcheck shell=bash

# tmux >= 3.3 on the bench? (24.04 has 3.4, 22.04 has 3.2a)
tmux_ge_33() {
	[[ $(r tmux -V) =~ ([0-9]+)\.([0-9]+) ]] || return 1
	((BASH_REMATCH[1] > 3 || (BASH_REMATCH[1] == 3 && BASH_REMATCH[2] >= 3)))
}

test_setup_tmux_conf_block() {
	local conf
	assert_exit 0 h setup
	assert_exit 0 h setup
	conf=$(r 'cat ~/.tmux.conf')
	assert_eq 1 "$(grep -cxF '# tmuxpad: begin' <<<"$conf")" "begin markers"
	assert_eq 1 "$(grep -cxF '# tmuxpad: end' <<<"$conf")" "end markers"
	assert_contains "$conf" 'set -g set-clipboard on'
	assert_contains "$conf" 'set -g history-limit 50000'
	assert_not_contains "$conf" 'mouse'
	if tmux_ge_33; then
		assert_contains "$conf" 'set -g allow-passthrough on'
	else
		assert_not_contains "$conf" 'allow-passthrough'
	fi
	# the config must load in the bench's tmux
	assert_exit 0 r 'tmux -f ~/.tmux.conf new -d -s conftest && tmux kill-server'
}

# an existing config without a trailing newline keeps its last line intact
test_setup_tmux_conf_append() {
	local conf
	r "printf 'set -g status off' > ~/.tmux.conf"
	assert_exit 0 h setup
	conf=$(r 'cat ~/.tmux.conf')
	assert_eq 'set -g status off' "$(head -n1 <<<"$conf")" "first line"
	assert_eq '# tmuxpad: begin' "$(sed -n 2p <<<"$conf")" "second line"
}

test_setup_leaves_profile_alone() {
	local before after
	before=$(r 'sha256sum ~/.profile')
	assert_exit 0 h setup
	after=$(r 'sha256sum ~/.profile')
	assert_eq "$before" "$after" ".profile"
	assert_exit 1 r 'test -e ~/.claude/settings.json'
}

test_setup_creates_dirs() {
	r 'rm -rf ~/projects'
	h setup >/dev/null
	assert_exit 0 r 'test -d ~/.tmuxpad/clients && test -d ~/projects'
}

test_doctor_ok() {
	local out code
	out=$(h doctor)
	code=$?
	assert_eq 0 "$code" "exit code"
	assert_eq '' "$(grep -v '^ok	' <<<"$out")" "non-ok lines"
	assert_contains "$out" $'ok\ttmux\ttmux '
	assert_contains "$out" $'ok\tclaude\t/usr/local/bin/claude'
	assert_contains "$out" $'ok\tclaude_name\t'
	# README.md is a file, not a project
	assert_contains "$out" $'ok\tprojects\t3 projects in /home/dev/projects'
	assert_contains "$out" $'ok\tscript\ttmuxpad-host 1'
}

test_doctor_no_projects_root() {
	local out code
	out=$(PROJECTS=nope h doctor)
	code=$?
	assert_eq 1 "$code" "exit code"
	assert_contains "$out" $'fail\tprojects\t/home/dev/nope'
}

test_doctor_old_claude() {
	local out code
	out=$(CMD=/opt/claude-old/bin/claude h doctor)
	code=$?
	assert_eq 0 "$code" "exit code"
	assert_contains "$out" $'ok\tclaude\t/opt/claude-old/bin/claude'
	assert_contains "$out" $'warn\tclaude_name\t'
}

test_doctor_missing_claude() {
	local out code
	out=$(CMD='claude-nowhere/claude' h doctor)
	code=$?
	assert_eq 1 "$code" "exit code"
	assert_contains "$out" $'fail\tclaude\t'
	assert_not_contains "$out" 'claude_name'
}

test_doctor_custom_cmd() {
	local out code
	out=$(CMD='sleep 1000' h doctor)
	code=$?
	assert_eq 0 "$code" "exit code"
	assert_contains "$out" $'ok\tclaude\tcustom command'
	assert_not_contains "$out" 'claude_name'
}

test_auth_stores_token() {
	local out
	out=$(printf 'sk-abc_1\n' | h auth)
	assert_eq 0 $? "exit code"
	assert_contains "$out" 'token stored in /home/dev/.tmuxpad/env'
	assert_eq 600 "$(r 'stat -c %a ~/.tmuxpad/env')" "mode"
	assert_eq "export CLAUDE_CODE_OAUTH_TOKEN='sk-abc_1'" "$(r 'cat ~/.tmuxpad/env')" "env"
	printf 'sk-def_2\n' | h auth >/dev/null
	assert_eq "export CLAUDE_CODE_OAUTH_TOKEN='sk-def_2'" "$(r 'cat ~/.tmuxpad/env')" "env after the second auth"
	assert_exit 1 r 'test -e ~/.tmuxpad/env.tmp'
}

test_auth_rejects_garbage() {
	local code
	printf 'bad token\n' | h auth >/dev/null 2>&1
	code=$?
	assert_eq 2 "$code" "exit code"
	assert_exit 1 r 'test -e ~/.tmuxpad/env'
}
