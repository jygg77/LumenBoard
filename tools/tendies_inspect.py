#!/usr/bin/env python3
"""Safety-oriented inspector/extractor for descriptor-format PosterBoard .tendies ZIPs.

This is a portable developer utility, not the runtime implementation used by the iOS pane.
It intentionally refuses container-format restores, encrypted/ZIP64 archives, symlinks,
special files, traversal paths, duplicate paths, and oversized archives.
"""
from __future__ import annotations

import argparse
import json
import struct
import os
import plistlib
import shutil
import stat
import sys
import unicodedata
import zipfile
from pathlib import Path, PurePosixPath
from typing import Any

MAX_ARCHIVE_BYTES = 300 * 1024 * 1024
MAX_ENTRIES = 2048
# Keep the offline inspector no more permissive than the on-device validator.
MAX_SINGLE_FILE_BYTES = 64 * 1024 * 1024
MAX_TOTAL_UNCOMPRESSED_BYTES = 128 * 1024 * 1024
MAX_COMPRESSION_RATIO = 500
MAX_PLIST_BYTES = 8 * 1024 * 1024

class TendiesError(ValueError):
    """Invalid or unsafe .tendies package."""


def _safe_member(info: zipfile.ZipInfo) -> str:
    raw = info.filename
    if not raw or "\x00" in raw or "\\" in raw:
        raise TendiesError(f"unsafe path separator/name: {raw!r}")
    if raw.startswith("/") or (len(raw) >= 2 and raw[1] == ":"):
        raise TendiesError(f"absolute path rejected: {raw!r}")
    if any(ord(ch) < 32 or ord(ch) == 127 for ch in raw):
        raise TendiesError(f"control character in path: {raw!r}")
    is_dir = info.is_dir()
    trimmed = raw[:-1] if is_dir and raw.endswith("/") else raw
    parts = trimmed.split("/")
    if not trimmed or any(part in ("", ".", "..") for part in parts):
        raise TendiesError(f"non-normal path rejected: {raw!r}")
    if any(":" in part for part in parts):
        raise TendiesError(f"colon in path rejected: {raw!r}")
    mode = (info.external_attr >> 16) & 0xFFFF
    file_type = stat.S_IFMT(mode)
    if file_type == stat.S_IFLNK:
        raise TendiesError(f"symlink entry rejected: {raw!r}")
    if file_type not in (0, stat.S_IFREG, stat.S_IFDIR):
        raise TendiesError(f"special entry rejected: {raw!r}")
    if is_dir and file_type == stat.S_IFREG:
        raise TendiesError(f"directory/file type mismatch: {raw!r}")
    if not is_dir and file_type == stat.S_IFDIR:
        raise TendiesError(f"directory/file type mismatch: {raw!r}")
    return "/".join(parts)


def _is_macos_metadata_path(name: str) -> bool:
    """Return True for Finder metadata that must not enter a PosterBoard tree."""
    for component in name.split("/"):
        folded = component.casefold()
        if folded in {"__macosx", "macosx", ".ds_store"} or folded.startswith("._"):
            return True
    return False


def _reject_unsupported_zip_layout(archive: Path) -> None:
    """Reject multi-disk and ZIP64 archives rather than guessing their boundaries."""
    with archive.open("rb") as stream:
        stream.seek(0, os.SEEK_END)
        length = stream.tell()
        tail_size = min(length, 65_557)
        stream.seek(length - tail_size)
        tail = stream.read(tail_size)
    signature = b"PK\x05\x06"
    offset = tail.rfind(signature)
    if offset < 0 or offset + 22 > len(tail):
        raise TendiesError("ZIP end-of-central-directory record not found")
    try:
        disk_number, central_disk, entries_disk, entries_total, central_size, central_offset, comment_len = struct.unpack_from("<4H2LH", tail, offset + 4)
    except struct.error as exc:
        raise TendiesError("malformed ZIP end-of-central-directory record") from exc
    if offset + 22 + comment_len != len(tail):
        raise TendiesError("malformed ZIP comment length")
    if disk_number != 0 or central_disk != 0 or entries_disk != entries_total:
        raise TendiesError("multi-disk ZIP archives are not supported")
    if entries_total == 0xFFFF or central_size == 0xFFFFFFFF or central_offset == 0xFFFFFFFF:
        raise TendiesError("ZIP64 archives are not supported by this inspector")
    absolute_eocd = length - tail_size + offset
    if central_offset + central_size > absolute_eocd:
        raise TendiesError("central directory overlaps or exceeds the ZIP end record")
    # Parse central directory records without loading archive payloads; reject ZIP64 extras/sentinels.
    with archive.open("rb") as stream:
        stream.seek(central_offset)
        consumed = 0
        for _ in range(entries_total):
            header = stream.read(46)
            consumed += len(header)
            if len(header) != 46 or header[:4] != b"PK\x01\x02":
                raise TendiesError("malformed ZIP central-directory entry")
            _made_by, _needed, _flags, _method, _time, _date, _crc, comp_size, file_size, name_len, extra_len, comment_len, disk_start, _int_attr, _ext_attr, _local_offset = struct.unpack_from("<6H3L5H2L", header, 4)
            if comp_size == 0xFFFFFFFF or file_size == 0xFFFFFFFF or disk_start == 0xFFFF or _local_offset == 0xFFFFFFFF:
                raise TendiesError("ZIP64 entry is not supported by this inspector")
            name_bytes = stream.read(name_len)
            extra = stream.read(extra_len)
            comment = stream.read(comment_len)
            if len(name_bytes) != name_len or len(extra) != extra_len or len(comment) != comment_len:
                raise TendiesError("truncated ZIP central-directory entry")
            consumed += name_len + extra_len + comment_len
            extra_pos = 0
            while extra_pos + 4 <= len(extra):
                field_id, field_len = struct.unpack_from("<HH", extra, extra_pos)
                extra_pos += 4
                if extra_pos + field_len > len(extra):
                    raise TendiesError("malformed ZIP extra field")
                if field_id == 0x0001:
                    raise TendiesError("ZIP64 extra fields are not supported by this inspector")
                extra_pos += field_len
            if extra_pos != len(extra):
                raise TendiesError("malformed ZIP extra-field length")
        if consumed != central_size:
            raise TendiesError("central-directory size does not match its records")


def inspect_archive(archive: Path) -> dict[str, Any]:
    if archive.suffix.lower() != ".tendies":
        raise TendiesError("input file must have a .tendies extension")
    try:
        size = archive.stat().st_size
    except OSError as exc:
        raise TendiesError(f"cannot stat archive: {exc}") from exc
    if size <= 0 or size > MAX_ARCHIVE_BYTES:
        raise TendiesError(f"archive size must be 1..{MAX_ARCHIVE_BYTES} bytes")
    _reject_unsupported_zip_layout(archive)
    try:
        zf = zipfile.ZipFile(archive, "r")
    except (OSError, zipfile.BadZipFile, zipfile.LargeZipFile) as exc:
        raise TendiesError(f"invalid ZIP archive: {exc}") from exc
    with zf:
        infos = zf.infolist()
        if not infos or len(infos) > MAX_ENTRIES:
            raise TendiesError(f"entry count must be 1..{MAX_ENTRIES}")
        normalized: list[tuple[zipfile.ZipInfo, str]] = []
        # APFS volumes used by iOS commonly compare names case-insensitively and
        # normalize Unicode. Reject aliases before extraction rather than relying
        # on the target filesystem to reveal a collision.
        seen: dict[str, bool] = {}
        total = 0
        has_descriptor = False
        has_container = False
        plist_paths: list[str] = []
        ignored_metadata_paths: set[str] = set()
        for info in infos:
            name = _safe_member(info)
            key = unicodedata.normalize("NFD", name).casefold()
            if key in seen:
                raise TendiesError(f"duplicate archive path rejected: {name!r}")
            parts_key = key.split("/")
            for index in range(1, len(parts_key)):
                parent_key = "/".join(parts_key[:index])
                if parent_key in seen and not seen[parent_key]:
                    raise TendiesError(f"file/directory path conflict rejected: {name!r}")
            is_directory = info.is_dir()
            if not is_directory and any(existing.startswith(key + "/") for existing in seen):
                raise TendiesError(f"file/directory path conflict rejected: {name!r}")
            seen[key] = is_directory
            if info.flag_bits & 0x1:
                raise TendiesError(f"encrypted entry rejected: {name!r}")
            if info.compress_type not in (zipfile.ZIP_STORED, zipfile.ZIP_DEFLATED):
                raise TendiesError(f"unsupported compression method for {name!r}")
            if info.file_size < 0 or info.file_size > MAX_SINGLE_FILE_BYTES:
                raise TendiesError(f"uncompressed member size too large: {name!r}")
            total += info.file_size
            if total > MAX_TOTAL_UNCOMPRESSED_BYTES:
                raise TendiesError("total uncompressed size exceeds safety limit")
            if info.file_size > 0 and info.compress_size == 0:
                raise TendiesError(f"invalid compressed size for {name!r}")
            if info.compress_size > 0 and info.file_size / info.compress_size > MAX_COMPRESSION_RATIO:
                raise TendiesError(f"compression ratio exceeds safety limit: {name!r}")
            is_macos_metadata = _is_macos_metadata_path(name)
            if is_macos_metadata:
                ignored_metadata_paths.add(name)
            else:
                parts = name.split("/")
                low_parts = [part.casefold() for part in parts]
                if any(part == "container" for part in low_parts):
                    has_container = True
                directory_parts = low_parts if info.is_dir() else low_parts[:-1]
                if any("descriptor" in part for part in directory_parts):
                    has_descriptor = True
                if name.casefold().endswith(".plist"):
                    plist_paths.append(name)
            normalized.append((info, name))
        if has_container:
            raise TendiesError("container-format package rejected; only descriptor-format .tendies is accepted")
        if not has_descriptor:
            raise TendiesError("no descriptor/descriptors directory found")
        if not plist_paths:
            raise TendiesError("no plist descriptors found in archive")
        # Parse small property-list files to catch obvious malformed descriptors without loading assets.
        parseable_plists: list[str] = []
        wallpaper_plists: list[str] = []
        for name in plist_paths:
            matching = next(info for info, item_name in normalized if item_name == name)
            if matching.file_size > MAX_PLIST_BYTES:
                raise TendiesError(f"plist exceeds {MAX_PLIST_BYTES}-byte validation limit: {name!r}")
            with zf.open(matching, "r") as stream:
                payload = stream.read(MAX_PLIST_BYTES + 1)
            if len(payload) > MAX_PLIST_BYTES:
                raise TendiesError(f"plist exceeds {MAX_PLIST_BYTES}-byte validation limit: {name!r}")
            try:
                parsed = plistlib.loads(payload)
            except Exception as exc:
                raise TendiesError(f"malformed plist rejected: {name!r}") from exc
            parseable_plists.append(name)
            if PurePosixPath(name).name.casefold() == "wallpaper.plist":
                if not isinstance(parsed, dict):
                    raise TendiesError(f"Wallpaper.plist root must be a dictionary: {name!r}")
                if not {"identifier", "name", "assets"}.issubset(parsed):
                    raise TendiesError(f"Wallpaper.plist is missing required top-level fields: {name!r}")
                if type(parsed["identifier"]) is not int or not isinstance(parsed["name"], str) or not isinstance(parsed["assets"], dict):
                    raise TendiesError(f"Wallpaper.plist contains invalid identifier/name/assets types: {name!r}")
                wallpaper_plists.append(name)
        if not parseable_plists:
            raise TendiesError("no parseable plist descriptor found in archive")
        if not wallpaper_plists:
            raise TendiesError("no parseable Wallpaper.plist with expected descriptor fields found")
        # This is structural validation, not a complete schema/version check.
        # Inspect the archive CRCs only after size/path limits are established.
        bad_crc = zf.testzip()
        if bad_crc:
            raise TendiesError(f"CRC failure in archive member: {bad_crc!r}")
        return {
            "valid_zip": True,
            "format": "descriptor",
            "archive": archive.name,
            "archive_bytes": size,
            "entries": len(infos),
            "ignored_metadata_entries": len(ignored_metadata_paths),
            "uncompressed_bytes": total,
            "plist_entries": len(plist_paths),
            "parseable_plists": parseable_plists,
            "note": "Structural checks passed; this does not prove PosterBoard/iOS-version compatibility.",
        }


def extract_verified(archive: Path, destination: Path) -> dict[str, Any]:
    report = inspect_archive(archive)
    created_here = not destination.exists()
    if destination.is_symlink():
        raise TendiesError("extraction destination must not be a symlink")
    if destination.exists():
        if not destination.is_dir() or any(destination.iterdir()):
            raise TendiesError("extraction destination must not exist or must be an empty directory")
    else:
        destination.mkdir(parents=True, mode=0o700)
    root = destination.resolve(strict=True)
    try:
        with zipfile.ZipFile(archive, "r") as zf:
            for info in zf.infolist():
                relative = _safe_member(info)
                if _is_macos_metadata_path(relative):
                    continue
                target = root.joinpath(*PurePosixPath(relative).parts)
                # Resolve existing parents and assert they remain under the empty output root.
                target.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
                parent_real = target.parent.resolve(strict=True)
                if parent_real != root and root not in parent_real.parents:
                    raise TendiesError(f"extraction escaped destination: {relative!r}")
                if info.is_dir():
                    target.mkdir(mode=0o700, exist_ok=True)
                    continue
                # O_EXCL prevents a duplicate or pre-created path from being overwritten.
                flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
                if hasattr(os, "O_NOFOLLOW"):
                    flags |= os.O_NOFOLLOW
                fd = os.open(target, flags, 0o600)
                try:
                    with os.fdopen(fd, "wb", closefd=False) as output, zf.open(info, "r") as source:
                        shutil.copyfileobj(source, output, length=128 * 1024)
                    os.fsync(fd)
                finally:
                    os.close(fd)
        return report | {"extracted_to": str(root)}
    except Exception:
        if created_here:
            shutil.rmtree(root, ignore_errors=True)
        else:
            # Preserve a caller-provided empty directory itself; remove only extracted children.
            for child in sorted(root.rglob("*"), key=lambda item: len(item.parts), reverse=True):
                try:
                    child.unlink() if child.is_file() or child.is_symlink() else child.rmdir()
                except OSError:
                    pass
        raise


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive", type=Path, help="path to the .tendies ZIP archive")
    parser.add_argument("--extract", type=Path, help="extract a verified descriptor archive into a new/empty directory")
    args = parser.parse_args(argv)
    try:
        report = extract_verified(args.archive, args.extract) if args.extract else inspect_archive(args.archive)
    except (TendiesError, OSError, zipfile.BadZipFile) as exc:
        print(json.dumps({"valid_zip": False, "error": str(exc)}, indent=2), file=sys.stderr)
        return 2
    print(json.dumps(report, indent=2, ensure_ascii=False))
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
