import os
import plistlib
import re
import shutil
import stat
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest import mock

import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
import tendies_inspect


def make_descriptor_archive(path: Path, root_name: str = "descriptors") -> Path:
    with zipfile.ZipFile(path, "w", compression=zipfile.ZIP_DEFLATED) as zf:
        zf.writestr(f"{root_name}/AABBCCDD-0000-4000-8000-000000000001/", "")
        zf.writestr(f"{root_name}/AABBCCDD-0000-4000-8000-000000000001/com.apple.posterkit.provider.descriptor.identifier", "12345")
        zf.writestr(f"{root_name}/AABBCCDD-0000-4000-8000-000000000001/versions/1/contents/demo.Custom.wallpaper/Wallpaper.plist",
                    plistlib.dumps({"identifier": 12345, "name": "Demo", "assets": {"lockAndHome": {}}}, fmt=plistlib.FMT_BINARY))
    return path


class TendiesInspectorTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)

    def tearDown(self):
        self.temp.cleanup()

    def test_accepts_descriptor_archive_and_reports_parseable_plist(self):
        archive = make_descriptor_archive(self.root / "valid.tendies")
        report = tendies_inspect.inspect_archive(archive)
        self.assertTrue(report["valid_zip"])
        self.assertEqual(report["format"], "descriptor")
        self.assertEqual(report["entries"], 3)
        self.assertEqual(len(report["parseable_plists"]), 1)

    def test_accepts_singular_descriptor_root(self):
        archive = make_descriptor_archive(self.root / "singular.tendies", "descriptor")
        self.assertTrue(tendies_inspect.inspect_archive(archive)["valid_zip"])

    def test_rejects_container_format(self):
        archive = self.root / "container.tendies"
        with zipfile.ZipFile(archive, "w") as zf:
            zf.writestr("container/Library/a.plist", plistlib.dumps({"x": 1}))
            zf.writestr("container/descriptor.txt", "not a descriptor tree")
        with self.assertRaisesRegex(tendies_inspect.TendiesError, "container-format"):
            tendies_inspect.inspect_archive(archive)

    def test_rejects_parent_traversal(self):
        archive = self.root / "traversal.tendies"
        with zipfile.ZipFile(archive, "w") as zf:
            zf.writestr("descriptors/../../outside.plist", plistlib.dumps({"x": 1}))
        with self.assertRaisesRegex(tendies_inspect.TendiesError, "path rejected|non-normal path"):
            tendies_inspect.inspect_archive(archive)

    def test_rejects_absolute_paths(self):
        archive = self.root / "absolute.tendies"
        with zipfile.ZipFile(archive, "w") as zf:
            zf.writestr("/tmp/outside", "x")
        with self.assertRaisesRegex(tendies_inspect.TendiesError, "absolute path"):
            tendies_inspect.inspect_archive(archive)

    def test_rejects_windows_path_separator(self):
        archive = self.root / "backslash.tendies"
        with zipfile.ZipFile(archive, "w") as zf:
            zf.writestr("descriptors\\..\\outside", "x")
        with self.assertRaises(tendies_inspect.TendiesError):
            tendies_inspect.inspect_archive(archive)

    def test_rejects_symlink_entries(self):
        archive = self.root / "symlink.tendies"
        info = zipfile.ZipInfo("descriptors/link")
        info.create_system = 3
        info.external_attr = (stat.S_IFLNK | 0o777) << 16
        with zipfile.ZipFile(archive, "w") as zf:
            zf.writestr(info, "../../outside")
            zf.writestr("descriptors/id/test.plist", plistlib.dumps({"x": 1}))
        with self.assertRaisesRegex(tendies_inspect.TendiesError, "symlink"):
            tendies_inspect.inspect_archive(archive)

    def test_rejects_special_file_entries(self):
        archive = self.root / "device.tendies"
        info = zipfile.ZipInfo("descriptors/device")
        info.create_system = 3
        info.external_attr = (stat.S_IFCHR | 0o600) << 16
        with zipfile.ZipFile(archive, "w") as zf:
            zf.writestr(info, "")
            zf.writestr("descriptors/id/test.plist", plistlib.dumps({"x": 1}))
        with self.assertRaisesRegex(tendies_inspect.TendiesError, "special entry"):
            tendies_inspect.inspect_archive(archive)

    def test_rejects_duplicate_casefolded_paths(self):
        archive = self.root / "duplicate.tendies"
        with zipfile.ZipFile(archive, "w") as zf:
            zf.writestr("descriptors/id/file.plist", plistlib.dumps({"x": 1}))
            zf.writestr("DESCRIPTORS/ID/FILE.PLIST", plistlib.dumps({"x": 2}))
        with self.assertRaisesRegex(tendies_inspect.TendiesError, "duplicate"):
            tendies_inspect.inspect_archive(archive)

    def test_rejects_archive_without_descriptor_directory(self):
        archive = self.root / "not-descriptor.tendies"
        with zipfile.ZipFile(archive, "w") as zf:
            zf.writestr("other/file.plist", plistlib.dumps({"x": 1}))
        with self.assertRaisesRegex(tendies_inspect.TendiesError, "no descriptor"):
            tendies_inspect.inspect_archive(archive)

    def test_rejects_size_limit(self):
        archive = self.root / "large.tendies"
        with zipfile.ZipFile(archive, "w", compression=zipfile.ZIP_STORED) as zf:
            zf.writestr("descriptors/id/data.bin", b"12345")
            zf.writestr("descriptors/id/descriptor.plist", plistlib.dumps({"x": 1}))
        with mock.patch.object(tendies_inspect, "MAX_SINGLE_FILE_BYTES", 4):
            with self.assertRaisesRegex(tendies_inspect.TendiesError, "size too large"):
                tendies_inspect.inspect_archive(archive)

    def test_rejects_bad_zip(self):
        archive = self.root / "bad.tendies"
        archive.write_bytes(b"not a zip")
        with self.assertRaisesRegex(tendies_inspect.TendiesError, "ZIP end-of-central-directory|invalid ZIP"):
            tendies_inspect.inspect_archive(archive)

    def test_rejects_crc_corruption(self):
        archive = self.root / "crc-corrupt.tendies"
        wallpaper = plistlib.dumps({"identifier": 12345, "name": "Demo", "assets": {"lockAndHome": {}}})
        with zipfile.ZipFile(archive, "w", compression=zipfile.ZIP_STORED) as zf:
            zf.writestr("descriptors/id/versions/1/contents/demo.Custom.wallpaper/Wallpaper.plist", wallpaper)
            zf.writestr("descriptors/id/versions/1/contents/demo.Custom.wallpaper/assets/0.jpg", b"ASSET_PAYLOAD")
        damaged = bytearray(archive.read_bytes())
        offset = damaged.find(b"ASSET_PAYLOAD")
        self.assertGreaterEqual(offset, 0)
        damaged[offset] ^= 0x01
        archive.write_bytes(damaged)
        with self.assertRaisesRegex(tendies_inspect.TendiesError, "CRC failure"):
            tendies_inspect.inspect_archive(archive)

    def test_extracts_verified_archive_to_new_directory(self):
        archive = make_descriptor_archive(self.root / "extract.tendies")
        destination = self.root / "out"
        report = tendies_inspect.extract_verified(archive, destination)
        self.assertEqual(report["extracted_to"], str(destination.resolve()))
        self.assertTrue((destination / "descriptors/AABBCCDD-0000-4000-8000-000000000001/versions/1/contents/demo.Custom.wallpaper/Wallpaper.plist").is_file())

    def test_refuses_nonempty_extraction_destination(self):
        archive = make_descriptor_archive(self.root / "extract.tendies")
        destination = self.root / "out"
        destination.mkdir()
        (destination / "keep.txt").write_text("keep")
        with self.assertRaisesRegex(tendies_inspect.TendiesError, "empty directory"):
            tendies_inspect.extract_verified(archive, destination)
        self.assertEqual((destination / "keep.txt").read_text(), "keep")

    def test_rejects_non_tendies_extension(self):
        archive = self.root / "input.zip"
        make_descriptor_archive(archive)
        with self.assertRaisesRegex(tendies_inspect.TendiesError, r"\.tendies extension"):
            tendies_inspect.inspect_archive(archive)

    def test_refuses_symlink_extraction_destination(self):
        archive = make_descriptor_archive(self.root / "extract.tendies")
        real = self.root / "real-out"
        real.mkdir()
        link = self.root / "linked-out"
        link.symlink_to(real, target_is_directory=True)
        with self.assertRaisesRegex(tendies_inspect.TendiesError, "not be a symlink"):
            tendies_inspect.extract_verified(archive, link)
        self.assertEqual(list(real.iterdir()), [])

    def test_refuses_empty_archive_file(self):
        archive = self.root / "empty.tendies"
        archive.write_bytes(b"")
        with self.assertRaisesRegex(tendies_inspect.TendiesError, "archive size"):
            tendies_inspect.inspect_archive(archive)

    def test_rejects_malformed_plist_instead_of_accepting_false_positive(self):
        archive = self.root / "badplist.tendies"
        with zipfile.ZipFile(archive, "w") as zf:
            zf.writestr("descriptors/id/Wallpaper.plist", b"not a plist")
            zf.writestr("descriptors/id/readme.bin", b"x")
        with self.assertRaisesRegex(tendies_inspect.TendiesError, "malformed plist"):
            tendies_inspect.inspect_archive(archive)

    def test_rejects_archive_with_no_plist_entries(self):
        archive = self.root / "noplists.tendies"
        with zipfile.ZipFile(archive, "w") as zf:
            zf.writestr("descriptors/id/assets/0.jpg", b"jpeg bytes")
        with self.assertRaisesRegex(tendies_inspect.TendiesError, "no plist descriptors"):
            tendies_inspect.inspect_archive(archive)

    def test_rejects_archive_with_generic_plist_but_no_wallpaper_plist(self):
        archive = self.root / "generic-plist.tendies"
        with zipfile.ZipFile(archive, "w") as zf:
            zf.writestr("descriptors/id/metadata.plist", plistlib.dumps({"identifier": 1}))
        with self.assertRaisesRegex(tendies_inspect.TendiesError, "no parseable Wallpaper.plist"):
            tendies_inspect.inspect_archive(archive)

    def test_rejects_wallpaper_plist_missing_expected_fields(self):
        archive = self.root / "incomplete-wallpaper-plist.tendies"
        with zipfile.ZipFile(archive, "w") as zf:
            zf.writestr("descriptors/id/Wallpaper.plist", plistlib.dumps({"identifier": 1, "name": "Demo"}))
        with self.assertRaisesRegex(tendies_inspect.TendiesError, "missing required top-level fields"):
            tendies_inspect.inspect_archive(archive)

    def test_rejects_unicode_normalization_alias_paths(self):
        archive = self.root / "unicode-alias.tendies"
        with zipfile.ZipFile(archive, "w") as zf:
            zf.writestr("descriptors/café.txt", b"one")
            zf.writestr("descriptors/café.txt", b"two")
        with self.assertRaisesRegex(tendies_inspect.TendiesError, "duplicate archive path"):
            tendies_inspect.inspect_archive(archive)

    def test_rejects_file_directory_prefix_conflict(self):
        archive = self.root / "path-conflict.tendies"
        with zipfile.ZipFile(archive, "w") as zf:
            zf.writestr("descriptors/id", b"not a directory")
            zf.writestr("descriptors/id/Wallpaper.plist", plistlib.dumps({"identifier": 1}))
        with self.assertRaisesRegex(tendies_inspect.TendiesError, "file/directory path conflict"):
            tendies_inspect.inspect_archive(archive)

    def test_rejects_oversized_plist_even_if_archive_is_under_total_limit(self):
        archive = self.root / "oversized-plist.tendies"
        with zipfile.ZipFile(archive, "w", compression=zipfile.ZIP_STORED) as zf:
            zf.writestr("descriptors/id/Wallpaper.plist", b"x" * 32)
        with mock.patch.object(tendies_inspect, "MAX_PLIST_BYTES", 16):
            with self.assertRaisesRegex(tendies_inspect.TendiesError, "plist exceeds"):
                tendies_inspect.inspect_archive(archive)


    def test_ignores_macosx_mirror_with_malformed_posterkit_metadata_plist(self):
        archive = make_descriptor_archive(self.root / "macosx-metadata.tendies")
        sidecar = "__MACOSX/descriptors/AABBCCDD-0000-4000-8000-000000000001/_com.apple.posterkit.provider.identifierURL.suggestion-Metadata.plist"
        with zipfile.ZipFile(archive, "a", compression=zipfile.ZIP_DEFLATED) as zf:
            zf.writestr(sidecar, b"not a property list")
        second_sidecar = "MACOSX/descriptors/AABBCCDD-0000-4000-8000-000000000001/_com.apple.posterkit.provider.identifierURL.suggestion-Metadata.plist"
        with zipfile.ZipFile(archive, "a", compression=zipfile.ZIP_DEFLATED) as zf:
            zf.writestr(second_sidecar, b"also not a property list")
        report = tendies_inspect.inspect_archive(archive)
        self.assertTrue(report["valid_zip"])
        self.assertEqual(report["ignored_metadata_entries"], 2)
        self.assertEqual(report["plist_entries"], 1)
        self.assertNotIn(sidecar, report["parseable_plists"])
        self.assertNotIn(second_sidecar, report["parseable_plists"])

    def test_ignores_appledouble_and_finder_files_during_extraction(self):
        archive = make_descriptor_archive(self.root / "finder-metadata.tendies")
        with zipfile.ZipFile(archive, "a", compression=zipfile.ZIP_DEFLATED) as zf:
            zf.writestr("descriptors/AABBCCDD-0000-4000-8000-000000000001/._Wallpaper.plist", b"not a plist")
            zf.writestr("descriptors/AABBCCDD-0000-4000-8000-000000000001/.DS_Store", b"finder state")
        destination = self.root / "finder-out"
        report = tendies_inspect.extract_verified(archive, destination)
        descriptor = destination / "descriptors/AABBCCDD-0000-4000-8000-000000000001"
        self.assertEqual(report["ignored_metadata_entries"], 2)
        self.assertTrue((descriptor / "com.apple.posterkit.provider.descriptor.identifier").is_file())
        self.assertFalse((descriptor / "._Wallpaper.plist").exists())
        self.assertFalse((descriptor / ".DS_Store").exists())


class ProjectPackagingContractTests(unittest.TestCase):
    PROJECT = Path(__file__).resolve().parents[1]

    def test_deb_architecture_matches_rootless_theos_scheme(self):
        control = (self.PROJECT / "control").read_text()
        makefile = (self.PROJECT / "Makefile").read_text()
        self.assertIn("Architecture: iphoneos-arm64", control)
        self.assertIn("THEOS_PACKAGE_SCHEME = rootless", makefile)
        self.assertNotIn("Architecture: iphoneos-arm\n", control)

    def test_preference_bundle_declares_executable(self):
        info = plistlib.loads((self.PROJECT / "Preferences" / "Info.plist").read_bytes())
        self.assertEqual(info["CFBundleExecutable"], "LumenBoardPrefs")
        self.assertEqual(info["NSPrincipalClass"], "LumenBoardRootListController")
        control = (self.PROJECT / "control").read_text()
        package_version = next(line.split(":", 1)[1].strip() for line in control.splitlines() if line.startswith("Version:"))
        self.assertEqual(info["CFBundleVersion"], package_version.rsplit("-", 1)[1])

    def test_native_daemon_is_built_and_staged_for_rootless_launchd(self):
        makefile = (self.PROJECT / "Makefile").read_text()
        self.assertIn("TOOL_NAME = lumenboardd", makefile)
        self.assertIn("lumenboardd_INSTALL_PATH = /usr/libexec", makefile)
        plist_path = self.PROJECT / "layout" / "Library" / "LaunchDaemons" / "com.iuyghi.lumenboardd.plist"
        self.assertTrue(plist_path.is_file())
        with plist_path.open("rb") as stream:
            plist = plistlib.load(stream)
        self.assertEqual(plist["Label"], "com.iuyghi.lumenboardd")
        self.assertEqual(plist["ProgramArguments"][0], "/var/jb/usr/libexec/lumenboardd")

    def test_maintainer_scripts_are_packaged_executable_hooks(self):
        control_dir = self.PROJECT / "layout" / "DEBIAN"
        self.assertTrue(control_dir.is_dir())
        for name in ("postinst", "prerm"):
            script = control_dir / name
            self.assertTrue(script.is_file())
            if os.name != "nt":
                self.assertTrue(script.stat().st_mode & stat.S_IXUSR)
        postinst = (control_dir / "postinst").read_text()
        prerm = (control_dir / "prerm").read_text()
        self.assertIn("bootstrap user/foreground", postinst)
        self.assertIn("system/com.iuyghi.lumenboardd", postinst)
        self.assertIn("system/com.iuyghi.lumenboardd", prerm)


    def test_native_validator_filters_macos_finder_metadata_before_plist_parsing_and_extraction(self):
        source = (self.PROJECT / "Preferences" / "LBTendiesValidator.m").read_text()
        self.assertIn("static BOOL LBTIsMetadataPath(NSString *path)", source)
        self.assertIn('isEqualToString:@"__macosx"', source)
        self.assertIn('isEqualToString:@"macosx"', source)
        self.assertIn('hasPrefix:@"._"', source)
        self.assertIn("e.ignoredMetadata=ignoredMetadata", source)
        self.assertIn("!e.ignoredMetadata &&", source)
        self.assertIn("if(e.ignoredMetadata)continue;", source)
        self.assertIn("ignoredMetadataEntries", source)


    def test_posterboard_refresh_skips_unprivileged_chown_and_never_controls_processes(self):
        installer = (self.PROJECT / "Daemon" / "LBPosterBoardInstaller.m").read_text()
        self.assertIn("writtenStat.st_uid != mobile->pw_uid", installer)
        self.assertIn("writtenStat.st_gid != mobile->pw_gid", installer)
        self.assertIn("verifiedStat.st_uid != mobile->pw_uid", installer)
        self.assertIn("verifiedStat.st_gid != mobile->pw_gid", installer)
        self.assertIn("geteuid() != 0 && geteuid() != mobile->pw_uid", installer)
        self.assertIn('@"refreshPreferencesErrno": @(written ? 0 : (savedErrno ?: EIO))', installer)
        self.assertIn('@"refreshCommandAttempted": @NO', installer)
        self.assertIn('@"posterBoardRefreshRequiresDeviceRestart": @(written)', installer)
        self.assertIn("The existing PosterBoard preferences are not a valid property-list dictionary", installer)
        self.assertIn("LumenBoard does not terminate or signal system processes", installer)
        for forbidden in ("killall", "posix_spawn", "waitpid", "SIGKILL", "kill("):
            with self.subTest(forbidden=forbidden):
                self.assertNotIn(forbidden, installer)

    def test_duplicate_tendies_path_performs_read_only_live_store_verification(self):
        installer = (self.PROJECT / "Daemon" / "LBPosterBoardInstaller.m").read_text()
        header = (self.PROJECT / "Daemon" / "LBPosterBoardInstaller.h").read_text()
        daemon = (self.PROJECT / "Daemon" / "main.m").read_text()
        preferences = (self.PROJECT / "Preferences" / "LBRootListController.m").read_text()
        self.assertIn("verifyRegisteredDescriptorIdentifiers:", installer)
        self.assertIn("filesystem-registration-only", installer)
        self.assertIn("posterBoardApplicationState", installer)
        self.assertIn("verifyRegisteredDescriptorIdentifiers:", header)
        self.assertIn("verify-tendies-registration", daemon)
        self.assertIn("LBVerifyManagedTendiesRegistration", daemon)
        self.assertIn("LBQueueTendiesVerificationAndWait", preferences)
        self.assertIn("descriptorStoreState", preferences)
        self.assertIn("native gallery visibility, selectability, or wallpaper application", preferences)


class ValidatorLimitsParityTests(unittest.TestCase):
    PROJECT = Path(__file__).resolve().parents[1]

    def test_python_inspector_limits_match_on_device_validator(self):
        inspector = (self.PROJECT / "tools" / "tendies_inspect.py").read_text()
        native = (self.PROJECT / "Preferences" / "LBTendiesValidator.m").read_text()

        def number(source, pattern, label, multiplier=1):
            match = re.search(pattern, source, re.MULTILINE)
            self.assertIsNotNone(match, f"could not find {label}")
            return int(match.group(1)) * multiplier

        mib = 1024 * 1024
        python_limits = {
            "archive": number(inspector, r"^MAX_ARCHIVE_BYTES = (\d+) \* 1024 \* 1024$", "Python archive limit", mib),
            "entries": number(inspector, r"^MAX_ENTRIES = (\d+)$", "Python entry limit"),
            "member": number(inspector, r"^MAX_SINGLE_FILE_BYTES = (\d+) \* 1024 \* 1024$", "Python member limit", mib),
            "total": number(inspector, r"^MAX_TOTAL_UNCOMPRESSED_BYTES = (\d+) \* 1024 \* 1024$", "Python total limit", mib),
            "ratio": number(inspector, r"^MAX_COMPRESSION_RATIO = (\d+)$", "Python compression ratio"),
            "plist": number(inspector, r"^MAX_PLIST_BYTES = (\d+) \* 1024 \* 1024$", "Python plist limit", mib),
        }
        native_limits = {
            "archive": number(native, r"LBTMaxArchive = (\d+)ULL \* 1024ULL \* 1024ULL", "native archive limit", mib),
            "entries": number(native, r"LBTMaxEntries = (\d+)", "native entry limit"),
            "member": number(native, r"LBTMaxFile = (\d+)ULL \* 1024ULL \* 1024ULL", "native member limit", mib),
            "total": number(native, r"LBTMaxTotal = (\d+)ULL \* 1024ULL \* 1024ULL", "native total limit", mib),
            "ratio": number(native, r"\(uint64_t\)us>\(uint64_t\)cs\*(\d+)", "native compression ratio"),
            "plist": number(native, r"LBTMaxPlist = (\d+) \* 1024 \* 1024", "native plist limit", mib),
        }
        self.assertEqual(python_limits, native_limits)


if __name__ == "__main__":
    unittest.main()
