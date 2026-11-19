# Throwaway "VPS" for tando tests: Ubuntu + systemd as PID 1, sshd, sudo, Caddy, Node, rsync.
# Everything `tando host setup` needs from apt is in the image (rsync, curl, nftables, openssl), so
# a suite's first setup does not wait for, or fail with, the package mirror. Installing them is
# tested where it belongs: on the bare image below. cron and at are what test/e2e-ci.sh plants
# jobs with (an Ubuntu server has cron).
# BARE=1: a fresh cloud VM instead: systemd, sshd and a sudo user, nothing else (apt works), for
# test/e2e-bootstrap.sh, where `tando host setup` installs everything.
ARG UBUNTU=26.04
FROM ubuntu:${UBUNTU}
# CADDY=upstream (current release) or CADDY=ubuntu (the distribution's older package, as on the real VPS).
ARG CADDY=upstream
ARG BARE=0
ENV DEBIAN_FRONTEND=noninteractive container=docker
RUN if [ "$BARE" = 1 ]; then \
      apt-get update && apt-get install -y --no-install-recommends \
        systemd systemd-sysv dbus libpam-systemd openssh-server sudo ca-certificates iproute2 procps \
      && rm -rf /var/lib/apt/lists/*; \
    else \
      apt-get update && apt-get install -y --no-install-recommends \
      systemd systemd-sysv dbus libpam-systemd openssh-server sudo rsync curl ca-certificates \
      gnupg xz-utils util-linux iproute2 procps less nftables openssl cron at \
 && if [ "$CADDY" = upstream ]; then \
      curl -fsSL https://dl.cloudsmith.io/public/caddy/stable/gpg.key \
        | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg \
   && curl -fsSL https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt \
        > /etc/apt/sources.list.d/caddy-stable.list; fi \
 && apt-get update && apt-get install -y --no-install-recommends caddy \
 && rm -rf /var/lib/apt/lists/*; fi
# Node 24 from nodejs.org (Ubuntu ships 22): one exact version, checked against the checksums
# written here, so the image is the same whenever it is built and a failure can be reproduced
# the next day. To move to a newer one: change NODE and both sums (SHASUMS256.txt of that version).
# NODE=latest (test/server/up.sh with TANDO_TEST_NODE=latest; the weekly tier) takes the newest
# 24.x instead, checked against the site's own list: that run notices what a new Node breaks.
ARG NODE=24.22.3
ARG NODE_SHA_X64=4f2b175a6d53a5c617a80dba2676238a0688cef28c6da4eba35c7d844e66fcfb
ARG NODE_SHA_ARM64=6e51a2ada00f0011cc266f65d98922b403d7ad88f809ca2aa615a5fe1ce6e86c
RUN [ "$BARE" = 1 ] || { a=$(dpkg --print-architecture); case $a in amd64) a=x64;; esac; \
    if [ "$NODE" = latest ]; then base=https://nodejs.org/dist/latest-v24.x; \
      line=$(curl -fsSL "$base/SHASUMS256.txt" | awk -v a="linux-$a.tar.xz" '$2 ~ a"$"'); \
      sum=${line%% *}; f=${line##* }; \
    else base=https://nodejs.org/dist/v$NODE; f=node-v$NODE-linux-$a.tar.xz; \
      case $a in x64) sum=$NODE_SHA_X64;; arm64) sum=$NODE_SHA_ARM64;; *) echo "no checksum for $a" >&2; exit 1;; esac; fi; \
    [ -n "$sum" ] && [ -n "$f" ] && curl -fsSL -o /tmp/node.tar.xz "$base/$f" \
    && echo "$sum  /tmp/node.tar.xz" | sha256sum -c - \
    && tar -xJf /tmp/node.tar.xz -C /usr/local --strip-components=1 \
      --exclude=CHANGELOG.md --exclude=LICENSE --exclude=README.md && rm -f /tmp/node.tar.xz && node --version; }
# Container trimming: no consoles, udev or kernel module loading. (Further down: the docker image's
# docker-disable-periodic-update goes, so apt's daily jobs run as on a real server: host care judges them.)
RUN systemctl mask getty@tty1.service console-getty.service systemd-udevd.service \
      systemd-udevd-kernel.socket systemd-udevd-control.socket systemd-modules-load.service \
      systemd-remount-fs.service modprobe@.service systemd-binfmt.service proc-sys-fs-binfmt_misc.automount proc-sys-fs-binfmt_misc.mount sys-kernel-debug.mount sys-kernel-tracing.mount \
 && rm -f /etc/ssh/ssh_host_* && truncate -s0 /etc/machine-id \
 && echo LANG=C.UTF-8 > /etc/default/locale
COPY files/ /
RUN if [ "$BARE" = 1 ]; then rm -rf /etc/caddy && systemctl enable testvm-firstboot.service; \
    else systemctl enable testvm-firstboot.service caddy.service && mkdir -p /etc/caddy/tando; fi \
 && rm -f /etc/apt/apt.conf.d/docker-disable-periodic-update \
 && useradd -m -s /bin/bash -G sudo,adm vmadmin && passwd -l vmadmin \
 && echo 'vmadmin ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/vmadmin && chmod 440 /etc/sudoers.d/vmadmin
STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
