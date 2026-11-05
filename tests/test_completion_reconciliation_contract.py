"""Static and behavioral regression checks for the Preferences/daemon completion handshake."""
from pathlib import Path
import plistlib
import tempfile
import unittest
import uuid


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "Preferences" / "LBRootListController.m"
DAEMON = ROOT / "Daemon" / "main.m"


class CompletionReconciliationContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = SOURCE.read_text(encoding="utf-8")
        cls.daemon = DAEMON.read_text(encoding="utf-8")

    def test_request_id_is_persisted_before_request_file_is_published(self):
        start = self.source.index("static NSDictionary *LBQueueDaemonActionAndWait")
        end = self.source.index("static NSDictionary *LBQueueTendiesImportAndWait", start)
        helper = self.source[start:end]
        persist = helper.index('manifest[@"daemonRequestID"] = requestID;')
        manifest_write = helper.index("LBWriteManagedManifest(manifest, itemDirectory, error)")
        request_publish = helper.index("writeToFile:requestPath")
        notify = helper.index("CFNotificationCenterPostNotification", request_publish)
        self.assertLess(persist, manifest_write)
        self.assertLess(manifest_write, request_publish)
        self.assertLess(request_publish, notify)

    def test_import_completion_is_retained_until_manifest_commit(self):
        start = self.source.index("static NSDictionary *LBQueueDaemonActionAndWait")
        end = self.source.index("static NSDictionary *LBQueueTendiesImportAndWait", start)
        helper = self.source[start:end]
        self.assertIn(
            'if (!manifest || !itemDirectory) [NSFileManager.defaultManager removeItemAtPath:completionPath error:nil];',
            helper,
        )
        self.assertNotIn(
            '[NSFileManager.defaultManager removeItemAtPath:completionPath error:nil];\n            if (![completion isKindOfClass:NSDictionary.class]',
            helper,
        )

    def test_completion_reader_validates_regular_file_uuid_finished_and_action(self):
        start = self.source.index("static NSDictionary *LBReadValidatedCompletion")
        end = self.source.index("static BOOL LBAcknowledgeDaemonCompletion", start)
        reader = self.source[start:end]
        self.assertIn("!S_ISREG(st.st_mode) || S_ISLNK(st.st_mode) || st.st_size <= 0 || st.st_size > 1024 * 1024", reader)
        self.assertIn('![completion[@"requestID"] isEqualToString:requestID]', reader)
        self.assertIn('![completion[@"finished"] boolValue]', reader)
        self.assertIn("[completionAction isEqualToString:expectedAction]", reader)
        self.assertNotIn("removeItemAtPath", reader)

    def test_two_phase_commit_retains_request_id_in_phase_a_and_clears_after_ack(self):
        start = self.source.index("static BOOL LBFinalizeAndAcknowledgeManifestCompletion")
        end = self.source.index("static NSDictionary *LBQueueDaemonActionAndWait", start)
        helper = self.source[start:end]
        retain = helper.index('if (requestID.length) manifest[@"daemonRequestID"] = requestID;')
        phase_a_write = helper.index("if (!LBWriteManagedManifest(manifest, itemDirectory, error))")
        ack = helper.index("if (LBAcknowledgeDaemonCompletion(requestID))", phase_a_write)
        remove_id = helper.index('[manifest removeObjectForKey:@"daemonRequestID"];', ack)
        phase_b_write = helper.index("LBWriteManagedManifest(manifest, itemDirectory, nil);", remove_id)
        self.assertLess(retain, phase_a_write)
        self.assertLess(phase_a_write, ack)
        self.assertLess(ack, remove_id)
        self.assertLess(remove_id, phase_b_write)

    def test_both_import_paths_acknowledge_only_after_successful_manifest_write(self):
        self.assertEqual(
            self.source.count("LBFinalizeAndAcknowledgeManifestCompletion(manifest, itemDirectory, requestID,"),
            3,
        )
        self.assertEqual(
            self.source.count("if (!LBFinalizeAndAcknowledgeManifestCompletion(manifest, itemDirectory, requestID, &finalManifestError))"),
            2,
        )

    def test_malformed_completion_after_dispatch_keeps_item_recoverable(self):
        self.assertEqual(
            self.source.count("else if ([completion[@\"timedOut\"] boolValue] || (!completion && requestID.length))"),
            2,
        )

    def test_refresh_validates_request_uuid_before_constructing_completion_path(self):
        start = self.source.index("- (void)refreshLibraryTapped")
        end = self.source.index("- (void)picker:", start)
        refresh = self.source[start:end]
        uuid_check = refresh.index("BOOL requestIDIsValid = requestUUID &&")
        path_build = refresh.index('stringByAppendingPathComponent:[requestID stringByAppendingPathExtension:@"plist"]')
        self.assertLess(uuid_check, path_build)

    def test_refresh_rejects_symlink_and_oversized_completion_records(self):
        start = self.source.index("- (void)refreshLibraryTapped")
        end = self.source.index("- (void)picker:", start)
        refresh = self.source[start:end]
        self.assertIn("lstat(completionPath.fileSystemRepresentation, &completionStat)", refresh)
        self.assertIn("S_ISREG(completionStat.st_mode) && !S_ISLNK(completionStat.st_mode)", refresh)
        self.assertIn("completionStat.st_size <= 1024 * 1024", refresh)

    def test_refresh_retains_completion_when_manifest_write_fails(self):
        start = self.source.index("- (void)refreshLibraryTapped")
        end = self.source.index("- (void)picker:", start)
        refresh = self.source[start:end]
        commit = refresh.index("if (LBFinalizeAndAcknowledgeManifestCompletion(manifest, itemDirectory, requestID, &reconciliationWriteError))")
        failure = refresh.index("} else {", commit)
        self.assertIn("Keep both the durable pending request ID and completion record.", refresh[failure:])

    def test_refresh_handles_phase_a_to_phase_b_crash_window_as_cleanup_only(self):
        start = self.source.index("- (void)refreshLibraryTapped")
        end = self.source.index("- (void)picker:", start)
        refresh = self.source[start:end]
        self.assertIn('[status isEqualToString:@"registered-unverified"]', refresh)
        self.assertIn("Cleanup-only recovery for the Phase A -> Phase B crash window", refresh)
        self.assertIn("if (completionAbsent || (completion && LBAcknowledgeDaemonCompletion(requestID)))", refresh)

    def test_daemon_media_install_preserves_daemon_request_id_for_preferences_ack(self):
        start = self.daemon.index("static NSDictionary *LBProcessMediaInstallRequest")
        end = self.daemon.index("static void LBProcessRequests", start)
        media = self.daemon[start:end]
        self.assertNotIn('[manifest removeObjectForKey:@"daemonRequestID"]', media)


class TwoPhaseProtocolSimulationTests(unittest.TestCase):
    """Behavioral state-machine tests simulating interruptions across every protocol boundary."""

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.library = self.root / "Library"
        self.requests = self.root / "Requests"
        self.completed = self.root / "Completed"
        for d in (self.library, self.requests, self.completed):
            d.mkdir(parents=True)

    def tearDown(self):
        self.temp.cleanup()

    def _valid_uuid(self, value: str) -> bool:
        try:
            parsed = uuid.UUID(value)
        except Exception:
            return False
        return str(parsed).lower() == value.lower()

    def _write_manifest(self, item_dir: Path, manifest: dict, fail: bool = False) -> bool:
        if fail:
            return False
        data = plistlib.dumps(manifest, fmt=plistlib.FMT_BINARY)
        (item_dir / "manifest.plist").write_bytes(data)
        return True

    def _read_manifest(self, item_dir: Path) -> dict:
        return plistlib.loads((item_dir / "manifest.plist").read_bytes())

    def _read_validated_completion(self, request_id: str, expected_action: str):
        if not self._valid_uuid(request_id):
            return None, 211
        path = self.completed / f"{request_id}.plist"
        if not path.exists() and not path.is_symlink():
            return None, None
        if path.is_symlink() or not path.is_file():
            return None, 210
        size = path.stat().st_size
        if size <= 0 or size > 1024 * 1024:
            return None, 210
        try:
            data = plistlib.loads(path.read_bytes())
        except Exception:
            return None, 211
        if (
            not isinstance(data, dict)
            or data.get("requestID") != request_id
            or not data.get("finished")
            or data.get("action") != expected_action
        ):
            return None, 211
        return data, None

    def _acknowledge_completion(self, request_id: str, fail_delete: bool = False) -> bool:
        if not self._valid_uuid(request_id):
            return False
        path = self.completed / f"{request_id}.plist"
        if not path.exists() and not path.is_symlink():
            return True
        if path.is_symlink() or not path.is_file() or fail_delete:
            return False
        path.unlink()
        return True

    def _finalize_and_acknowledge(
        self,
        manifest: dict,
        item_dir: Path,
        request_id: str,
        fail_phase_a: bool = False,
        crash_after_phase_a: bool = False,
        fail_delete: bool = False,
        crash_after_delete: bool = False,
    ) -> bool:
        manifest["daemonRequestID"] = request_id
        if not self._write_manifest(item_dir, manifest, fail=fail_phase_a):
            return False
        if crash_after_phase_a:
            return True
        if self._acknowledge_completion(request_id, fail_delete=fail_delete):
            if crash_after_delete:
                return True
            manifest.pop("daemonRequestID", None)
            self._write_manifest(item_dir, manifest)
        return True

    def _refresh_reconcile_item(
        self,
        item_dir: Path,
        fail_phase_a: bool = False,
        crash_after_phase_a: bool = False,
    ) -> str:
        manifest = self._read_manifest(item_dir)
        status = manifest.get("status", "unknown")
        request_id = manifest.get("daemonRequestID")
        valid_id = isinstance(request_id, str) and self._valid_uuid(request_id)
        expected_action = (
            "install-media" if manifest.get("type") in ("image", "video") else "import-tendies"
        )
        if status in ("registering", "generating") and valid_id:
            completion, _ = self._read_validated_completion(request_id, expected_action)
            if completion:
                pending_status = status
                if completion.get("success"):
                    manifest["status"] = "registered-unverified"
                    manifest["installationState"] = (
                        "installed" if expected_action == "install-media" else "descriptors-published"
                    )
                    manifest["installationReport"] = completion.get("result", {})
                    manifest["installedDescriptorIdentifiers"] = completion.get("result", {}).get(
                        "installedDescriptorIdentifiers", []
                    )
                else:
                    manifest["status"] = "failed"
                    manifest["installationState"] = "failed"
                    manifest["installationError"] = completion.get("error", "failed")
                if self._finalize_and_acknowledge(
                    manifest,
                    item_dir,
                    request_id,
                    fail_phase_a=fail_phase_a,
                    crash_after_phase_a=crash_after_phase_a,
                ):
                    status = manifest["status"]
                else:
                    manifest["status"] = pending_status
                    manifest["installationState"] = "queued"
                    manifest["daemonRequestID"] = request_id
                    status = pending_status
        elif status in ("registered-unverified", "imported", "failed") and valid_id:
            completion_path = self.completed / f"{request_id}.plist"
            completion_absent = not completion_path.exists() and not completion_path.is_symlink()
            completion, _ = (
                (None, None)
                if completion_absent
                else self._read_validated_completion(request_id, expected_action)
            )
            if completion_absent or (completion and self._acknowledge_completion(request_id)):
                manifest.pop("daemonRequestID", None)
                self._write_manifest(item_dir, manifest)
        return status

    def test_interruption_after_phase_a_is_cleaned_up_idempotently_on_refresh(self):
        item_id = str(uuid.uuid4())
        request_id = str(uuid.uuid4())
        item_dir = self.library / item_id
        item_dir.mkdir()
        manifest = {
            "identifier": item_id,
            "type": "tendies-unvalidated",
            "status": "registering",
            "installationState": "queued",
            "daemonRequestID": request_id,
        }
        self._write_manifest(item_dir, manifest)
        completion = {
            "requestID": request_id,
            "action": "import-tendies",
            "finished": True,
            "success": True,
            "result": {"installedDescriptorIdentifiers": ["UUID-1"]},
        }
        completion_path = self.completed / f"{request_id}.plist"
        completion_path.write_bytes(plistlib.dumps(completion, fmt=plistlib.FMT_BINARY))

        # Simulate crash immediately after Phase A (terminal manifest written, completion still on disk).
        status = self._refresh_reconcile_item(item_dir, crash_after_phase_a=True)
        self.assertEqual(status, "registered-unverified")
        persisted = self._read_manifest(item_dir)
        self.assertEqual(persisted["status"], "registered-unverified")
        self.assertEqual(persisted["daemonRequestID"], request_id)
        self.assertTrue(completion_path.exists())

        # Subsequent refresh executes cleanup-only Phase B without re-running installation.
        status_after = self._refresh_reconcile_item(item_dir)
        self.assertEqual(status_after, "registered-unverified")
        cleaned = self._read_manifest(item_dir)
        self.assertEqual(cleaned["status"], "registered-unverified")
        self.assertNotIn("daemonRequestID", cleaned)
        self.assertFalse(completion_path.exists())

    def test_phase_a_write_failure_retains_completion_and_recovers_on_next_refresh(self):
        item_id = str(uuid.uuid4())
        request_id = str(uuid.uuid4())
        item_dir = self.library / item_id
        item_dir.mkdir()
        manifest = {
            "identifier": item_id,
            "type": "image",
            "status": "generating",
            "installationState": "queued",
            "daemonRequestID": request_id,
        }
        self._write_manifest(item_dir, manifest)
        completion_path = self.completed / f"{request_id}.plist"
        completion_path.write_bytes(
            plistlib.dumps(
                {
                    "requestID": request_id,
                    "action": "install-media",
                    "finished": True,
                    "success": True,
                    "result": {"installedDescriptorIdentifiers": ["UUID-MEDIA"]},
                },
                fmt=plistlib.FMT_BINARY,
            )
        )

        # Phase A write fails: completion and pending status must remain intact.
        status = self._refresh_reconcile_item(item_dir, fail_phase_a=True)
        self.assertEqual(status, "generating")
        self.assertTrue(completion_path.exists())
        self.assertEqual(self._read_manifest(item_dir)["status"], "generating")

        # Next refresh succeeds and acknowledges completion.
        status_retry = self._refresh_reconcile_item(item_dir, fail_phase_a=False)
        self.assertEqual(status_retry, "registered-unverified")
        self.assertFalse(completion_path.exists())
        final_manifest = self._read_manifest(item_dir)
        self.assertNotIn("daemonRequestID", final_manifest)
        self.assertEqual(final_manifest["installedDescriptorIdentifiers"], ["UUID-MEDIA"])

    def test_malformed_or_mismatched_completion_does_not_destroy_recovery(self):
        item_id = str(uuid.uuid4())
        request_id = str(uuid.uuid4())
        item_dir = self.library / item_id
        item_dir.mkdir()
        manifest = {
            "identifier": item_id,
            "type": "tendies-unvalidated",
            "status": "registering",
            "installationState": "queued",
            "daemonRequestID": request_id,
        }
        self._write_manifest(item_dir, manifest)
        completion_path = self.completed / f"{request_id}.plist"

        # 1. Malformed bytes on disk: item stays in 'registering' and file is not deleted.
        completion_path.write_bytes(b"corrupted-incomplete-write")
        self.assertEqual(self._refresh_reconcile_item(item_dir), "registering")
        self.assertTrue(completion_path.exists())
        self.assertEqual(self._read_manifest(item_dir)["daemonRequestID"], request_id)

        # 2. Mismatched requestID or action: rejected without clobbering state.
        completion_path.write_bytes(
            plistlib.dumps(
                {
                    "requestID": str(uuid.uuid4()),
                    "action": "import-tendies",
                    "finished": True,
                    "success": True,
                },
                fmt=plistlib.FMT_BINARY,
            )
        )
        self.assertEqual(self._refresh_reconcile_item(item_dir), "registering")
        self.assertEqual(self._read_manifest(item_dir)["status"], "registering")

        # 3. Valid completion arrives/replaces file: item reconciles cleanly.
        completion_path.write_bytes(
            plistlib.dumps(
                {
                    "requestID": request_id,
                    "action": "import-tendies",
                    "finished": True,
                    "success": True,
                    "result": {"installedDescriptorIdentifiers": ["RECOVERED-UUID"]},
                },
                fmt=plistlib.FMT_BINARY,
            )
        )
        self.assertEqual(self._refresh_reconcile_item(item_dir), "registered-unverified")
        self.assertFalse(completion_path.exists())
        self.assertNotIn("daemonRequestID", self._read_manifest(item_dir))


if __name__ == "__main__":
    unittest.main()
