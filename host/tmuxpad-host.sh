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

# shellcheck disable=SC2034 # STATE and CMD serve the subcommands of later tasks
STATE=$HOME/.tmuxpad
PROJECTS=${TMUXPAD_PROJECTS:-$HOME/projects}
PROJECTS=${PROJECTS/#\~/$HOME}
[[ $PROJECTS == /* ]] || PROJECTS=$HOME/$PROJECTS
# a symlinked root must not break the "path right under the root" filter of list
PROJECTS=$(realpath -m -- "$PROJECTS")
# shellcheck disable=SC2034
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

usage() {
	die "usage: ${0##*/} version | list | new NAME PROJECT | attach NAME | take NAME | copy-cancel NAME | kill NAME | setup | doctor | auth" 2
}

case ${1:-} in
version) echo "tmuxpad-host $VERSION" ;;
list | new | attach | take | copy-cancel | kill | setup | doctor | auth) not_implemented "$1" ;;
*) usage ;;
esac
