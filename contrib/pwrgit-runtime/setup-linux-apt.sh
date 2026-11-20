#!/bin/bash
# Run only inside the disposable Ubuntu build/test container.
set -euo pipefail
snapshot="${1:?Pass the pinned Ubuntu snapshot timestamp}"
ca=/run/pwrgit-apt-ca.pem
if [[ ! "$snapshot" =~ ^[0-9]{8}T[0-9]{6}Z$ || ! -s "$ca" ]]; then
  echo 'Expected a pinned snapshot timestamp and the mounted bootstrap CA bundle' >&2
  exit 1
fi
rm -f /etc/apt/sources.list.d/*
cat > /etc/apt/sources.list <<EOF
deb [check-valid-until=no] https://snapshot.ubuntu.com/ubuntu/$snapshot jammy main universe
deb [check-valid-until=no] https://snapshot.ubuntu.com/ubuntu/$snapshot jammy-updates main universe
deb [check-valid-until=no] https://snapshot.ubuntu.com/ubuntu/$snapshot jammy-security main universe
deb-src [check-valid-until=no] https://snapshot.ubuntu.com/ubuntu/$snapshot jammy main universe
deb-src [check-valid-until=no] https://snapshot.ubuntu.com/ubuntu/$snapshot jammy-updates main universe
deb-src [check-valid-until=no] https://snapshot.ubuntu.com/ubuntu/$snapshot jammy-security main universe
EOF
# Establish HTTPS trust without running any install against live mirrors.
# Ubuntu's archive keyring still authenticates the snapshot metadata.
printf 'Acquire::https::CAInfo "%s";\n' "$ca" > /etc/apt/apt.conf.d/99pwrgit-snapshot
apt-get -o APT::Update::Error-Mode=any update
