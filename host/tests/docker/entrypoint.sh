#!/usr/bin/env bash
# The key comes in an env var, not a mount: StrictModes wants it owned by dev.
set -eu
mkdir -p /home/dev/.ssh
printf '%s\n' "${AUTHORIZED_KEY:?AUTHORIZED_KEY is required}" >/home/dev/.ssh/authorized_keys
chmod 700 /home/dev/.ssh
chmod 600 /home/dev/.ssh/authorized_keys
chown -R dev:dev /home/dev/.ssh
exec /usr/sbin/sshd -D -e
