# shellcheck shell=bash

# a session whose pane runs no agent stub
attach_session() { CMD='sleep 1000' h new api api; }

# client_pids NAME - PIDs of NAME's tmux clients, sorted
client_pids() { r "tmux list-clients -t =$1 -F '#{client_pid}' | sort"; }

# wait_dead PID - wait up to 5 s for the local process PID to exit
wait_dead() {
	local i
	for ((i = 0; i < 25; i++)); do
		kill -0 "$1" 2>/dev/null || return 0
		sleep 0.2
	done
	fail "process $1 is still alive"
}

test_attach_missing_session() {
	assert_exit 4 h attach nope
	assert_exit 4 h take nope
}

test_attach_requires_client() {
	attach_session
	CLIENT='' assert_exit 2 h attach api
	CLIENT='' assert_exit 2 h take api
	assert_exit 2 h attach 'bad name'
}

test_attach_writes_client_file() {
	local pid
	attach_session
	attach_bg api >/dev/null
	wait_clients api 1 || return 1
	pid=$(client_pids api)
	assert_eq "$pid" "$(r 'ls ~/.tmuxpad/clients')" "client file name"
	assert_eq "$CLIENT_A" "$(r "cat ~/.tmuxpad/clients/$pid")" "client file content"
}

test_attach_sets_options() {
	attach_session
	r 'tmux set -t =api: mouse off; tmux set -w -t =api: window-size smallest
		tmux new-window -d -t =api: && tmux set -w -t =api:1 window-size smallest'
	attach_bg api >/dev/null
	wait_clients api 1 || return 1
	assert_eq 'mouse on' "$(r 'tmux show -t =api: mouse')" "mouse"
	assert_eq 'latest
latest' "$(r "tmux list-windows -t =api -F '#{window-size}'")" "window-size on every window"
}

test_attach_detaches_own_zombie() {
	local first old second
	attach_session
	first=$(attach_bg api)
	wait_clients api 1 || return 1
	old=$(client_pids api)
	attach_bg api >/dev/null
	# the old client goes away, the new one comes
	local i
	for ((i = 0; i < 25; i++)); do
		second=$(client_pids api)
		[[ -n $second && $second != "$old" ]] && break
		sleep 0.2
	done
	wait_clients api 1 || return 1
	[[ $second != "$old" ]] || fail "the zombie client $old was not detached"
	wait_dead "$first" || return 1
	h list >/dev/null
	assert_eq "$second" "$(r 'ls ~/.tmuxpad/clients')" "client files after list"
}

test_attach_keeps_foreign_client() {
	local b plain
	attach_session
	b=$(CLIENT=$CLIENT_B attach_bg api)
	wait_clients api 1 || return 1
	plain=$(tmux_bg attach -t =api)
	wait_clients api 2 || return 1
	CLIENT=$CLIENT_A attach_bg api >/dev/null
	wait_clients api 3 || return 1
	sleep 1
	wait_clients api 3 || return 1
	kill -0 "$b" 2>/dev/null || fail "client B was detached"
	kill -0 "$plain" 2>/dev/null || fail "the plain tmux client was detached"
	assert_eq 2 "$(CLIENT=$CLIENT_A others_of api)" "others for A"
}

test_take_detaches_everyone() {
	local b plain mine
	attach_session
	b=$(CLIENT=$CLIENT_B attach_bg api)
	wait_clients api 1 || return 1
	plain=$(tmux_bg attach -t =api)
	wait_clients api 2 || return 1
	CLIENT=$CLIENT_A attach_bg api take >/dev/null
	wait_clients api 1 || return 1
	wait_dead "$b" || return 1
	wait_dead "$plain" || return 1
	mine=$(client_pids api)
	assert_eq "$CLIENT_A" "$(r "cat ~/.tmuxpad/clients/$mine")" "the remaining client is the new one"
	assert_eq 0 "$(CLIENT=$CLIENT_A others_of api)" "others for A"
}

test_copy_cancel() {
	attach_session
	r 'tmux copy-mode -t =api:'
	assert_eq 1 "$(r "tmux display -p -t =api: '#{pane_in_mode}'")" "in copy-mode"
	assert_exit 0 h copy-cancel api
	assert_eq 0 "$(r "tmux display -p -t =api: '#{pane_in_mode}'")" "after copy-cancel"
	assert_exit 0 h copy-cancel api
	assert_exit 0 h copy-cancel nope
	assert_exit 2 h copy-cancel 'bad name'
}

test_kill() {
	h new api api
	wait_log || return 1
	assert_exit 0 r 'test -f ~/.tmuxpad/api.claude'
	assert_exit 0 h kill api
	assert_exit 1 r 'tmux has-session -t =api'
	assert_exit 1 r 'test -e ~/.tmuxpad/api.claude'
	assert_exit 0 h kill api
	assert_exit 2 h kill 'bad name'
}

test_detach_on_ssh_close() {
	local pid
	attach_session
	pid=$(attach_bg api)
	wait_clients api 1 || return 1
	kill "$pid"
	local i n
	for ((i = 0; i < 15; i++)); do
		n=$(r "tmux list-clients -t =api 2>/dev/null | wc -l")
		[[ $n == 0 ]] && return 0
		sleep 0.2
	done
	fail "clients after closing ssh: $n"
}

test_attach_unknown_term() {
	attach_session
	TERM=bogus-term attach_bg api >/dev/null
	wait_clients api 1
}

# =NAME is an exact match: without it tmux would take api2 for api
test_exact_session_names() {
	r 'tmux new -d -s api2 -c ~/projects/api'
	r 'tmux copy-mode -t =api2:'
	assert_exit 4 h attach api
	assert_exit 4 h take api
	assert_exit 0 h kill api
	assert_exit 0 h copy-cancel api
	assert_eq 1 "$(r "tmux display -p -t =api2: '#{pane_in_mode}'")" "api2 still in copy-mode"
	assert_exit 0 h new api api
	assert_exit 0 r 'tmux has-session -t =api && tmux has-session -t =api2'
}
