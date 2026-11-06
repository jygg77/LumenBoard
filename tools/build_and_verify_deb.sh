#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
: "${THEOS:?Set THEOS to a verified Theos installation with an iOS SDK and a host-compatible toolchain}"

if [[ ! -f "$THEOS/makefiles/common.mk" ]]; then
  echo "ERROR: missing $THEOS/makefiles/common.mk" >&2
  exit 2
fi
if command -v xcrun >/dev/null 2>&1; then
  if ! xcrun --find clang >/dev/null 2>&1; then
    echo "ERROR: Xcode clang is unavailable through xcrun" >&2
    exit 3
  fi
elif [[ ! -x "$THEOS/toolchain/linux/iphone/bin/clang" ]]; then
  echo "ERROR: neither Xcode clang nor the Theos Linux iOS clang toolchain is available" >&2
  exit 3
fi
if ! find "$THEOS/sdks" -maxdepth 1 -type d -name 'iPhoneOS*.sdk' -print -quit 2>/dev/null | grep -q .; then
  echo "ERROR: no iPhoneOS SDK found under $THEOS/sdks" >&2
  exit 4
fi

cd "$PROJECT_DIR"
build_out="$(mktemp -d "${TMPDIR:-/tmp}/lumenboard-packages.XXXXXX")"
stage=""
trap 'if [[ -n "${stage:-}" ]]; then rm -rf "$stage"; fi; rm -rf "$build_out"' EXIT
THEOS_PACKAGE_SCHEME=rootless THEOS_PACKAGE_DIR="$build_out" make clean package FINALPACKAGE=1

shopt -s nullglob
debs=("$build_out"/*.deb)
if [[ ${#debs[@]} -ne 1 ]]; then
  echo "ERROR: expected exactly one newly generated .deb, found ${#debs[@]}" >&2
  printf '  %s\n' "${debs[@]:-<none>}" >&2
  exit 5
fi
deb="${debs[0]}"
"$PROJECT_DIR/tools/normalize_deb_ownership.sh" "$deb"
echo "=== dpkg-deb --info ==="
dpkg-deb --info "$deb"
arch="$(dpkg-deb -f "$deb" Architecture)"
pkg="$(dpkg-deb -f "$deb" Package)"
version="$(dpkg-deb -f "$deb" Version)"
if [[ "$version" != "0.1.0-21" ]]; then
  echo "ERROR: expected package version 0.1.0-21; got '$version'" >&2
  exit 13
fi
if [[ "$arch" != "iphoneos-arm64" ]]; then
  echo "ERROR: expected Architecture: iphoneos-arm64; got '$arch'" >&2
  exit 6
fi
if [[ "$pkg" != "com.iuyghi.lumenboard" ]]; then
  echo "ERROR: unexpected package name '$pkg'" >&2
  exit 7
fi

stage="$(mktemp -d "${TMPDIR:-/tmp}/lumenboard-stage.XXXXXX")"
dpkg-deb -x "$deb" "$stage"
plist="$stage/var/jb/Library/PreferenceLoader/Preferences/LumenBoard.plist"
bundle="$stage/var/jb/Library/PreferenceBundles/LumenBoardPrefs.bundle"
if [[ ! -f "$plist" ]]; then
  echo "ERROR: missing rootless PreferenceLoader entry: $plist" >&2
  exit 8
fi
if [[ ! -d "$bundle" ]]; then
  echo "ERROR: missing rootless preference bundle: $bundle" >&2
  exit 9
fi
if [[ ! -f "$bundle/LumenBoardPrefs" ]]; then
  echo "ERROR: missing compiled bundle executable: $bundle/LumenBoardPrefs" >&2
  exit 10
fi
if ! file "$bundle/LumenBoardPrefs" | grep -Eiq 'Mach-O.*arm64|Mach-O universal'; then
  echo "ERROR: bundle executable is not identified as an arm64 Mach-O binary" >&2
  file "$bundle/LumenBoardPrefs" >&2 || true
  exit 11
fi

info_plist="$bundle/Info.plist"
if [[ ! -f "$info_plist" ]]; then
  echo "ERROR: missing required Preferences bundle Info.plist: $info_plist" >&2
  exit 14
fi
python3 - "$info_plist" <<'PY'
import plistlib, sys
with open(sys.argv[1], "rb") as stream:
    info = plistlib.load(stream)
expected = {
    "CFBundleIdentifier": "com.iuyghi.lumenboard.preferences",
    "CFBundleExecutable": "LumenBoardPrefs",
    "CFBundlePackageType": "BNDL",
    "CFBundleVersion": "21",
    "NSPrincipalClass": "LumenBoardRootListController",
}
for key, value in expected.items():
    if info.get(key) != value:
        raise SystemExit(f"ERROR: Preferences Info.plist {key} must be {value!r}, got {info.get(key)!r}")
PY

daemon="$stage/var/jb/usr/libexec/lumenboardd"
if [[ ! -x "$daemon" ]] || ! file "$daemon" | grep -Eiq 'Mach-O.*arm64'; then
  echo "ERROR: rootless daemon is missing, not executable, or not an arm64 Mach-O binary" >&2
  file "$daemon" >&2 || true
  exit 15
fi

control_dir="$stage/control"
dpkg-deb -e "$deb" "$control_dir"
for script in postinst prerm; do
  if [[ ! -x "$control_dir/$script" ]]; then
    echo "ERROR: maintainer script is not executable in control archive: $script" >&2
    exit 16
  fi
  sh -n "$control_dir/$script"
done

echo "=== package fields ==="
printf 'Package: %s\nArchitecture: %s\nVersion: %s\nDepends: %s\n' \
  "$pkg" "$arch" "$version" "$(dpkg-deb -f "$deb" Depends)"
echo "=== package contents ==="
dpkg-deb --contents "$deb"
echo "=== compiled executable ==="
file "$bundle/LumenBoardPrefs"
mkdir -p "$PROJECT_DIR/packages"
final_deb="$PROJECT_DIR/packages/$(basename "$deb")"
if [[ -e "$final_deb" ]]; then
  echo "ERROR: refusing to overwrite existing package: $final_deb" >&2
  exit 12
fi
cp -p "$deb" "$final_deb"
echo "=== SHA-256 ==="
if command -v shasum >/dev/null 2>&1; then
  shasum -a 256 "$final_deb"
elif command -v sha256sum >/dev/null 2>&1; then
  sha256sum "$final_deb"
else
  echo "ERROR: neither shasum nor sha256sum is available" >&2
  exit 17
fi
echo "=== Verified artifact ==="
printf '%s\n' "$final_deb"
echo "=== Verification result ==="
echo "PASS: Debian archive metadata, rootless preference paths, and Mach-O executable verified. This does not test installation or PosterBoard runtime compatibility."