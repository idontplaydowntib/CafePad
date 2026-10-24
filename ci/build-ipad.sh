#!/bin/bash
# Build the current CafePad source checkout using Xcode on macOS.
# Produces build-ios/package/CafePad-unsigned.ipa; it does not sign or publish.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
if [ "$(uname -s)" != Darwin ]; then
  echo 'error: the iOS build requires macOS and full Xcode (the GitHub xcode-27 runner is supported).' >&2
  exit 1
fi
for tool in xcodebuild xcrun xcodegen cmake ninja python3; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "error: missing build tool: $tool" >&2
    exit 1
  fi
done

BUILD="$ROOT/build-ios"
LOGS="$BUILD/logs"
PACKAGE="$BUILD/package"
mkdir -p "$LOGS" "$PACKAGE"
SOURCE_COMMIT="$(git rev-parse HEAD)"
SOURCE_DIRTY=false
if [ -n "$(git status --porcelain --untracked-files=normal)" ]; then SOURCE_DIRTY=true; fi
export SOURCE_COMMIT SOURCE_DIRTY
git submodule status --recursive > "$LOGS/submodules.txt"
if grep -Eq '^[-+U]' "$LOGS/submodules.txt"; then
  echo 'error: submodules are missing, conflicted or differ from the committed versions; initialize the pinned submodules first.' >&2
  exit 1
fi
printf '%s\n' "$SOURCE_COMMIT" > "$LOGS/source-commit.txt"
xcodebuild -version | tee "$LOGS/xcode.txt"
xcrun --sdk iphoneos --show-sdk-version | tee "$LOGS/ios-sdk.txt"
cmake --version > "$LOGS/cmake.txt"
xcodegen --version > "$LOGS/xcodegen.txt"

# Xcode's post-build scripts must also work after an archive-based source copy.
chmod +x "$ROOT"/ci/*.sh

echo 'Building the pinned StikJIT dependency...'
bash ci/build-stikjit.sh 2>&1 | tee "$LOGS/stikjit.log"
cp dependencies/.stikjit-commit "$LOGS/stikjit-commit.txt"
shasum -a 256 \
  dependencies/idevice/libidevice_ffi.a \
  dependencies/MoltenVK.xcframework/ios-arm64/MoltenVK.framework/MoltenVK \
  dependencies/MoltenVK128.framework/MoltenVK128 > "$LOGS/dependency-sha256.txt"

echo 'Compiling the real Cemu core for iOS arm64...'
cmake -S . -B "$BUILD" -G Ninja \
  -DCMAKE_SYSTEM_NAME=iOS \
  -DCMAKE_OSX_SYSROOT=iphoneos \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=17.4 \
  -DVCPKG_TARGET_TRIPLET=arm64-ios \
  -DBUILD_HEADLESS_DYLIB=ON \
  -DCMAKE_MACOSX_BUNDLE=OFF \
  -DCMAKE_BUILD_TYPE=Release 2>&1 | tee "$LOGS/core-configure.log"
cmake --build "$BUILD" --target CemuBin --parallel "${CAFEPAD_BUILD_JOBS:-3}" \
  2>&1 | tee "$LOGS/core-build.log"

# CMake's Apple framework output depends on the runtime/output settings. Check
# known build-product locations only, never a stale cache or an arbitrary find.
CORE=''
for candidate in \
  "$BUILD/src/Cemu.framework" \
  "$ROOT/bin/Cemu.framework" \
  "$BUILD/bin/Cemu.framework" \
  "$BUILD/Cemu.framework"; do
  if [ -f "$candidate/Cemu" ] && [ -f "$candidate/Info.plist" ]; then
    if [ -n "$CORE" ]; then
      echo "error: more than one Cemu framework build product exists ($CORE and $candidate); use a clean source checkout." >&2
      exit 1
    fi
    CORE="$candidate"
  fi
done
if [ -z "$CORE" ]; then
  echo 'error: the Cemu build did not produce a framework in any known output location.' >&2
  exit 1
fi
mkdir -p "$BUILD/out"
# This is a fixed build-output path under the checked-out source tree.
if [ -d "$BUILD/out/Cemu.framework" ]; then rm -rf "$BUILD/out/Cemu.framework"; fi
ditto "$CORE" "$BUILD/out/Cemu.framework"
lipo -verify_arch arm64 "$BUILD/out/Cemu.framework/Cemu"
xcrun nm -gU "$BUILD/out/Cemu.framework/Cemu" > "$LOGS/core-exports.txt"
grep -q '_cemu_bridge_core_available' "$LOGS/core-exports.txt"
grep -q '_cemu_bridge_initialize' "$LOGS/core-exports.txt"
xcrun otool -L "$BUILD/out/Cemu.framework/Cemu" > "$LOGS/core-libraries.txt"

echo 'Building the app, touch controls and local JIT helper...'
(cd src/ios && xcodegen generate) 2>&1 | tee "$LOGS/xcodegen.log"
xcodebuild \
  -project src/ios/EspressU.xcodeproj \
  -scheme EspressU \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  -configuration Release \
  -derivedDataPath "$BUILD/app" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  build 2>&1 | tee "$LOGS/app-build.log"

APP="$BUILD/app/Build/Products/Release-iphoneos/EspressU.app"
export APP LOGS PACKAGE
test -f "$APP/EspressU"
test -f "$APP/Frameworks/Cemu.framework/Cemu"
test -f "$APP/Frameworks/StikJIT.framework/StikJIT"
test -f "$APP/PlugIns/StikJITHelper.appex/StikJITHelper"
test -d "$APP/CemuData/resources/sharedFonts"
test -d "$APP/CemuData/gameProfiles"
test -s "$APP/CemuData/graphicPacks/CafePad_NSMBU_CrashFix/rules.txt"
test -s "$APP/CemuData/graphicPacks/CafePad_NSMBU_CrashFix/patch_CrashFix.asm"
for binary in "$APP/EspressU" "$APP/Frameworks/Cemu.framework/Cemu" \
  "$APP/Frameworks/StikJIT.framework/StikJIT" \
  "$APP/PlugIns/StikJITHelper.appex/StikJITHelper"; do
  lipo -verify_arch arm64 "$binary"
done
plutil -lint "$APP/Info.plist" "$APP/PlugIns/StikJITHelper.appex/Info.plist"

# Stamp the actual checked-out commit after compilation. A plist stamp is build
# provenance, not a claim of physical-device testing or game compatibility.
python3 - <<'PY'
import datetime
import json
import os
import pathlib
import plistlib

app = pathlib.Path(os.environ['APP'])
logs = pathlib.Path(os.environ['LOGS'])
package = pathlib.Path(os.environ['PACKAGE'])
info_path = app / 'Info.plist'
with info_path.open('rb') as source:
    info = plistlib.load(source)
with (app / 'PlugIns/StikJITHelper.appex/Info.plist').open('rb') as source:
    helper = plistlib.load(source)
if info.get('CFBundleIdentifier') != 'org.cafepad.emulator':
    raise SystemExit('App bundle identifier is not the CafePad fork identifier')
if info.get('CFBundleDisplayName') != 'CafePad':
    raise SystemExit('App display name is not CafePad')
if not helper.get('CFBundleIdentifier', '').startswith(info['CFBundleIdentifier'] + '.'):
    raise SystemExit('JIT helper bundle identifier does not belong to the host app')
provenance = {
    'product': 'CafePad',
    'source_repository': os.environ.get('GITHUB_REPOSITORY', 'local checkout'),
    'source_commit': os.environ['SOURCE_COMMIT'],
    'source_dirty': os.environ['SOURCE_DIRTY'] == 'true',
    'upstream_repository': 'EspressU/EspressU-Emu',
    'upstream_commit': 'eb6779ce2ed9022d563b167517e508a7b25c6ac9',
    'stikjit_commit': (logs / 'stikjit-commit.txt').read_text().strip(),
    'build_utc': datetime.datetime.now(datetime.timezone.utc).isoformat(),
    'xcode': (logs / 'xcode.txt').read_text().strip(),
    'ios_sdk': (logs / 'ios-sdk.txt').read_text().strip(),
    'cmake': (logs / 'cmake.txt').read_text().strip(),
    'xcodegen': (logs / 'xcodegen.txt').read_text().strip(),
    'submodules': (logs / 'submodules.txt').read_text().splitlines(),
    'dependency_sha256': (logs / 'dependency-sha256.txt').read_text().splitlines(),
    'physical_device_tested': False,
}
run_id = os.environ.get('GITHUB_RUN_ID')
if run_id:
    provenance['build_run'] = (
        f"{os.environ.get('GITHUB_SERVER_URL', 'https://github.com')}/"
        f"{os.environ['GITHUB_REPOSITORY']}/actions/runs/{run_id}"
    )
info['CafePadSourceCommit'] = provenance['source_commit']
info['CafePadSourceDirty'] = provenance['source_dirty']
info['CafePadSourceRepository'] = provenance['source_repository']
info['CafePadUpstreamCommit'] = provenance['upstream_commit']
info['CafePadBuildUTC'] = provenance['build_utc']
if 'build_run' in provenance:
    info['CafePadBuildRun'] = provenance['build_run']
with info_path.open('wb') as destination:
    plistlib.dump(info, destination, fmt=plistlib.FMT_BINARY)
(package / 'build-provenance.json').write_text(
    json.dumps(provenance, indent=2) + '\n', encoding='utf-8'
)
PY

# Use a new staging directory and a new archive each time. zip's update mode
# would otherwise retain files removed by a later build.
STAGE="$(mktemp -d "$BUILD/package-stage.XXXXXX")"
mkdir -p "$STAGE/Payload"
ditto "$APP" "$STAGE/Payload/EspressU.app"
rm -f "$PACKAGE/CafePad-unsigned.ipa"
(cd "$STAGE" && /usr/bin/zip -qry "$PACKAGE/CafePad-unsigned.ipa" Payload)
unzip -tq "$PACKAGE/CafePad-unsigned.ipa"
(cd "$PACKAGE" && shasum -a 256 CafePad-unsigned.ipa > SHA256SUMS.txt)
printf '%s\n' \
  'CafePad unsigned iOS arm64 build. Sign and sideload it with your own Apple account.' \
  'Sign the app and all nested frameworks/extensions. Preserve get-task-allow, increased-memory-limit and extended-virtual-addressing entitlements where supported.' \
  'Local JIT requires Developer Mode, a device pairing file and an active LocalDevVPN connection.' \
  'Compilation and archive checks do not establish game compatibility or performance on a physical iPad.' \
  'The core and app compile from public source. StikJIT reuses a vendored idevice library, and MoltenVK is vendored.' \
  'Hosted tooling and timestamps can change; this is a rebuildable procedure, not a guarantee of byte-identical artifacts.' \
  > "$PACKAGE/BUILD-NOTES.txt"
echo "Unsigned build packaged: $PACKAGE/CafePad-unsigned.ipa"
