import plistlib
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
import descriptor_consistency as validator


def make_fixture(root: Path, folder_name="AABBCCDD-0000-4000-8000-000000000001", descriptor_id="12345", wallpaper_id=12345, wallpaper_name=None):
    descriptor = root / folder_name
    contents = descriptor / "versions" / "1" / "contents"
    wallpaper_name = wallpaper_name or f"{folder_name}.Custom.wallpaper"
    wallpaper = contents / wallpaper_name
    (wallpaper / "PF_Background.ca" / "assets").mkdir(parents=True)
    (wallpaper / "PF_Floating.ca").mkdir(parents=True)

    (descriptor / "com.apple.posterkit.provider.descriptor.identifier").write_text(str(descriptor_id), encoding="utf-8")
    (descriptor / "com.apple.posterkit.role.identifier").write_text("PRPosterRoleLockScreen", encoding="utf-8")
    (descriptor / "providerInfo.plist").write_bytes(plistlib.dumps({"kConfigurationLastUseDateKey": "synthetic-fixture"}, fmt=plistlib.FMT_BINARY))

    metadata = {
        "appearanceAware": True,
        "assets": {"lockAndHome": {"default": {
            "backgroundAnimationFileName": "PF_Background.ca",
            "floatingAnimationFileNameKey": "PF_Floating.ca",
            "identifier": wallpaper_id,
            "name": "Synthetic test only",
            "type": "LayeredAnimation",
        }}},
        "contentVersion": 2.01,
        "family": "Marble",
        "identifier": wallpaper_id,
        "logicalScreenClass": "375w-812h@3x~iphone",
        "name": "Synthetic test only",
        "preferredProminentColor": {"dark": "#000000", "default": "#FFFFFF"},
        "version": 1,
    }
    (wallpaper / "Wallpaper.plist").write_bytes(plistlib.dumps(metadata, fmt=plistlib.FMT_BINARY))
    user_info = {
        "posterEnvironmentOverrides": b"{}",
        "wallpaperRepresentingFileName": wallpaper_name,
        "wallpaperRepresentingIdentifier": str(wallpaper_id),
    }
    contents.mkdir(parents=True, exist_ok=True)
    (contents / "com.apple.posterkit.provider.contents.userInfo").write_bytes(plistlib.dumps(user_info, fmt=plistlib.FMT_BINARY))

    for name in ("PF_Background.ca", "PF_Floating.ca"):
        ca = wallpaper / name
        ca.mkdir(parents=True, exist_ok=True)
        caml = '<document><image src="assets/hero.png"/></document>' if name == "PF_Background.ca" else "<document/>"
        (ca / "main.caml").write_text(caml, encoding="utf-8")
        (ca / "assetManifest.caml").write_text("<dict/>", encoding="utf-8")
        (ca / "index.xml").write_bytes(plistlib.dumps({
            "assetManifest": "assetManifest.caml",
            "documentHeight": 2556,
            "documentResizesToView": True,
            "documentWidth": 1179,
            "geometryFlipped": False,
            "rootDocument": "main.caml",
            "scalesToFitInPlayer": True,
            "unitsInPixelsInPlayer": True,
        }, fmt=plistlib.FMT_BINARY))
    (wallpaper / "PF_Background.ca" / "assets" / "hero.png").write_bytes(b"synthetic referenced asset")
    return descriptor, wallpaper, contents


class DescriptorConsistencyTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name) / "descriptors"
        self.root.mkdir()
        self.descriptor, self.wallpaper, self.contents = make_fixture(self.root)

    def tearDown(self):
        self.temp.cleanup()

    def test_checks_posterforge_shaped_tree_without_warnings(self):
        report = validator.validate_descriptors_root(self.root)
        self.assertEqual(report["status"], "passes-structural-checks", report)
        self.assertEqual(report["errors"], [])
        self.assertEqual(report["descriptors"][0]["wallpaper_identifier"], 12345)
        self.assertEqual(report["scope"], "structural-consistency-only-not-a-PosterBoard-compatibility-test")

    def test_reports_logical_screen_class_from_wallpaper_metadata(self):
        report = validator.validate_descriptors_root(self.root)
        self.assertEqual(report["descriptors"][0]["logical_screen_class"], "375w-812h@3x~iphone")

    def test_expected_screen_class_match_has_no_warning(self):
        report = validator.validate_descriptors_root(self.root, "375w-812h@3x~iphone")
        self.assertEqual(report["status"], "passes-structural-checks")
        self.assertEqual(report["expected_screen_class"], "375w-812h@3x~iphone")

    def test_expected_screen_class_mismatch_is_explicit_warning(self):
        report = validator.validate_descriptors_root(self.root, "810w-1080h@2x~ipad")
        self.assertEqual(report["status"], "passes-with-warnings")
        self.assertTrue(any("does not match requested target" in issue for issue in report["warnings"]))
        self.assertEqual(report["descriptors"][0]["logical_screen_class"], "375w-812h@3x~iphone")

    def test_rejects_malformed_logical_screen_class(self):
        path = self.wallpaper / "Wallpaper.plist"
        metadata = plistlib.loads(path.read_bytes())
        metadata["logicalScreenClass"] = "../ipad"
        path.write_bytes(plistlib.dumps(metadata))
        report = validator.validate_descriptors_root(self.root)
        self.assertEqual(report["status"], "invalid")
        self.assertTrue(any("logicalScreenClass is missing or malformed" in issue for issue in report["errors"]))

    def test_rejects_malformed_expected_screen_class_argument(self):
        with self.assertRaisesRegex(validator.ConsistencyError, "expected screen class"):
            validator.validate_descriptors_root(self.root, "../ipad")

    def test_reports_mismatch_between_wallpaper_and_provider_userinfo(self):
        path = self.contents / "com.apple.posterkit.provider.contents.userInfo"
        data = plistlib.loads(path.read_bytes())
        data["wallpaperRepresentingIdentifier"] = "99999"
        path.write_bytes(plistlib.dumps(data))
        report = validator.validate_descriptors_root(self.root)
        self.assertEqual(report["status"], "invalid")
        self.assertTrue(any("does not match Wallpaper.plist" in issue for issue in report["errors"]))

    def test_reports_missing_asset_referenced_by_caml(self):
        asset = self.wallpaper / "PF_Background.ca" / "assets" / "hero.png"
        asset.unlink()
        report = validator.validate_descriptors_root(self.root)
        self.assertTrue(any("referenced asset is missing" in issue for issue in report["errors"]))

    def test_rejects_traversal_in_caml_asset_reference(self):
        caml = self.wallpaper / "PF_Background.ca" / "main.caml"
        caml.write_text('<document><image src="assets/../outside.png"/></document>', encoding="utf-8")
        report = validator.validate_descriptors_root(self.root)
        self.assertTrue(any("unsafe asset reference" in issue for issue in report["errors"]))

    def test_reports_invalid_index_root_document_reference(self):
        path = self.wallpaper / "PF_Background.ca" / "index.xml"
        data = plistlib.loads(path.read_bytes())
        data["rootDocument"] = "../../evil.caml"
        path.write_bytes(plistlib.dumps(data))
        report = validator.validate_descriptors_root(self.root)
        self.assertTrue(any("single path component" in issue for issue in report["errors"]))

    def test_reports_dangling_asset_manifest_as_warning_not_proof_of_compatibility(self):
        path = self.wallpaper / "PF_Floating.ca" / "assetManifest.caml"
        path.unlink()
        report = validator.validate_descriptors_root(self.root)
        self.assertEqual(report["status"], "passes-with-warnings")
        self.assertTrue(any("assetManifest target is absent" in issue for issue in report["warnings"]))

    def test_reports_duplicate_descriptor_identifier(self):
        make_fixture(self.root, folder_name="SECOND-DESCRIPTOR", descriptor_id="12345", wallpaper_id=54321)
        report = validator.validate_descriptors_root(self.root)
        self.assertTrue(any("duplicate descriptor identifier 12345" in issue for issue in report["errors"]))

    def test_reports_duplicate_wallpaper_identifier(self):
        make_fixture(self.root, folder_name="SECOND-DESCRIPTOR", descriptor_id="54321", wallpaper_id=12345)
        report = validator.validate_descriptors_root(self.root)
        self.assertTrue(any("duplicate wallpaper identifier 12345" in issue for issue in report["errors"]))

    def test_reports_bundle_filename_mismatch(self):
        path = self.contents / "com.apple.posterkit.provider.contents.userInfo"
        data = plistlib.loads(path.read_bytes())
        data["wallpaperRepresentingFileName"] = "other.wallpaper"
        path.write_bytes(plistlib.dumps(data))
        report = validator.validate_descriptors_root(self.root)
        self.assertTrue(any("does not match actual bundle name" in issue for issue in report["errors"]))

    def test_rejects_malformed_caml_xml(self):
        (self.wallpaper / "PF_Background.ca" / "main.caml").write_text("<document>", encoding="utf-8")
        report = validator.validate_descriptors_root(self.root)
        self.assertTrue(any("not well-formed XML" in issue for issue in report["errors"]))

    def test_rejects_symlink_anywhere_in_tree(self):
        target = Path(self.temp.name) / "outside.txt"
        target.write_text("outside", encoding="utf-8")
        (self.wallpaper / "PF_Background.ca" / "assets" / "unsafe-link.png").symlink_to(target)
        report = validator.validate_descriptors_root(self.root)
        self.assertTrue(any("symlink rejected" in issue for issue in report["errors"]))

    def test_requires_existing_descriptors_root(self):
        with self.assertRaisesRegex(validator.ConsistencyError, "existing"):
            validator.validate_descriptors_root(self.root / "missing")

    def test_rejects_non_descriptor_tree(self):
        empty = Path(self.temp.name) / "empty"
        empty.mkdir()
        report = validator.validate_descriptors_root(empty)
        self.assertEqual(report["status"], "invalid")
        self.assertTrue(any("no descriptor directories" in issue for issue in report["errors"]))

    def test_accepts_caml_layer_with_omitted_asset_manifest(self):
        floating_ca = self.wallpaper / "PF_Floating.ca"
        (floating_ca / "index.xml").write_bytes(plistlib.dumps({
            "rootDocument": "main.caml",
        }, fmt=plistlib.FMT_BINARY))
        (floating_ca / "assetManifest.caml").unlink(missing_ok=True)
        report = validator.validate_descriptors_root(self.root)
        self.assertEqual(report["status"], "passes-structural-checks", report)
        self.assertEqual(report["errors"], [])

    def test_accepts_percent_encoded_caml_asset_references_with_spaces(self):
        bg_ca = self.wallpaper / "PF_Background.ca"
        (bg_ca / "main.caml").write_text('<document><image src="assets/my%20hero%20image.png"/></document>', encoding="utf-8")
        (bg_ca / "assets" / "my hero image.png").write_bytes(b"image data")
        report = validator.validate_descriptors_root(self.root)
        self.assertEqual(report["status"], "passes-structural-checks", report)
        self.assertEqual(report["errors"], [])

    def test_accepts_foreground_layer_if_declared(self):
        fg_ca = self.wallpaper / "PF_Foreground.ca"
        fg_ca.mkdir(parents=True)
        (fg_ca / "main.caml").write_text("<document/>", encoding="utf-8")
        (fg_ca / "index.xml").write_bytes(plistlib.dumps({
            "rootDocument": "main.caml",
        }, fmt=plistlib.FMT_BINARY))
        wplist_path = self.wallpaper / "Wallpaper.plist"
        wplist = plistlib.loads(wplist_path.read_bytes())
        wplist["assets"]["lockAndHome"]["default"]["foregroundAnimationFileName"] = "PF_Foreground.ca"
        wplist_path.write_bytes(plistlib.dumps(wplist, fmt=plistlib.FMT_BINARY))
        report = validator.validate_descriptors_root(self.root)
        self.assertEqual(report["status"], "passes-structural-checks", report)
        self.assertIn("PF_Foreground.ca", report["descriptors"][0]["ca_bundles"])


if __name__ == "__main__":
    unittest.main()
