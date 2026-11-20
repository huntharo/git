#!/bin/bash
set -euo pipefail
arch="${1:?Pass x64 or arm64}"
snapshot="${2:?Pass the pinned Ubuntu snapshot timestamp}"
bash /src/contrib/pwrgit-runtime/setup-linux-apt.sh "$snapshot"
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
  build-essential git python3 libcurl4-openssl-dev libexpat1-dev zlib1g-dev libssl-dev \
  ca-certificates patchelf binutils dpkg-dev xz-utils
git config --global --add safe.directory /src
cd /src
export PYTHONDONTWRITEBYTECODE=1
python3 -m unittest discover -s contrib/pwrgit-runtime -p test_runtime.py
python3 contrib/pwrgit-runtime/build.py --arch "$arch" --output /out/build
mkdir '/out/relocated runtime'
tar -xzf /out/build/*-candidate.tar.gz -C '/out/relocated runtime'
python3 contrib/pwrgit-runtime/verify.py '/out/relocated runtime' --report /out/verify.json
python3 contrib/pwrgit-runtime/smoke.py '/out/relocated runtime' \
  --test-tool /out/build/source/t/helper/test-tool --https --report /out/smoke.json
cd /out/build/source/t
for suite in t241[0-7]-*.sh; do ./$suite; done
PATH="/out/relocated runtime/bin:$PATH" GIT_TEST_REQUIRE_PREREQ='GIT_LFS_FILE_TRANSPORT SHA256SUM' \
  ./t2419-reflink-lfs.sh
