from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]


class SQLiteRegistrationContractTests(unittest.TestCase):
    def setUp(self):
        self.installer_source = (ROOT / "Daemon/LBPosterBoardInstaller.m").read_text()
        self.media_builder_source = (ROOT / "Daemon/LBPosterMediaBuilder.m").read_text()
        self.makefile = (ROOT / "Makefile").read_text()
        self.project_yml = (ROOT / "project.yml").read_text()

    def test_installer_imports_sqlite3(self):
        self.assertIn("#import <sqlite3.h>", self.installer_source)

    def test_installer_defines_transactional_sqlite_helpers(self):
        for token in (
            "LBRegisterDescriptorsInSQLiteDatabase",
            "LBRollbackDescriptorsInSQLiteDatabase",
            "LBCountRegisteredDescriptorsInSQLite",
            "sqlite3_open_v2",
            "sqlite3_busy_timeout",
            "PRAGMA journal_mode=WAL;",
            "BEGIN IMMEDIATE;",
            "COMMIT;",
            "ROLLBACK;",
        ):
            with self.subTest(token=token):
                self.assertIn(token, self.installer_source)

    def test_sqlite_targets_poster_and_poster_role_membership_tables(self):
        for token in (
            "INSERT OR REPLACE INTO poster (UUID, providerId)",
            "INSERT OR REPLACE INTO posterRoleMembership (posterUUID, roleId, roleSortKey)",
            "PRPosterRoleLockScreen",
            "SELECT COALESCE(MAX(roleSortKey), 0) + 1 FROM posterRoleMembership WHERE roleId = 'PRPosterRoleLockScreen';",
            "DELETE FROM posterRoleMembership WHERE posterUUID = ?;",
            "DELETE FROM poster WHERE UUID = ?;",
        ):
            with self.subTest(token=token):
                self.assertIn(token, self.installer_source)

    def test_installer_integrates_sqlite_check_and_rollback(self):
        self.assertIn("PBFPosterExtensionDataStoreSQLiteDatabase.sqlite3", self.installer_source)
        self.assertIn("sqliteUpdated ? @\"filesystem-and-sqlite-registered\" : @\"filesystem-registration-only\"", self.installer_source)
        self.assertIn("LBRollbackDescriptorsInSQLiteDatabase(sqlitePath, publishedIdentifiers)", self.installer_source)

    def test_media_builder_declares_and_enforces_cumulative_asset_budget(self):
        self.assertIn("LBMaxCumulativeVideoAssetBytes", self.media_builder_source)
        self.assertIn("Cumulative video asset size exceeded", self.media_builder_source)

    def test_build_system_links_sqlite3(self):
        self.assertIn("lumenboardd_LIBRARIES = z sqlite3", self.makefile)
        self.assertIn("- sdk: libsqlite3.tbd", self.project_yml)


if __name__ == "__main__":
    unittest.main()
