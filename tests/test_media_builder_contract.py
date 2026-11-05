from pathlib import Path
import math
import plistlib
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]


class NativeMediaPipelineContractTests(unittest.TestCase):
    def test_package_build_normalizes_numeric_archive_ownership(self):
        script = (ROOT / "tools" / "build_and_verify_deb.sh").read_text()
        self.assertIn("normalize_deb_ownership.sh", script)

    def test_native_builder_emits_posterboard_descriptor_components(self):
        source = (ROOT / "Daemon/LBPosterMediaBuilder.m").read_text()
        for token in (
            "com.apple.posterkit.provider.descriptor.identifier",
            "com.apple.posterkit.role.identifier",
            "providerInfo.plist",
            "com.apple.posterkit.provider.contents.userInfo",
            "Wallpaper.plist",
            "PF_Background.ca",
            "PF_Floating.ca",
            "main.caml",
            "index.xml",
            "AVAssetImageGenerator",
            "CAKeyframeAnimation",
        ):
            with self.subTest(token=token):
                self.assertIn(token, source)

    def test_daemon_has_hash_checked_media_install_action(self):
        source = (ROOT / "Daemon/main.m").read_text()
        self.assertIn('isEqualToString:@"install-media"', source)
        self.assertIn("LBPosterMediaBuilder buildDescriptorForSource", source)
        self.assertIn("LBSHA256(sourcePath)", source)
        self.assertIn("installExtractedDescriptorTreeAtPath:generatedRoot", source)

    def test_preferences_queue_media_instead_of_storing_only(self):
        source = (ROOT / "Preferences/LBRootListController.m").read_text()
        self.assertIn('LBQueueDaemonActionAndWait(identifier, @"install-media"', source)
        self.assertIn('manifest[@"installationState"] = @"installed"', source)
        self.assertIn('title = @"Wallpaper descriptor registered"', source)

    def test_media_daemon_rejects_symlinked_item_roots_and_noncanonical_source_names(self):
        source = (ROOT / "Daemon/main.m").read_text()
        start = source.index("static NSDictionary *LBProcessMediaInstallRequest")
        end = source.index("static void LBProcessRequests", start)
        media = source[start:end]
        self.assertIn("lstat(itemRoot.fileSystemRepresentation", media)
        self.assertIn("S_ISDIR(itemRootStat.st_mode)", media)
        self.assertIn("S_ISLNK(itemRootStat.st_mode)", media)
        self.assertIn('[@"source" stringByAppendingPathExtension:sourceExtension]', media)
        self.assertIn("allowedImageExtensions", media)
        self.assertIn("allowedVideoExtensions", media)

    def test_daemon_media_extension_allowlist_matches_picker(self):
        daemon = (ROOT / "Daemon/main.m").read_text()
        preferences = (ROOT / "Preferences/LBRootListController.m").read_text()
        image_match = re.search(r'allowedImageExtensions\s*=\s*\[NSSet setWithArray:@\[(.*?)\]\]', daemon, re.S)
        video_match = re.search(r'allowedVideoExtensions\s*=\s*\[NSSet setWithArray:@\[(.*?)\]\]', daemon, re.S)
        picker_match = re.search(r'NSSet \*allowed\s*=\s*\[NSSet setWithArray:@\[(.*?)\]\]', preferences, re.S)
        self.assertIsNotNone(image_match)
        self.assertIsNotNone(video_match)
        self.assertIsNotNone(picker_match)
        extract = lambda match: set(re.findall(r'@"([a-z0-9]+)"', match.group(1)))
        self.assertTrue(extract(image_match).isdisjoint(extract(video_match)))
        self.assertEqual(extract(image_match) | extract(video_match), extract(picker_match))

    def test_refresh_is_requested_after_media_publication(self):
        source = (ROOT / "Daemon/main.m").read_text()
        self.assertIn("requestPosterBoardRefreshForContainer:container", source)


    def test_posterboard_refresh_writes_flags_without_process_control(self):
        source = (ROOT / "Daemon/LBPosterBoardInstaller.m").read_text()
        self.assertIn('@"refreshCommandAttempted": @NO', source)
        self.assertIn('@"posterBoardRefreshRequested": @NO', source)
        self.assertIn('@"posterBoardRefreshRequiresDeviceRestart": @(written)', source)
        self.assertIn("NSPropertyListMutableContainersAndLeaves", source)
        self.assertIn("LumenBoard does not terminate or signal system processes", source)
        for forbidden in ("killall", "posix_spawn", "waitpid", "SIGKILL", "kill("):
            with self.subTest(forbidden=forbidden):
                self.assertNotIn(forbidden, source)

    def test_posterboard_index_xml_uses_binary_posterforge_property_list_format(self):
        source = (ROOT / "Daemon/LBPosterMediaBuilder.m").read_text()
        self.assertIn("NSPropertyListBinaryFormat_v1_0", source)
        self.assertIn('LBMediaWritePlist(index, [directory stringByAppendingPathComponent:@"index.xml"], error)', source)
        self.assertIn('@"assetManifest":@"assetManifest.caml"', source)
        self.assertIn('@"rootDocument":@"main.caml"', source)
        self.assertIn('@"unitsInPixelsInPlayer":@YES', source)
        self.assertNotIn("LBMediaWriteXMLPlist(index", source)
        self.assertIn(r'version=\"1.0\"', source)
        self.assertNotIn(r'version=\\"1.0\\"', source)

    def test_package_and_preferences_versions_are_synchronized(self):
        control = (ROOT / "control").read_text()
        match = re.search(r"^Version:\s*(\S+)$", control, re.MULTILINE)
        self.assertIsNotNone(match)
        package_version = match.group(1)
        bundle_info = plistlib.loads((ROOT / "Preferences/Info.plist").read_bytes())
        self.assertEqual(bundle_info["CFBundleVersion"], package_version.rsplit("-", 1)[1])
        workflow = (ROOT / ".github/workflows/native-validator.yml").read_text()
        helper = (ROOT / "tools/build_and_verify_deb.sh").read_text()
        self.assertIn(f'Version)" = "{package_version}"', workflow)
        self.assertIn(f'version" != "{package_version}"', helper)

    def test_build_verifier_supports_macos_and_linux_hosts(self):
        helper = (ROOT / "tools/build_and_verify_deb.sh").read_text()
        self.assertIn("command -v xcrun", helper)
        self.assertIn("THEOS/toolchain/linux/iphone/bin/clang", helper)
        self.assertIn("shasum -a 256", helper)
        self.assertIn("sha256sum", helper)

    def test_published_media_manifest_failure_is_reported_as_warning(self):
        source = (ROOT / "Daemon/main.m").read_text()
        start = source.index("static NSDictionary *LBProcessMediaInstallRequest")
        end = source.index("static void LBProcessRequests", start)
        media_path = source[start:end]
        self.assertIn('report[@"manifestUpdateWarning"]', media_path)
        self.assertIn('report[@"posterBoardApplicationState"] = @"unverified"', media_path)
        self.assertNotIn("if (!manifestData || ![manifestData writeToFile:manifestPath options:NSDataWritingAtomic error:error]) return nil;", media_path)

    def test_published_descriptor_never_claims_gallery_or_wallpaper_application(self):
        daemon = (ROOT / "Daemon/main.m").read_text()
        installer = (ROOT / "Daemon/LBPosterBoardInstaller.m").read_text()
        self.assertIn('report[@"posterBoardApplicationState"] = @"unverified"', daemon)
        self.assertIn('@"posterBoardApplicationState": @"unverified"', installer)
        self.assertIn("Native gallery recognition, wallpaper selection, and actual application still require device verification.", (ROOT / "Preferences/LBRootListController.m").read_text())

    def test_timed_out_media_generation_is_reconciled(self):
        source = (ROOT / "Preferences/LBRootListController.m").read_text()
        self.assertIn('@"generating"', source)
        self.assertIn('@"install-media"', source)
        self.assertIn('mediaInstall ? @"installed" : @"descriptors-published"', source)

    def test_legacy_tendies_verification_recovers_ids_from_saved_installation_report(self):
        source = (ROOT / "Daemon/main.m").read_text()
        start = source.index("static NSDictionary *LBVerifyManagedTendiesRegistration")
        end = source.index("static NSDictionary *LBProcessMediaInstallRequest", start)
        verification = source[start:end]
        self.assertIn('manifest[@"installedDescriptorIdentifiers"]', verification)
        self.assertIn('manifest[@"installationReport"]', verification)
        self.assertIn('legacyReport[@"installedDescriptorIdentifiers"]', verification)
        self.assertIn('reportedIdentifiers.count <= 256', verification)
        self.assertIn("no filesystem-wide guess or duplicate publication was attempted", verification)

    def test_video_frame_count_handles_short_and_extreme_durations(self):
        source = (ROOT / "Daemon/LBPosterMediaBuilder.m").read_text()
        self.assertIn("NSInteger maxFrames = 400;", source)
        self.assertIn("duration >= ((double)maxFrames / (double)fps)", source)
        self.assertIn("MAX(1, (NSInteger)ceil(duration * (double)fps))", source)
        self.assertNotIn("MIN(400, MAX(2,", source)

        def frame_count(duration):
            fps = 15.0
            max_frames = 400
            if duration >= max_frames / fps:
                return max_frames
            return max(1, math.ceil(duration * fps))

        self.assertEqual(frame_count(0.01), 1)
        self.assertEqual(frame_count(1.0 / 15.0), 1)
        self.assertEqual(frame_count(0.1), 2)
        self.assertEqual(frame_count(400.0 / 15.0), 400)
        self.assertEqual(frame_count(1e300), 400)


if __name__ == "__main__":
    unittest.main()
