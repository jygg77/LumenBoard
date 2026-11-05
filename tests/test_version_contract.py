"""Keep Debian, Preferences, CI, and project documentation versions aligned."""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]
EXPECTED_DEBIAN_VERSION = "0.1.0-20"
EXPECTED_BUNDLE_VERSION = "20"


class VersionContractTests(unittest.TestCase):
    def test_control_version_matches_candidate(self):
        control = (ROOT / "control").read_text(encoding="utf-8")
        match = re.search(r"(?m)^Version:\s*(\S+)\s*$", control)
        self.assertIsNotNone(match)
        self.assertEqual(match.group(1), EXPECTED_DEBIAN_VERSION)

    def test_preferences_bundle_version_matches_candidate(self):
        info = (ROOT / "Preferences" / "Info.plist").read_text(encoding="utf-8")
        match = re.search(r"<key>CFBundleVersion</key>\s*<string>([^<]+)</string>", info)
        self.assertIsNotNone(match)
        self.assertEqual(match.group(1), EXPECTED_BUNDLE_VERSION)

    def test_build_workflow_expects_current_debian_version(self):
        workflow = (ROOT / ".github" / "workflows" / "bootstrap-and-build.yml").read_text(encoding="utf-8")
        self.assertIn(f'test "$VERSION" = "{EXPECTED_DEBIAN_VERSION}"', workflow)

    def test_native_workflow_expects_same_versions(self):
        workflow = (ROOT / ".github" / "workflows" / "native-validator.yml").read_text(encoding="utf-8")
        self.assertIn(f'dpkg-deb -f "$DEB" Version)" = "{EXPECTED_DEBIAN_VERSION}"', workflow)
        self.assertIn("CFBundleVersion", workflow)
        self.assertIn(f'"{EXPECTED_BUNDLE_VERSION}"', workflow)

    def test_current_documentation_matches_candidate(self):
        readme = (ROOT / "README.md").read_text(encoding="utf-8")
        architecture = (ROOT / "docs" / "ARCHITECTURE.md").read_text(encoding="utf-8")
        build = (ROOT / "docs" / "BUILD_AND_DEVICE_VALIDATION.md").read_text(encoding="utf-8")
        self.assertIn(f"Current package candidate: **{EXPECTED_DEBIAN_VERSION}**", readme)
        self.assertIn(f"Current CI candidate: `{EXPECTED_DEBIAN_VERSION}`", architecture)
        self.assertIn(f"Current-state note ({EXPECTED_DEBIAN_VERSION})", build)
        self.assertIn(f"Debian version and Preferences `CFBundleVersion` are {EXPECTED_DEBIAN_VERSION} and {EXPECTED_BUNDLE_VERSION}", build)


if __name__ == "__main__":
    unittest.main()
