# tando bench server (copy of test/server/Dockerfile): Ubuntu + systemd as PID 1, sshd, sudo, Caddy, Node, rsync.
ARG UBUNTU=26.04
FROM ubuntu:${UBUNTU}
ENV DEBIAN_FRONTEND=noninteractive container=docker
RUN apt-get update && apt-get install -y --no-install-recommends \
      systemd systemd-sysv dbus libpam-systemd openssh-server sudo rsync curl ca-certificates \
      gnupg xz-utils util-linux iproute2 procps less \
 && curl -fsSL https://dl.cloudsmith.io/public/caddy/stable/gpg.key \
      | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg \
 && curl -fsSL https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt \
      > /etc/apt/sources.list.d/caddy-stable.list \
 && apt-get update && apt-get install -y --no-install-recommends caddy \
 && rm -rf /var/lib/apt/lists/*
# Node 24 from nodejs.org (Ubuntu ships 22).
RUN a=$(dpkg --print-architecture); case $a in amd64) a=x64;; esac; \
    f=$(curl -fsSL https://nodejs.org/dist/latest-v24.x/SHASUMS256.txt | awk -v a="linux-$a.tar.xz" '$2 ~ a"$" {print $2}'); \
    curl -fsSL "https://nodejs.org/dist/latest-v24.x/$f" | tar -xJ -C /usr/local --strip-components=1 \
      --exclude=CHANGELOG.md --exclude=LICENSE --exclude=README.md && node --version
# Container trimming: no consoles, udev or kernel module loading.
RUN systemctl mask getty@tty1.service console-getty.service systemd-udevd.service \
      systemd-udevd-kernel.socket systemd-udevd-control.socket systemd-modules-load.service \
      systemd-remount-fs.service modprobe@.service sys-kernel-debug.mount sys-kernel-tracing.mount \
 && rm -f /etc/ssh/ssh_host_* && truncate -s0 /etc/machine-id \
 && echo LANG=C.UTF-8 > /etc/default/locale
COPY files/ /
RUN systemctl enable testvm-firstboot.service caddy.service \
 && mkdir -p /etc/caddy/tando \
 && useradd -m -s /bin/bash -G sudo,adm vmadmin && passwd -l vmadmin \
 && echo 'vmadmin ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/vmadmin && chmod 440 /etc/sudoers.d/vmadmin
STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
