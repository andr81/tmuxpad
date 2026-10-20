# shellcheck shell=bash

test_basic_version() {
	local out
	out=$(h version)
	assert_eq 0 $? "exit code"
	assert_eq 'tmuxpad-host 1' "$out" "version"
}

test_basic_usage() {
	assert_exit 2 h
	assert_exit 2 h bogus
}

# the environment is checked before the dispatcher
test_basic_bad_client() {
	CLIENT=not-a-uuid assert_exit 2 h version
}

test_basic_install_path() {
	assert_exit 0 r 'test -x ~/.local/bin/tmuxpad-host.sh'
}
