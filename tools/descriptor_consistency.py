#!/usr/bin/env python3
"""Read-only structural checks for a PosterForge-shaped iOS 16 descriptor tree.

This tool checks local metadata and file-reference consistency only. It does not
establish that Apple's private PosterBoard renderer accepts or displays a descriptor.
It never writes to the tree or touches an iOS app container.
"""
from __future__ import annotations

import argparse
import json
import plistlib
import re
import stat
import sys
from urllib.parse import unquote
import xml.etree.ElementTree as ET
from pathlib import Path, PurePosixPath
from typing import Any

MAX_FILES = 20_000
MAX_BYTES = 2 * 1024 * 1024 * 1024
ASSET_REF_RE = re.compile(r"assets/[A-Za-z0-9_.%*?/-]+")
FRAME_PATTERN_RE = re.compile(r"%0?\d*d")


class ConsistencyError(ValueError):
    """The input is not safe to inspect or violates the observed descriptor profile."""


def _safe_component(value: Any, field: str) -> str:
    if not isinstance(value, str) or not value or value in {".", ".."} or "/" in value or "\\" in value or "\x00" in value:
        raise ConsistencyError(f"{field} must be a non-empty single path component")
    return value


def _read_plist(path: Path, label: str, errors: list[str]) -> Any | None:
    try:
        data = path.read_bytes()
        return plistlib.loads(data)
    except (OSError, plistlib.InvalidFileException, ValueError, TypeError) as exc:
        errors.append(f"{label}: cannot parse plist: {exc}")
        return None


def _walk_safety(root: Path, report: dict[str, Any]) -> None:
    count = 0
    total = 0
    for entry in root.rglob("*"):
        if entry.is_symlink():
            report["errors"].append(f"symlink rejected: {entry.relative_to(root).as_posix()}")
            continue
        try:
            mode = entry.lstat().st_mode
        except OSError as exc:
            report["errors"].append(f"cannot stat {entry.relative_to(root)}: {exc}")
            continue
        if stat.S_ISDIR(mode):
            continue
        if not stat.S_ISREG(mode):
            report["errors"].append(f"non-regular entry rejected: {entry.relative_to(root).as_posix()}")
            continue
        count += 1
        total += entry.stat().st_size
        if count > MAX_FILES or total > MAX_BYTES:
            report["errors"].append("descriptor tree exceeds file-count or total-size limit")
            break
    report["files_checked"] = count
    report["bytes_checked"] = total


def _reference_paths(text: str) -> list[str]:
    found = []
    for match in ASSET_REF_RE.findall(text):
        candidate = match.rstrip(".,;:)}]")
        if candidate not in found:
            found.append(candidate)
    return found


def _check_asset_references(ca_dir: Path, report: dict[str, Any], label: str) -> None:
    assets = ca_dir / "assets"
    for caml in (ca_dir / "main.caml", ca_dir / "assetManifest.caml"):
        if not caml.is_file():
            # A generated empty layer in the inspected PosterForge source omits the
            # asset manifest; report this as uncertain instead of silently blessing it.
            if caml.name == "assetManifest.caml":
                index = ca_dir / "index.xml"
                index_data = _read_plist(index, f"{label}/index.xml", report["errors"]) if index.is_file() else None
                if isinstance(index_data, dict) and isinstance(index_data.get("assetManifest"), str):
                    report["warnings"].append(f"{label}: index.xml declares {index_data['assetManifest']!r}, but that file is absent; renderer tolerance is unverified")
            else:
                report["errors"].append(f"{label}: missing main.caml")
            continue
        try:
            data = caml.read_bytes()
            text = data.decode("utf-8")
        except (OSError, UnicodeDecodeError) as exc:
            report["errors"].append(f"{label}/{caml.name}: unreadable UTF-8 CAML: {exc}")
            continue
        try:
            ET.fromstring(text)
        except ET.ParseError as exc:
            report["errors"].append(f"{label}/{caml.name}: CAML is not well-formed XML: {exc}")
            continue
        if "assets\\" in text:
            report["errors"].append(f"{label}/{caml.name}: backslash-style asset reference is not accepted")
        for raw_ref in _reference_paths(text):
            try:
                decoded_ref = unquote(raw_ref)
                raw_parts = decoded_ref.split("/")
                rel = PurePosixPath(decoded_ref)
                if rel.is_absolute() or any(part in {"", ".", ".."} for part in raw_parts) or "\\" in decoded_ref:
                    report["errors"].append(f"{label}/{caml.name}: unsafe asset reference {raw_ref!r}")
                    continue
                if not rel.parts or rel.parts[0] != "assets" or len(rel.parts) < 2:
                    report["errors"].append(f"{label}/{caml.name}: unsupported asset reference {raw_ref!r}")
                    continue
                name = rel.name
                if FRAME_PATTERN_RE.search(name):
                    glob_name = FRAME_PATTERN_RE.sub("*", name)
                    matches = list((assets / Path(*rel.parts[1:-1])).glob(glob_name)) if assets.is_dir() else []
                    if not matches:
                        report["errors"].append(f"{label}/{caml.name}: frame pattern {raw_ref!r} matches no assets")
                elif not (ca_dir / Path(*rel.parts)).is_file():
                    report["errors"].append(f"{label}/{caml.name}: referenced asset is missing: {raw_ref}")
            except (OSError, ValueError) as exc:
                report["errors"].append(f"{label}/{caml.name}: invalid asset reference {raw_ref!r}: {exc}")


def _validate_one(descriptor: Path, report: dict[str, Any], seen_descriptor_ids: set[str], seen_wallpaper_ids: set[int], expected_screen_class: str | None = None) -> dict[str, Any] | None:
    root_label = descriptor.name
    before_errors = len(report["errors"])
    if descriptor.is_symlink() or not descriptor.is_dir():
        report["errors"].append(f"{root_label}: descriptor entry is not a real directory")
        return None

    required_root = [
        "com.apple.posterkit.provider.descriptor.identifier",
        "com.apple.posterkit.role.identifier",
        "providerInfo.plist",
    ]
    for name in required_root:
        if not (descriptor / name).is_file():
            report["errors"].append(f"{root_label}: missing root metadata {name}")

    identifier_path = descriptor / required_root[0]
    numeric_id = None
    try:
        numeric_id = identifier_path.read_text(encoding="utf-8").strip()
        if not numeric_id.isdecimal():
            report["errors"].append(f"{root_label}: descriptor identifier is not a decimal string as written by PosterForge")
            numeric_id = None
        elif numeric_id in seen_descriptor_ids:
            report["errors"].append(f"{root_label}: duplicate descriptor identifier {numeric_id}")
        else:
            seen_descriptor_ids.add(numeric_id)
    except OSError as exc:
        report["errors"].append(f"{root_label}: cannot read descriptor identifier: {exc}")

    role_path = descriptor / "com.apple.posterkit.role.identifier"
    role_value = None
    if role_path.is_file():
        try:
            role_value = role_path.read_text(encoding="utf-8").strip()
            if not role_value:
                report["errors"].append(f"{root_label}: role identifier is empty")
        except (OSError, UnicodeDecodeError) as exc:
            report["errors"].append(f"{root_label}: cannot read role identifier: {exc}")

    provider_info_path = descriptor / "providerInfo.plist"
    if provider_info_path.is_file():
        _read_plist(provider_info_path, f"{root_label}/providerInfo.plist", report["errors"])

    contents = descriptor / "versions" / "1" / "contents"
    if not contents.is_dir() or contents.is_symlink():
        report["errors"].append(f"{root_label}: missing versions/1/contents")
        return None
    bundles = sorted(p for p in contents.iterdir() if p.name.endswith(".wallpaper"))
    if len(bundles) != 1:
        report["errors"].append(f"{root_label}: expected exactly one .wallpaper bundle from the observed PosterForge installItem path; found {len(bundles)}")
        return None
    wallpaper = bundles[0]
    if wallpaper.is_symlink() or not wallpaper.is_dir():
        report["errors"].append(f"{root_label}: wallpaper bundle is not a real directory")
        return None
    metadata = _read_plist(wallpaper / "Wallpaper.plist", f"{root_label}/{wallpaper.name}/Wallpaper.plist", report["errors"])
    if not isinstance(metadata, dict):
        report["errors"].append(f"{root_label}: Wallpaper.plist root is not a dictionary")
        return None

    logical_screen_class = metadata.get("logicalScreenClass")
    if not isinstance(logical_screen_class, str) or not re.fullmatch(r"[1-9][0-9]*w-[1-9][0-9]*h@[1-9][0-9]*x~[A-Za-z0-9_-]+", logical_screen_class):
        report["errors"].append(f"{root_label}: Wallpaper.plist logicalScreenClass is missing or malformed")
        logical_screen_class = None
    elif expected_screen_class is not None and logical_screen_class != expected_screen_class:
        report["warnings"].append(f"{root_label}: logicalScreenClass {logical_screen_class!r} does not match requested target {expected_screen_class!r}; this is a metadata mismatch, not a renderer compatibility verdict")

    wallpaper_id = metadata.get("identifier")
    if isinstance(wallpaper_id, bool) or not isinstance(wallpaper_id, int) or wallpaper_id < 0:
        report["errors"].append(f"{root_label}: Wallpaper.plist identifier must be a non-negative integer in the observed PosterForge schema")
        wallpaper_id = None
    elif wallpaper_id in seen_wallpaper_ids:
        report["errors"].append(f"{root_label}: duplicate wallpaper identifier {wallpaper_id}")
    else:
        seen_wallpaper_ids.add(wallpaper_id)

    assets = metadata.get("assets")
    lock_home = assets.get("lockAndHome") if isinstance(assets, dict) else None
    default = lock_home.get("default") if isinstance(lock_home, dict) else None
    if not isinstance(default, dict):
        report["errors"].append(f"{root_label}: Wallpaper.plist lacks assets.lockAndHome.default dictionary")
        default = {}
    if wallpaper_id is not None and default.get("identifier") != wallpaper_id:
        report["errors"].append(f"{root_label}: Wallpaper.plist top-level and lockAndHome.default identifiers differ")
    if metadata.get("type") is not None and default.get("type") != "LayeredAnimation":
        report["errors"].append(f"{root_label}: observed PosterForge profile expects type LayeredAnimation")

    representing_id = None
    user_info_path = contents / "com.apple.posterkit.provider.contents.userInfo"
    user_info = _read_plist(user_info_path, f"{root_label}/contents userInfo", report["errors"]) if user_info_path.is_file() else None
    if not user_info_path.is_file():
        report["errors"].append(f"{root_label}: missing contents/com.apple.posterkit.provider.contents.userInfo")
    if isinstance(user_info, dict):
        representing_name = user_info.get("wallpaperRepresentingFileName")
        try:
            representing_name = _safe_component(representing_name, "wallpaperRepresentingFileName")
            if representing_name != wallpaper.name:
                report["errors"].append(f"{root_label}: userInfo wallpaperRepresentingFileName does not match actual bundle name")
        except ConsistencyError as exc:
            report["errors"].append(f"{root_label}: {exc}")
        representing_id = user_info.get("wallpaperRepresentingIdentifier")
        if not isinstance(representing_id, str) or not representing_id.isdecimal():
            report["errors"].append(f"{root_label}: userInfo wallpaperRepresentingIdentifier is not a decimal string")
        elif wallpaper_id is not None and representing_id != str(wallpaper_id):
            report["errors"].append(f"{root_label}: userInfo wallpaperRepresentingIdentifier does not match Wallpaper.plist")
        if numeric_id is not None and representing_id is not None and isinstance(representing_id, str) and numeric_id != representing_id:
            report["errors"].append(f"{root_label}: root descriptor identifier and wallpaperRepresentingIdentifier differ")

    ca_keys = ["backgroundAnimationFileName", "floatingAnimationFileNameKey"]
    if isinstance(default, dict) and "foregroundAnimationFileName" in default:
        ca_keys.append("foregroundAnimationFileName")
    ca_refs = []
    for key in ca_keys:
        name = default.get(key)
        try:
            name = _safe_component(name, key)
        except ConsistencyError as exc:
            report["errors"].append(f"{root_label}: {exc}")
            continue
        if not name.endswith(".ca"):
            report["errors"].append(f"{root_label}: {key} does not end in .ca")
            continue
        ca_dir = wallpaper / name
        if ca_dir.is_symlink() or not ca_dir.is_dir():
            report["errors"].append(f"{root_label}: Wallpaper.plist references missing .ca directory {name}")
            continue
        ca_refs.append(name)
        _check_asset_references(ca_dir, report, f"{root_label}/{wallpaper.name}/{name}")
        index_path = ca_dir / "index.xml"
        index = _read_plist(index_path, f"{root_label}/{wallpaper.name}/{name}/index.xml", report["errors"]) if index_path.is_file() else None
        if not index_path.is_file():
            report["errors"].append(f"{root_label}/{wallpaper.name}/{name}: missing index.xml")
        elif not isinstance(index, dict):
            report["errors"].append(f"{root_label}/{wallpaper.name}/{name}: index.xml root is not a plist dictionary")
        else:
            root_document = index.get("rootDocument")
            try:
                root_document = _safe_component(root_document, "index.xml rootDocument")
                if not (ca_dir / root_document).is_file():
                    report["errors"].append(f"{root_label}/{wallpaper.name}/{name}: index.xml rootDocument target is missing: {root_document}")
            except ConsistencyError as exc:
                report["errors"].append(f"{root_label}/{wallpaper.name}/{name}: {exc}")
            manifest_name = index.get("assetManifest")
            if manifest_name is not None:
                try:
                    manifest_name = _safe_component(manifest_name, "index.xml assetManifest")
                    if not (ca_dir / manifest_name).is_file():
                        report["warnings"].append(f"{root_label}/{wallpaper.name}/{name}: index.xml assetManifest target is absent: {manifest_name}; device-side tolerance is unverified")
                except ConsistencyError as exc:
                    report["errors"].append(f"{root_label}/{wallpaper.name}/{name}: {exc}")

    if len(ca_refs) == 2 and ca_refs[0] == ca_refs[1]:
        report["warnings"].append(f"{root_label}: background and floating layers reference the same .ca bundle")
    if len(report["errors"]) != before_errors:
        status = "invalid"
    else:
        status = "passes-structural-checks"
    return {
        "descriptor_directory": root_label,
        "descriptor_identifier": numeric_id,
        "role_identifier": role_value,
        "wallpaper_bundle": wallpaper.name,
        "wallpaper_identifier": wallpaper_id,
        "logical_screen_class": logical_screen_class,
        "ca_bundles": ca_refs,
        "status": status,
    }


def validate_descriptors_root(root: Path, expected_screen_class: str | None = None) -> dict[str, Any]:
    if expected_screen_class is not None and not re.fullmatch(r"[1-9][0-9]*w-[1-9][0-9]*h@[1-9][0-9]*x~[A-Za-z0-9_-]+", expected_screen_class):
        raise ConsistencyError("expected screen class must use the observed WIDTHw-HEIGHTh@SCALEx~DEVICE format")
    base = root.absolute()
    report: dict[str, Any] = {
        "schema": "lumenboard.posterforge-ios16-structure-check.v1",
        "status": "not-validated",
        "scope": "structural-consistency-only-not-a-PosterBoard-compatibility-test",
        "expected_screen_class": expected_screen_class,
        "root": str(base),
        "errors": [],
        "warnings": [],
        "descriptors": [],
    }
    if base.is_symlink() or not base.is_dir():
        raise ConsistencyError("descriptors root must be an existing, non-symlink directory")
    _walk_safety(base, report)
    # Do not follow links or inspect file contents once any unsafe filesystem entry
    # has been observed; the first report is sufficient to block further processing.
    if report["errors"]:
        report["status"] = "invalid"
        return report
    descriptor_dirs = sorted(p for p in base.iterdir() if p.is_dir() and not p.is_symlink())
    descriptor_dirs = [p for p in descriptor_dirs if (p / "com.apple.posterkit.provider.descriptor.identifier").exists() or (p / "versions").exists()]
    if not descriptor_dirs:
        report["errors"].append("no descriptor directories found under descriptors root")
    seen_descriptor_ids: set[str] = set()
    seen_wallpaper_ids: set[int] = set()
    for descriptor in descriptor_dirs:
        item = _validate_one(descriptor, report, seen_descriptor_ids, seen_wallpaper_ids, expected_screen_class)
        if item is not None:
            report["descriptors"].append(item)
    if report["errors"]:
        report["status"] = "invalid"
    elif report["warnings"]:
        report["status"] = "passes-with-warnings"
    else:
        report["status"] = "passes-structural-checks"
    return report


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("descriptors_root", type=Path, help="extracted descriptors directory; this command is read-only")
    parser.add_argument("--expected-screen-class", help="optional exact metadata target, e.g. 375w-812h@3x~iphone; mismatch is reported as a warning")
    args = parser.parse_args(argv)
    try:
        report = validate_descriptors_root(args.descriptors_root, args.expected_screen_class)
    except (ConsistencyError, OSError) as exc:
        print(json.dumps({"status": "invalid-input", "error": str(exc)}, indent=2), file=sys.stderr)
        return 2
    print(json.dumps(report, indent=2, ensure_ascii=False))
    return 0 if report["status"] == "passes-structural-checks" else 1


if __name__ == "__main__":
    raise SystemExit(main())
