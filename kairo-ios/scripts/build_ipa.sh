#!/bin/bash
# Build an unsigned device IPA for AltStore to sign with the user's account.
set -euo pipefail
kairo_root=$(cd "$(dirname "$0")/.." && pwd)
kairo_output=${1:-"$kairo_root/build/ipa"}
mkdir -p "$kairo_output"
kairo_output=$(cd "$kairo_output" && pwd)
kairo_temp=$(mktemp -d "${TMPDIR:-/tmp}/kairo-ipa.XXXXXX")
trap 'rm -rf "$kairo_temp"' EXIT

xcodebuild archive \
  -project "$kairo_root/Kairo.xcodeproj" -scheme Kairo \
  -configuration Release -destination 'generic/platform=iOS' \
  -archivePath "$kairo_temp/Kairo.xcarchive" \
  -derivedDataPath "$kairo_temp/DerivedData" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO

mkdir -p "$kairo_temp/Payload"
ditto "$kairo_temp/Kairo.xcarchive/Products/Applications/Kairo.app" "$kairo_temp/Payload/Kairo.app"
python3 - "$kairo_temp/Payload/Kairo.app" <<'PY'
import pathlib, plistlib, re, subprocess, sys
app = pathlib.Path(sys.argv[1])
with (app / 'Info.plist').open('rb') as handle:
    info = plistlib.load(handle)
assert info['CFBundleSupportedPlatforms'] == ['iPhoneOS'], 'Expected a device build'
assert info['CFBundleIdentifier'] == 'net.kusapo.kairo'
executable = app / info['CFBundleExecutable']
archs = subprocess.check_output(['xcrun', 'lipo', '-archs', str(executable)], text=True).split()
assert archs == ['arm64'], f'Unexpected architectures: {archs}'
platform = subprocess.check_output(['xcrun', 'vtool', '-show-build', str(executable)], text=True)
assert re.search(r'platform\s+IOS\s', platform), platform
assert not list(app.rglob('*.xctest')), 'Test bundle included in app'
print(f"Verified device app: {info['CFBundleIdentifier']}, iOS {info['MinimumOSVersion']}+, {archs}")
PY
ditto -c -k --keepParent "$kairo_temp/Payload" "$kairo_output/Kairo.ipa"
python3 - "$kairo_output/Kairo.ipa" <<'PY'
import hashlib, pathlib, sys, zipfile
ipa = pathlib.Path(sys.argv[1])
with zipfile.ZipFile(ipa) as archive:
    assert archive.testzip() is None
    assert 'Payload/Kairo.app/Kairo' in archive.namelist()
    assert 'Payload/Kairo.app/Info.plist' in archive.namelist()
digest = hashlib.sha256(ipa.read_bytes()).hexdigest()
ipa.with_suffix('.ipa.sha256').write_text(f'{digest}  {ipa.name}\n')
print(f'Packaged {ipa.name}: {ipa.stat().st_size} bytes; SHA256 {digest}')
PY
