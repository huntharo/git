#!/bin/bash
set -euo pipefail
arch="${1:?Pass x64 or arm64}"
snapshot="${2:?Pass the pinned Ubuntu snapshot timestamp}"
rm -f /etc/apt/sources.list.d/*
cat > /etc/apt/sources.list <<EOF
deb [check-valid-until=no] https://snapshot.ubuntu.com/ubuntu/$snapshot jammy main universe
deb [check-valid-until=no] https://snapshot.ubuntu.com/ubuntu/$snapshot jammy-updates main universe
deb [check-valid-until=no] https://snapshot.ubuntu.com/ubuntu/$snapshot jammy-security main universe
deb-src [check-valid-until=no] https://snapshot.ubuntu.com/ubuntu/$snapshot jammy main universe
deb-src [check-valid-until=no] https://snapshot.ubuntu.com/ubuntu/$snapshot jammy-updates main universe
deb-src [check-valid-until=no] https://snapshot.ubuntu.com/ubuntu/$snapshot jammy-security main universe
EOF
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
  build-essential git python3 libcurl4-openssl-dev libexpat1-dev zlib1g-dev libssl-dev \
  ca-certificates patchelf binutils dpkg-dev xz-utils
git config --global --add safe.directory /src
cd /src
export PYTHONDONTWRITEBYTECODE=1
python3 contrib/pwrgit-runtime/build.py --arch "$arch" --output /out/build
mkdir '/out/relocated runtime'
tar -xzf /out/build/*-candidate.tar.gz -C '/out/relocated runtime'
python3 contrib/pwrgit-runtime/verify.py '/out/relocated runtime' --report /out/verify.json
python3 contrib/pwrgit-runtime/smoke.py '/out/relocated runtime' \
  --test-tool /out/build/source/t/helper/test-tool --https --report /out/smoke.json
cd /out/build/source/t
for suite in t241[0-4]-*.sh; do ./$suite; done
