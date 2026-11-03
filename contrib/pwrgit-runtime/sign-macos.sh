#!/bin/bash
# Adapted from huntharo/codex .github/workflows/pwragent-release.yml's protected
# apple-signing job and its PwrDrvr temporary-keychain lifecycle.
set -euo pipefail
root="${1:?Pass the final universal runtime directory}"
root="$(cd "$root" && pwd)"
export PYTHONPATH="$(cd "$(dirname "$0")" && pwd)"
: "${CSC_LINK:?Use the established apple-signing Environment certificate}"
: "${CSC_KEY_PASSWORD:?Use the established certificate export password}"
: "${APPLE_API_KEY_BASE64:?Use the established notarization API key}"
: "${APPLE_API_KEY_ID:?Use the established notarization key ID}"
: "${APPLE_API_ISSUER:?Use the established notarization issuer}"
identity='Developer ID Application: PwrDrvr LLC (T44CNHC4UH)'
work="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/pwrgit-signing.XXXXXX")"
keychain="$work/pwrdrvr-release-signing.keychain-db"
keychain_password="$(openssl rand -hex 32)"
security list-keychains -d user > "$work/original-keychains.txt"
cleanup() {
  security delete-keychain "$keychain" >/dev/null 2>&1 || true
  # A subprocess reads the quoted keychain list without shell evaluation.
  python3 - "$work/original-keychains.txt" <<'PY'
import shlex,subprocess,sys
subprocess.run(['security','list-keychains','-d','user','-s',*shlex.split(open(sys.argv[1]).read())],check=False)
PY
  rm -rf "$work"
}
trap cleanup EXIT
certificate_base64="${CSC_LINK#data:application/x-pkcs12;base64,}"
printf '%s' "$certificate_base64" | base64 -D > "$work/certificate.p12"
printf '%s' "$APPLE_API_KEY_BASE64" | base64 -D > "$work/AuthKey.p8"
chmod 600 "$work/certificate.p12" "$work/AuthKey.p8"
security create-keychain -p "$keychain_password" "$keychain"
security set-keychain-settings -lut 21600 "$keychain"
security unlock-keychain -p "$keychain_password" "$keychain"
security list-keychains -d user -s "$keychain"
security import "$work/certificate.p12" -k "$keychain" -P "$CSC_KEY_PASSWORD" -T /usr/bin/codesign
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$keychain_password" "$keychain"
security find-identity -v -p codesigning "$keychain" | grep -F "\"${identity}\""
python3 - "$root" "$keychain" <<'PY'
import json,sys
from pathlib import Path
from runtime import is_macho,run,seal,verify_inventory,write_json
root,keychain=Path(sys.argv[1]),sys.argv[2]
verify_inventory(root)
m=json.loads((root/'pwrgit-build.json').read_text())
assert m['architecture']=='universal' and m['signing']=='ad-hoc'
identity='Developer ID Application: PwrDrvr LLC (T44CNHC4UH)'
signed=[]
for path in sorted(root.rglob('*')):
    if not is_macho(path): continue
    assert set(run(['lipo','-archs',path]).split())=={'arm64','x86_64'}
    run(['codesign','--force','--keychain',keychain,'--options','runtime','--timestamp','--sign',identity,path])
    run(['codesign','--verify','--all-architectures','--strict','--test-requirement','=anchor apple generic and certificate leaf[subject.OU] = "T44CNHC4UH"',path])
    signed.append(path.relative_to(root).as_posix())
assert signed
m.update(signing=identity,notarized=False,signed_executables=signed)
write_json(root/'pwrgit-build.json',m)
seal(root)
PY
ditto -c -k --keepParent "$root" "$work/notarization.zip"
xcrun notarytool submit "$work/notarization.zip" --key "$work/AuthKey.p8" \
  --key-id "$APPLE_API_KEY_ID" --issuer "$APPLE_API_ISSUER" --wait --output-format json > "$work/notarization.json"
python3 - "$root" "$work/notarization.json" <<'PY'
import json,sys
from pathlib import Path
from runtime import seal,verify_inventory,write_json
root=Path(sys.argv[1]); receipt=json.loads(Path(sys.argv[2]).read_text())
assert receipt['status']=='Accepted',receipt
# Prove submission did not change any payload byte or signature.
verify_inventory(root)
m=json.loads((root/'pwrgit-build.json').read_text())
m.update(notarized=True,notarization_id=receipt['id'])
write_json(root/'pwrgit-build.json',m)
write_json(root/'notarization.json',receipt)
seal(root)
PY
python3 "$(dirname "$0")/verify.py" "$root" --require-signed
