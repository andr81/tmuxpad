# shellcheck shell=bash

# repo NAME - a bare repository ~/repos/NAME.git with one commit, and a key that
# lets dev ssh into its own container: clone tests go over real ssh
repo() {
	r "set -e
		[ -f ~/.ssh/id_ed25519 ] || ssh-keygen -q -t ed25519 -N '' -f ~/.ssh/id_ed25519
		grep -qxF \"\$(cat ~/.ssh/id_ed25519.pub)\" ~/.ssh/authorized_keys || cat ~/.ssh/id_ed25519.pub >>~/.ssh/authorized_keys
		rm -f ~/.ssh/known_hosts
		rm -rf ~/repos/$1.git /tmp/seed-$1 && mkdir -p ~/repos
		git init -q --bare ~/repos/$1.git
		git init -q /tmp/seed-$1 && cd /tmp/seed-$1 && echo hello >README
		git add README && git -c user.email=t@t -c user.name=t commit -q -m init
		git push -q ~/repos/$1.git HEAD:refs/heads/main 2>/dev/null
		git --git-dir ~/repos/$1.git symbolic-ref HEAD refs/heads/main
		rm -rf /tmp/seed-$1" >/dev/null
}

# leftovers - temporary clone folders still in the projects root
leftovers() { r 'ls -A ~/projects | grep -c "^\.tmuxpad-clone" || true'; }

test_mkproject_creates_folder() {
	local out
	out=$(h mkproject newone)
	assert_eq 0 $? "exit code"
	assert_eq '' "$out" "stdout"
	assert_eq yes "$(r '[ -d ~/projects/newone ] && echo yes')" "folder"
	assert_eq 0 "$(r 'ls -A ~/projects/newone | wc -l')" "empty"
	assert_contains "$(h list)" $'P\tnewone\t/home/dev/projects/newone'
}

test_mkproject_exists() {
	assert_exit 5 h mkproject api
	# a file with the project name counts as taken too
	assert_exit 5 h mkproject README.md
	r 'ln -s /tmp ~/projects/link'
	assert_exit 5 h mkproject link
}

test_mkproject_bad_names() {
	assert_exit 2 h mkproject ''
	assert_exit 2 h mkproject .hidden
	assert_exit 2 h mkproject 'a b'
	assert_exit 2 h mkproject ../escape
	assert_eq no "$(r '[ -e ~/escape ] && echo yes || echo no')" "no escape"
}

test_mkproject_no_root() {
	PROJECTS=nope assert_exit 2 h mkproject x
	assert_eq no "$(r '[ -e ~/nope ] && echo yes || echo no')" "root not created"
}

test_clone_scp_url() {
	local out
	repo demo
	out=$(h clone demo 'dev@localhost:repos/demo.git')
	assert_eq 0 $? "exit code: $out"
	assert_eq hello "$(r 'cat ~/projects/demo/README')" "content"
	assert_eq dev@localhost:repos/demo.git "$(r 'git -C ~/projects/demo remote get-url origin')" "origin"
	# accept-new: the unknown host key was taken and stored (hashed on Ubuntu)
	assert_exit 0 r 'ssh-keygen -F localhost -f ~/.ssh/known_hosts'
	assert_eq 0 "$(leftovers)" "temporary folders"
	assert_contains "$(h list)" $'P\tdemo\t/home/dev/projects/demo'
}

test_clone_ssh_url() {
	repo demo
	assert_exit 0 h clone other 'ssh://dev@localhost/home/dev/repos/demo.git'
	assert_eq hello "$(r 'cat ~/projects/other/README')" "content"
}

test_clone_changed_host_key_refused() {
	local out code
	repo demo
	# a wrong key for localhost: accept-new takes new keys, not changed ones
	r "echo 'localhost ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl' >~/.ssh/known_hosts"
	out=$(h clone demo 'dev@localhost:repos/demo.git' 2>&1)
	code=$?
	assert_eq 1 "$code" "exit code"
	assert_contains "$out" "fatal"
	assert_eq no "$(r '[ -e ~/projects/demo ] && echo yes || echo no')" "no project"
	assert_eq 0 "$(leftovers)" "temporary folders"
}

test_clone_failure_cleans_up() {
	local out code
	out=$(h clone gone 'https://127.0.0.1:1/nothing.git' 2>&1)
	code=$?
	assert_eq 1 "$code" "exit code"
	assert_contains "$out" "fatal"
	assert_eq no "$(r '[ -e ~/projects/gone ] && echo yes || echo no')" "no project"
	assert_eq 0 "$(leftovers)" "temporary folders"
}

test_clone_missing_repo() {
	repo demo
	assert_exit 1 h clone nope 'dev@localhost:repos/missing.git'
	assert_eq 0 "$(leftovers)" "temporary folders"
}

test_clone_exists() {
	assert_exit 5 h clone api 'https://example.com/a/api.git'
	assert_exit 5 h clone README.md 'https://example.com/a/b.git'
}

test_clone_bad_urls() {
	local u
	for u in '' 'file:///home/dev/repos/demo.git' '/home/dev/repos/demo.git' 'repos/demo.git' \
		'ext::sh -c touch% /tmp/pwned' 'ext::ssh://x' '-uhack' '--upload-pack=touch' \
		'https://user:secret@example.com/a.git' "https://example.com/a'b.git" 'https://example.com/a b.git' \
		'ftp://example.com/a.git' 'https://' 'dev@localhost:' 'https://user@example.com/a.git' \
		'https://ghp_token@github.com/a/b.git' 'http://x@example.com/a.git' \
		'-oProxyCommand=touch@localhost:a'; do
		assert_exit 2 h clone x "$u"
	done
	assert_eq no "$(r '[ -e ~/projects/x ] && echo yes || echo no')" "no project"
}

test_clone_good_url_forms() {
	# fail on the network (exit 1), not on validation (exit 2)
	local u
	for u in 'https://127.0.0.1:1/a/b.git' 'http://127.0.0.1:1/a' 'git://127.0.0.1:1/a.git' \
		'ssh://git@127.0.0.1:1/a/b.git'; do
		assert_exit 1 h clone x "$u"
	done
}

test_clone_bad_name() {
	assert_exit 2 h clone .hidden 'https://example.com/a.git'
	assert_exit 2 h clone '' 'https://example.com/a.git'
}

# fake_git BODY - a `git` first in PATH for one call of the script; BODY runs
# instead of the real clone with $4 = the URL and $5 = the target folder
fake_git() {
	r "mkdir -p ~/fakebin && cat >~/fakebin/git <<'EOS'
#!/bin/bash
[ \"\$1\" = clone ] || exec /usr/bin/git \"\$@\"
$1
EOS
chmod +x ~/fakebin/git"
}

# hfake SUB ARGS... - h, with the fake git first in PATH
hfake() { r "PATH=\$HOME/fakebin:\$PATH $(hostcmd "$@")"; }

test_clone_does_not_replace_parallel_project() {
	# a parallel mkproject makes the folder while git is still running
	# shellcheck disable=SC2016 # expands in the fake git, not here
	fake_git 'mkdir -p "$5" && echo x >"$5/README" && mkdir ~/projects/race'
	assert_exit 5 hfake clone race 'https://example.com/a/race.git'
	assert_eq 0 "$(r 'ls -A ~/projects/race | wc -l')" "the other project stays empty"
	assert_eq 0 "$(leftovers)" "temporary folders"
	r 'rm -rf ~/fakebin'
}

test_clone_moves_dotfiles() {
	# shellcheck disable=SC2016 # expands in the fake git, not here
	fake_git 'mkdir -p "$5/.git" "$5/src" && touch "$5/.gitignore" "$5/src/a"'
	assert_exit 0 hfake clone dots 'https://example.com/a/dots.git'
	assert_eq '.git .gitignore src' "$(r 'cd ~/projects/dots && ls -A | tr "\n" " " | sed "s/ $//"')" "entries"
	assert_eq 0 "$(leftovers)" "temporary folders"
	r 'rm -rf ~/fakebin'
}

test_clone_askpass_is_disabled() {
	# shellcheck disable=SC2016 # expands in the fake git, not here
	fake_git 'echo "askpass=$GIT_ASKPASS ssh=$SSH_ASKPASS_REQUIRE prompt=$GIT_TERMINAL_PROMPT" >~/clone-env; exit 1'
	assert_exit 1 hfake clone ask 'https://example.com/a/ask.git'
	assert_eq 'askpass=false ssh=never prompt=0' "$(r 'cat ~/clone-env')" "environment"
	r 'rm -rf ~/fakebin ~/clone-env'
}
