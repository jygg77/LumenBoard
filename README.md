# LumenBoard — rootless iOS 16 PosterBoard importer

LumenBoard is a rootless jailbreak package targeting arm64 iOS 16, including iPhone X / iOS 16.7.16. The current package includes a PreferenceLoader pane, native `.tendies` validation, a launchd-managed daemon, and a descriptor publisher for the iOS 16 Collections PosterBoard store.

## Current status

Current package candidate: **0.1.0-19** (`iphoneos-arm64`). The Debian revision and Preferences `CFBundleVersion` are synchronized at 19. LumenBoard has a native Objective-C media descriptor generator adapted from the public PosterForge format. Imported photos and videos are queued for processing; the daemon verifies the managed source SHA-256, generates a descriptor tree, publishes it through the staged/collision-checked installer, revalidates the descriptor files at their final PosterBoard paths, and writes the two observed PosterBoard refresh preference flags. This confirms filesystem registration only—not a PosterBoard reload, gallery display, or wallpaper application.

The generated descriptor includes provider descriptor and role identifiers, providerInfo.plist, provider contents user-info, Wallpaper.plist, Background/Floating Core Animation bundles, index.xml, main.caml, and JPEG assets. Video input is decoded into a looping sequence capped at 400 frames at 15 fps. Static images are supported. Optional Home blur is represented by a blurred Background layer and sharp Floating layer, but the current UI defaults this option off.

The generated `index.xml` files are binary property lists, matching the public iOS 16 PosterForge writer despite the `.xml` suffix, and include `unitsInPixelsInPlayer`. The empty Floating layer uses a neutral 1×1 canvas. The installer validates CAML XML and its referenced assets, validates plist roots before rewriting IDs, and recognizes ordered descriptor groups so IDs preserve their requested order. These are source-informed structural decisions; PosterBoard's private schema and actual gallery rendering on iOS 16.7.16 still require device verification.

The existing .tendies path remains separate: it validates ZIP paths and descriptor structure, rewrites identifiers, publishes descriptor directories transactionally, and performs read-only reconciliation. The native media path reuses the same descriptor validation, identifier allocation, staging, publication and rollback logic rather than bypassing it.

CI must validate the native daemon and Preferences build, Python contract tests, package contents and rootless paths. This is not proof that PosterBoard accepts or renders every generated descriptor on iOS 16.7.16. Native gallery visibility, preview, selection, Lock Screen rendering and Home Screen rendering still require physical-device verification. No device installation or runtime test is performed by CI.

Known limitations: no in-app crop/zoom editor yet; no UI control for Home blur yet; no native removal of published descriptors; no claim of verified gallery rendering. Video generation is resource-intensive and capped at 400 frames. Source files are preserved in LumenBoard's managed library.

## Build and package requirements

- A supported Theos environment: macOS with Xcode/iOS SDK, or Linux with the official Theos cross-toolchain and a suitable iOS SDK (the public Theos SDK repository includes iOS 16.5),
- Theos configured in `THEOS`,
- the applicable rootless packaging tools and PreferenceLoader headers/framework.

The original local build attempt on 2026-10-29 is documented in [`docs/THEOS_BUILD_REPORT_2026-10-29.md`](docs/THEOS_BUILD_REPORT_2026-10-29.md). That environment lacked Theos/SDK; the package is now built in GitHub Actions using a supported macOS/Theos toolchain.

Then run:

```sh
make clean package FINALPACKAGE=1
```

The package is emitted under `packages/`. The current aggregate target compiles and stages both the Preferences bundle and the native daemon. Use the GitHub Actions artifact for the exact verified CI build; local builds require a supported Theos installation and iOS SDK.

## Portable validation tests

Python 3.11+ is sufficient; no third-party Python package is needed:

```sh
python3 -m unittest discover -s tests -v
python3 tools/tendies_inspect.py --help
python3 tools/static_wallpaper_builder.py --help
python3 tools/descriptor_consistency.py --help
python3 tools/static_descriptor_generator.py --help
```

Inspect a user-supplied archive without extracting it:

```sh
python3 tools/tendies_inspect.py path/to/wallpaper.tendies
```

Extract only a descriptor-format archive into a new/empty directory:

```sh
python3 tools/tendies_inspect.py path/to/wallpaper.tendies --extract /tmp/lb-inspected
```

The inspector is a development/test utility; the Preferences app does not shell out to Python. Do not interpret a successful ZIP inspection as proof that the wallpaper is compatible with PosterBoard.

## Repository/publication status

The public GitHub repository is `ouuhh7/LumenBoard`; active fixes and release validation are maintained on `fix/rootless-deb-installation`. The default branch `main` is kept separate from this work.

## Descriptor consistency checker

`tools/descriptor_consistency.py` performs a read-only structural check over an extracted descriptor-format tree. It cross-checks observed descriptor identifiers and provider user-info references, wallpaper bundle paths, `.ca` layer references, index plist targets, CAML XML syntax and referenced assets. It reports only structural consistency; it does not prove compatibility with PosterBoard or replace a real iOS 16 reference. See `docs/DESCRIPTOR_VALIDATOR.md`.

Example after extracting a verified reference archive:

```sh
python3 tools/descriptor_consistency.py /tmp/lb-reference/descriptors
```

## Experimental static-image template transformer

`tools/static_wallpaper_builder.py` is a conservative, developer-only prototype. It does **not** synthesize a new PosterBoard schema. It requires a `.wallpaper` bundle extracted from a known-good iOS 16 descriptor fixture, then replaces one existing PNG/JPEG asset that is referenced by `main.caml`, `assetManifest.caml`, or `index.xml`. The source and target extensions must match. It preserves the reference CAML and plist files, stages output beside the destination, and refuses to overwrite existing paths.

Example (only after obtaining and inspecting a lawful known-good iOS 16 fixture):

```sh
python3 tools/tendies_inspect.py /path/to/known-good-ios16-descriptor.tendies --extract /tmp/lb-reference
python3 tools/static_wallpaper_builder.py \
  --template-bundle /tmp/lb-reference/descriptors/UUID/versions/1/contents/NAME.wallpaper \
  --asset 'BACKGROUND.ca/assets/existing.png' \
  --image /path/to/replacement.png \
  --output /tmp/LumenBoard-Candidate.wallpaper
```

The example paths after `descriptors/UUID/...` are placeholders and must be replaced with the exact tree and asset path present in the supplied archive. The tool produces a sibling `.report.json` sidecar. It does not rewrite descriptor UUIDs, wallpaper IDs, `providerInfo.plist`, `Wallpaper.plist`, provider user-info, or references outside the `.wallpaper` bundle. Consequently, this transformer's output is an offline candidate for comparison only—not an installable wallpaper descriptor and not proof of iOS 16.7.16 compatibility.

For this prototype, supported source formats are PNG and JPEG, with basic signature/dimension checks. This tool does not implement video, CAML generation, `.tendies` runtime import, native installation/removal, or PosterBoard refresh. These limitations do not describe the separate native daemon path.


## Experimental full static descriptor generator

`tools/static_descriptor_generator.py` generates a complete local descriptor candidate from a JPEG using the public MIT-licensed PosterForge implementation as a technical reference. It creates the root metadata, `providerInfo.plist`, provider user-info, `Wallpaper.plist`, background/floating `.ca` bundles, CAML, manifests and index plists; it checks for ID collisions and runs the descriptor validator before atomically publishing the output.

```sh
python3 tools/static_descriptor_generator.py /path/to/photo.jpg /tmp/lb-candidates --title "My Static Poster"
python3 tools/descriptor_consistency.py /tmp/lb-candidates
```

This Python generator is an offline candidate-generation tool and is not the runtime import path. A public iOS 16 dump from an iPhone 12 was found as a research lead, but the exact build/native rendering on iOS 16.7.16 and redistribution rights for its Apple assets are not verified; no third-party fixture is included. The generated empty `assetManifest.caml` is an unverified schema choice and must be compared with a real reference. It does not itself write to PosterBoard or refresh the native gallery. See `docs/ENGINE_PHASE_REPORT.md` for the fixture search, source attribution and three validation levels.


The runtime importer writes descriptor directories directly into PosterBoard's iOS 16 Collections store and performs a read-only structural check at the final destination after publication. It preserves the existing `com.apple.PosterBoard.unprotectedUserDefaults.plist` dictionary while setting `PBF_LOCALE_DID_CHANGE` and `PBF_RESET_FILE_PROTECTIONS`, and refuses to overwrite a malformed or non-regular preferences file. It does not terminate, signal, or restart PosterBoard. The app reports refresh flags separately from descriptor publication; a device restart may be needed before PosterBoard reloads the store. Filesystem verification does not prove native gallery visibility, selection, or wallpaper application.
