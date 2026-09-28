# Ubuntu 24.04 with systemd, close to a Jelastic Ubuntu VPS node. Used only for tests.
FROM ubuntu:24.04
RUN apt-get update && apt-get install -y --no-install-recommends systemd systemd-sysv dbus curl ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && systemctl mask systemd-logind.service getty.target console-getty.service
STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
