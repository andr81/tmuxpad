# shellcheck shell=bash

# session NAME DIR - a tmux session in ~/DIR made directly, bypassing new
session() { r "tmux new -d -s $1 -c ~/$2"; }

# others_of NAME - the others field of NAME's S line in `h list`
others_of() { h list | awk -F '\t' -v n="$1" '$1 == "S" && $2 == n { print $3 }'; }

test_list_header_and_projects() {
	local out
	out=$(h list)
	assert_eq 0 $? "exit code"
	assert_eq 'V	1' "$(head -n1 <<<"$out")" "header"
	assert_eq "P	api	/home/dev/projects/api
P	my.app	/home/dev/projects/my.app
P	web	/home/dev/projects/web" "$(grep '^P' <<<"$out")" "projects"
	assert_not_contains "$out" README
	assert_eq 0 "$(grep -c '^S' <<<"$out")" "no sessions without a tmux server"
}

test_list_filters_foreign_sessions() {
	local out
	session home ''
	r 'mkdir -p ~/projects/api/sub' && session deep projects/api/sub
	session zz projects/web
	session api projects/api
	out=$(h list)
	assert_eq "api web" "$(awk -F '\t' '$1 == "S" { printf "%s%s", s, $4; s = " " }' <<<"$out")" "projects of S lines"
	assert_eq "api zz" "$(awk -F '\t' '$1 == "S" { printf "%s%s", s, $2; s = " " }' <<<"$out")" "names, sorted"
	assert_eq 2 "$(grep -c '^S' <<<"$out")" "S lines: home and deep are not under the root"
}

test_list_activity_is_epoch() {
	local act
	session api projects/api
	act=$(h list | awk -F '\t' '$1 == "S" { print $5 }')
	if ! [[ $act =~ ^[0-9]+$ ]] || ((act < 1700000000)); then
		fail "activity [$act] is not an epoch"
	fi
}

test_list_symlinked_root() {
	local out
	r 'ln -sfn projects ~/proj-link'
	session api projects/api
	out=$(PROJECTS=/home/dev/proj-link h list)
	assert_contains "$out" 'S	api	0	api	'
	assert_contains "$out" 'P	api	/home/dev/projects/api'
}

test_list_symlinked_project() {
	local out
	r 'mkdir -p ~/elsewhere/foo && ln -sfn ~/elsewhere/foo ~/projects/foo && ln -sfn api ~/projects/alias'
	assert_exit 0 h new s1 foo
	assert_exit 0 h new s2 alias
	out=$(h list)
	assert_contains "$out" 'S	s1	0	foo	'
	assert_contains "$out" 'S	s2	0	alias	'
}

test_list_others() {
	session api projects/api
	attach_bg api >/dev/null
	wait_clients api 1 || return 1
	assert_eq 0 "$(CLIENT=$CLIENT_A others_of api)" "own client"
	assert_eq 1 "$(CLIENT=$CLIENT_B others_of api)" "another device"
	assert_eq 1 "$(CLIENT='' others_of api)" "no TMUXPAD_CLIENT"
}

test_list_plain_tmux_client_is_other() {
	session api projects/api
	tmux_bg attach -t =api >/dev/null
	wait_clients api 1 || return 1
	assert_eq 1 "$(CLIENT=$CLIENT_A others_of api)" "plain tmux client, A"
	assert_eq 1 "$(CLIENT=$CLIENT_B others_of api)" "plain tmux client, B"
}

test_list_prunes_stale_client_files() {
	local pid
	session api projects/api
	attach_bg api >/dev/null
	wait_clients api 1 || return 1
	pid=$(r "tmux list-clients -t =api -F '#{client_pid}'")
	r 'echo x > ~/.tmuxpad/clients/999999; echo x > ~/.tmuxpad/clients/junk'
	assert_exit 0 h list
	assert_eq "$pid" "$(r 'ls ~/.tmuxpad/clients')" "client files"
}

test_list_no_projects_root() {
	PROJECTS=nope assert_exit 2 h list
}

test_list_others_per_session() {
	session api projects/api
	session web projects/web
	attach_bg api >/dev/null
	CLIENT=$CLIENT_B attach_bg web >/dev/null
	tmux_bg attach -t =web >/dev/null
	wait_clients api 1 || return 1
	wait_clients web 2 || return 1
	assert_eq 0 "$(CLIENT=$CLIENT_A others_of api)" "api for A"
	assert_eq 2 "$(CLIENT=$CLIENT_A others_of web)" "web for A"
	assert_eq 1 "$(CLIENT=$CLIENT_B others_of web)" "web for B"
}

test_list_skips_bad_session_names() {
	local out
	r "tmux new -d -s 'my work' -c ~/projects/api"
	session api projects/api
	out=$(h list)
	assert_eq 1 "$(grep -c '^S' <<<"$out")" "S lines"
	assert_not_contains "$out" 'my work'
}

# a client file is kept while its PID is still the script before exec or the
# tmux client the server does not list yet, and dropped for any other process
test_list_keeps_client_files_of_attaching_pids() {
	local script client other
	r 'mkdir -p ~/.tmuxpad/clients && cp /bin/sleep /tmp/tmux'
	script=$(r "bash -c 'exec -a tmuxpad-host.sh sleep 30' >/dev/null 2>&1 </dev/null & echo \$!")
	client=$(r '/tmp/tmux 30 >/dev/null 2>&1 </dev/null & echo $!')
	other=$(r 'sleep 30 >/dev/null 2>&1 </dev/null & echo $!')
	r "for p in $script $client $other; do echo x > ~/.tmuxpad/clients/\$p; done"
	assert_exit 0 h list
	assert_eq "$(printf '%s\n' "$script" "$client" | sort)" "$(r 'ls ~/.tmuxpad/clients | sort')" "client files"
	r "kill $script $client $other"
}
