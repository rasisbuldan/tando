# Throwaway "VPS" for tando tests: Ubuntu + systemd as PID 1, sshd, sudo, Caddy, Node, rsync.
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
      gnupg xz-utils util-linux iproute2 procps less \
 && if [ "$CADDY" = upstream ]; then \
      curl -fsSL https://dl.cloudsmith.io/public/caddy/stable/gpg.key \
        | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg \
   && curl -fsSL https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt \
        > /etc/apt/sources.list.d/caddy-stable.list; fi \
 && apt-get update && apt-get install -y --no-install-recommends caddy \
 && rm -rf /var/lib/apt/lists/*; fi
# Node 24 from nodejs.org (Ubuntu ships 22).
RUN [ "$BARE" = 1 ] || { a=$(dpkg --print-architecture); case $a in amd64) a=x64;; esac; \
    f=$(curl -fsSL https://nodejs.org/dist/latest-v24.x/SHASUMS256.txt | awk -v a="linux-$a.tar.xz" '$2 ~ a"$" {print $2}'); \
    curl -fsSL "https://nodejs.org/dist/latest-v24.x/$f" | tar -xJ -C /usr/local --strip-components=1 \
      --exclude=CHANGELOG.md --exclude=LICENSE --exclude=README.md && node --version; }
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
