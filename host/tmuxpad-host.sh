#!/usr/bin/env bash
# tmuxpad-host.sh - the host half of TmuxPad. Lives on the server in
# ~/.local/bin; the iPad app installs it over stdin and calls its subcommands
# over ssh exec channels. The contract is §7 of docs/tmuxpad-spec.md.
#
# Based on agt-remote-host.sh from the remote-claude-session recipe of agterm
# (MIT, https://github.com/umputun/agterm/tree/master/cookbook/remote-claude-session).
#
#   version          print the script version
#   list             sessions and projects as TSV, header `V 1`
#   new NAME PROJECT create a tmux session and start the agent in it
#   attach NAME      attach this device's client to a session
#   take NAME        attach and detach every other client
#   copy-cancel NAME leave tmux copy-mode before typing
#   kill NAME        end a session (DESTRUCTIVE: everything in it dies)
#   setup            host preparation; idempotent
#   doctor           check the host, TSV `ok|warn|fail KEY MESSAGE`
#   auth             store the agent's OAuth token from stdin
set -u

VERSION=1

STATE=$HOME/.tmuxpad
PROJECTS=${TMUXPAD_PROJECTS:-$HOME/projects}
PROJECTS=${PROJECTS/#\~/$HOME}
[[ $PROJECTS == /* ]] || PROJECTS=$HOME/$PROJECTS
# a symlinked root must not break the "path right under the root" filter of list
PROJECTS=$(realpath -m -- "$PROJECTS")
CMD=${TMUXPAD_CMD:-claude}
CLIENT=${TMUXPAD_CLIENT:-}

die() {
	echo "$1" >&2
	exit "${2:-1}"
}

if [[ -n $CLIENT && ! $CLIENT =~ ^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$ ]]; then
	die "bad TMUXPAD_CLIENT: $CLIENT" 2
fi

valid_name() { [[ $1 =~ ^[A-Za-z0-9_-]{1,64}$ ]]; }
valid_project() { [[ $1 =~ ^[A-Za-z0-9_-][A-Za-z0-9._-]{0,127}$ ]]; }
need_client() { [[ -n $CLIENT ]] || die "TMUXPAD_CLIENT is required" 2; }

not_implemented() { die "not implemented: $1" 1; }

# the agent gets -n/--session-id/--resume only when the command is claude itself
CMD_FIRST=${CMD%%[[:space:]]*}
is_claude() { [[ ${CMD_FIRST##*/} == claude ]]; }

# tmux_version - MAJOR.MINOR of the installed tmux (`3.2a` -> 3.2, `next-3.5` -> 3.5)
tmux_version() {
	[[ $(tmux -V 2>/dev/null) =~ ([0-9]+)\.([0-9]+) ]] || return 1
	echo "${BASH_REMATCH[1]}.${BASH_REMATCH[2]}"
}

# version_ge A B - A >= B for MAJOR.MINOR; no sort -V, busybox lacks it
version_ge() {
	local a1=${1%%.*} a2=${1#*.} b1=${2%%.*} b2=${2#*.}
	((a1 > b1 || (a1 == b1 && a2 >= b2)))
}

# ---------------------------------------------------------------- doctor, setup

DOCTOR_FAILED=0
report() {
	printf '%s\t%s\t%s\n' "$1" "$2" "$3"
	[[ $1 != fail ]] || DOCTOR_FAILED=1
}

doctor() {
	local raw v path n=0 d
	if ! command -v tmux >/dev/null 2>&1; then
		report fail tmux "tmux not found, 3.1 required"
	elif ! v=$(tmux_version); then
		report fail tmux "cannot parse \`$(tmux -V 2>&1)\`, 3.1 required"
	else
		raw=$(tmux -V)
		raw=${raw#tmux }
		if version_ge "$v" 3.1; then
			report ok tmux "tmux $raw"
		else
			report fail tmux "tmux $raw found, 3.1 required"
		fi
	fi

	# the pane runs a login shell, the exec channel does not: look where the pane looks
	if ! is_claude; then
		report ok claude "custom command"
	elif path=$(bash -lc "command -v $(printf '%q' "$CMD_FIRST")" </dev/null 2>/dev/null) && [[ -n $path ]]; then
		report ok claude "${path##*$'\n'}"
		if bash -lc "$CMD --help" </dev/null 2>/dev/null | grep -q -- --name; then
			report ok claude_name "--name supported"
		else
			report warn claude_name "no --name in \`$CMD_FIRST --help\`, sessions will start unnamed"
		fi
	else
		report fail claude "$CMD_FIRST not found in the login shell PATH"
	fi

	if [[ -d $PROJECTS ]]; then
		for d in "$PROJECTS"/*/; do
			[[ -d $d ]] || continue
			d=${d%/}
			valid_project "${d##*/}" && ((n++))
		done
		report ok projects "$n projects in $PROJECTS"
	else
		report fail projects "$PROJECTS is not a directory"
	fi

	report ok script "tmuxpad-host $VERSION"
	return "$DOCTOR_FAILED"
}

# an append to a file whose last line has no newline glues onto it
end_newline() {
	[[ -s $1 && -n $(tail -c1 "$1") ]] && printf '\n' >>"$1"
	return 0
}

# idempotent: the tmux.conf block is added once, by its marker. Leaves alone
# ~/.profile (new sources $STATE/env itself), ~/.claude and ~/.ssh.
setup() {
	mkdir -p "$STATE" "$STATE/clients" "$PROJECTS" || exit 1

	# OSC 52 (clipboard) and OSC 9/777 (notifications) from the agent have to
	# pass through tmux. No global `mouse on`: new and attach set it per session.
	local conf=$HOME/.tmux.conf v
	if ! grep -qsxF '# tmuxpad: begin' "$conf"; then
		end_newline "$conf"
		{
			echo '# tmuxpad: begin'
			echo 'set -g set-clipboard on'
			echo 'set -g history-limit 50000'
			# tmux before 3.3 stops reading the config at an unknown option
			if v=$(tmux_version) && version_ge "$v" 3.3; then
				echo 'set -g allow-passthrough on'
			fi
			echo '# tmuxpad: end'
		} >>"$conf"
	fi

	doctor
}

# ---------------------------------------------------------------- auth

auth() {
	# the token file is created before it can be chmod'd, and a channel that drops
	# between the write and the rename leaves the temporary behind
	umask 077
	local token
	IFS= read -r token
	[[ $token =~ ^[A-Za-z0-9_-]+$ ]] || die "no usable token on stdin" 2
	mkdir -p "$STATE"
	local env=$STATE/env
	touch "$env"
	chmod 600 "$env"
	rm -f "$env.tmp"
	grep -v '^export CLAUDE_CODE_OAUTH_TOKEN=' "$env" >"$env.tmp" || true
	printf "export CLAUDE_CODE_OAUTH_TOKEN='%s'\n" "$token" >>"$env.tmp"
	chmod 600 "$env.tmp"
	mv "$env.tmp" "$env"
	echo "token stored in $env"
}

usage() {
	die "usage: ${0##*/} version | list | new NAME PROJECT | attach NAME | take NAME | copy-cancel NAME | kill NAME | setup | doctor | auth" 2
}

case ${1:-} in
version) echo "tmuxpad-host $VERSION" ;;
setup) setup ;;
doctor) doctor ;;
auth) auth ;;
list | new | attach | take | copy-cancel | kill) not_implemented "$1" ;;
*) usage ;;
esac
