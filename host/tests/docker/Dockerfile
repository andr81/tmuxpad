# Test bench for tmuxpad-host.sh: sshd + tmux + a claude stub, user `dev`.
ARG BASE=ubuntu:24.04
FROM $BASE

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
	&& apt-get install -y --no-install-recommends openssh-server tmux bash coreutils ncurses-bin \
	&& rm -rf /var/lib/apt/lists/*

RUN useradd -m -s /bin/bash dev && mkdir -p /run/sshd
# TMUXPAD_* is not accepted from the client: the app passes it through `env`,
# and the bench must prove that this is enough
RUN { \
		echo 'PasswordAuthentication no'; \
		echo 'PubkeyAuthentication yes'; \
		echo 'AcceptEnv LANG LC_*'; \
	} >>/etc/ssh/sshd_config

COPY claude /usr/local/bin/claude
COPY claude-old /usr/local/bin/claude-old
COPY entrypoint.sh /entrypoint.sh
RUN chmod 755 /usr/local/bin/claude /usr/local/bin/claude-old /entrypoint.sh

EXPOSE 22
ENTRYPOINT ["/entrypoint.sh"]
