# Build, package, and device validation

> **Current-state note (0.1.0-24):** the detailed build record below is a historical 0.1.0-9 snapshot, not evidence for this working tree. The active candidate is maintained on `fix/rootless-deb-installation`; Debian version and Preferences `CFBundleVersion` are 0.1.0-24 and 24. The audited local changes have not been built in the current environment because Theos and an iOS SDK are absent. Native PosterBoard gallery recognition and wallpaper application remain device-only checks.

## Current candidate contract

- Package: `com.iuyghi.lumenboard`
- Debian version: `0.1.0-24`
- Preferences `CFBundleVersion`: `23`
- Architecture: `iphoneos-arm64`
- Working branch: `fix/rootless-deb-installation`
- Main branch remains separate and unchanged.
- The active workflow validates portable tests, macOS XCTest, rootless package construction and archive contents.
- `index.xml` is emitted as a binary property list; the empty Floating layer is a neutral 1×1 canvas. CAML references and metadata types receive structural checks. This source-based format work does not establish actual iPhone installation or PosterBoard rendering.


## Historical verified candidate 0.1.0-9 (superseded)

- Package: `com.iuyghi.lumenboard`
- Version: `0.1.0-9`
- Architecture: `iphoneos-arm64`
- Branch: `fix/rootless-deb-installation`
- Commit: `7ac16e7ef6cc759e7d6c96b0069e3ca3df175f85`
- CI run: [41193825292](https://github.com/ouuhh7/LumenBoard/actions/runs/41193825292) — all three jobs passed
- Native XCTest: 39 passed
- Portable Python suite: 68 passed
- Maintainer-script lifecycle tests: passed
- Debian package SHA-256: `67947c2f2106ce8b8dfb3dd372abdf9649c09e06f182d49201fd91f31ce64c50`

Package checks cover Debian archive and metadata, rootless paths, Mach-O arm64 architecture/signatures, Preferences bundle Info.plist, launchd plist, script syntax, and the maintainer-script lifecycle. The package was downloaded from the successful workflow artifact and independently extracted and checked. CI does not prove installation on Dopamine or PosterBoard rendering.

## Corrections included in 0.1.0-9

- Removed unavailable hard-coded `grep` and `sleep` dependencies from maintainer scripts.
- Moved service registration to Dopamine's `user/foreground` launchd domain.
- Made repeated dpkg configuration idempotent: status 37 is accepted only with the `service already bootstrapped` diagnostic.
- Removed the synchronous process-state check after `kickstart`; launchd startup is asynchronous, and a successful kickstart is treated only as acceptance of the start request.
- Migrated and stopped any legacy `system/com.iuyghi.lumenboardd` registration before starting the foreground service.
- Made `prerm` stop both current and legacy service domains and refuse package removal/upgrade if a service remains registered.
- Adjusted descriptor/completion ownership handling for a daemon running as the foreground mobile user; do not assume root `chown` rights.
- Replaced stale baseline tests that incorrectly asserted the daemon was not packaged. CI now tests the active package contract and runs portable Python tests.

## Device validation still required

1. Confirm dpkg reaches configured state without maintainer-script errors.
2. Confirm `launchctl print user/foreground/com.iuyghi.lumenboardd` shows the expected service and inspect `/var/mobile/Library/Logs/LumenBoard-daemon.log`.
3. Confirm any stale `system/com.iuyghi.lumenboardd` registration is absent after upgrade.
4. Import a known-good descriptor-format `.tendies` fixture from Settings > LumenBoard.
5. Confirm the daemon writes a successful completion and the UI reports descriptor publication, not verified application.
6. Confirm the item appears in native PosterBoard Collections, opens in preview, can be selected, and renders on Lock Screen/Home Screen.
7. Reboot/respring and verify persistence and daemon relaunch.
8. Test repeated dpkg configure/upgrade and package removal. Verify removal stops both service domains without deleting user wallpaper data or unrelated PosterBoard descriptors.

Capture dpkg output, launchctl print output for both domains, daemon log, the managed item manifest, and screenshots of Collections/preview/applied wallpaper. Redact device identifiers before sharing logs.

## Evidence boundary

- Build and automated tests: passed on the exact source commit listed above.
- Installation on the user's iPhone: not performed by the assistant.
- Native gallery visibility, selection, actual wallpaper rendering, persistence after reboot, and device-side upgrade/removal: not yet demonstrated.
- Photo/video descriptor generation and publication code exists; gallery visibility, selection, and actual rendering remain unverified on the target iPhone.
- Removing a source from LumenBoard's local library does not remove a published PosterBoard descriptor.

Treat the package as CI-verified, not device-validated.

## Local build

On macOS Theos builds, the build helper rewrites the package data archive with
`dpkg-deb --root-owner-group` and verifies numeric UID/GID 0 for every payload
entry. `dpkg-deb --contents` owner names are insufficient for this check: a
macOS archive may display `root/wheel` while storing the runner's numeric
ownership. The CI package verification applies the same normalization and
numeric header check before publishing the artifact.

On a supported Theos/macOS environment:

```sh
make clean package FINALPACKAGE=1
dpkg-deb --info packages/*.deb
dpkg-deb --contents packages/*.deb
```