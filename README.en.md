# WeShot

A native macOS screenshot app built with Swift and AppKit. Select a region, annotate, translate, capture scrolling content, save, or pin an image from the menu bar or a shortcut.

[简体中文](README.md) · [Changelog](CHANGELOG.md) · [Product specification](SPEC.md)

Current version: **2.0.3 (build 17)**. Requires **macOS 15.2+ and Apple Silicon**.

## Use

Open the DMG, drag `WeShot.app` into **Applications**, and launch the installed copy.

1. Press the default shortcut `⌃⌘A` or choose **Capture Screen** from the menu bar. The shortcut is configurable.
2. Drag a selection, move it, or resize it with its eight handles.
3. Annotate, translate, capture scrolling content, save, or pin from the toolbar.
4. Press `Return` to finish and copy, or `Esc` to cancel. While editing text, `Esc` discards only the current draft.

| Feature | Behavior |
|---|---|
| Selection and colors | Freeform selection, multiple displays, pixel magnifier, RGB/HEX values; press `C` to copy HEX |
| Annotation | Rectangle, ellipse, arrow, pen, text, Unicode emoji, and mosaic; `⌘Z` to undo |
| Translation | Click the icon to translate the selection. Use the arrow to set separate targets for Chinese and other languages. The defaults are English and Simplified Chinese, respectively |
| Privacy redaction | The mosaic panel offers local detection of faces, names, phone numbers, and email addresses |
| Scrolling capture | Captures only the selected region and updates the preview; finishing copies the result and exits |
| Output and pins | PNG files, PNG/TIFF clipboard data; drag pins, zoom around the pointer with the scroll wheel, double-click to close |

An uncertain scrolling alignment preserves the current result and asks you to return to the interruption point. Sessions are limited to 40 frames or about 256 MiB of raw pixels. Animated pages, repeated content, or large fixed panels may not stitch.

WeShot is not a 1:1 implementation of WeChat screenshots. It has no separate OCR result window, system sharing, QR-code tool, or online AI entry point.

## Screen recording permission

On first capture, enable WeShot in **System Settings → Privacy & Security → Screen & System Audio Recording** and reopen it as directed by macOS.

Keep the installation location and signing identity consistent across updates. Migrating from an older ad-hoc build to the fixed signing identity may require one new grant. If the switch is enabled but capture is denied, first check that you are running the current copy in **Applications**. If an old grant still does not match, remove only the old WeShot entry and add the installed app again. Do not reset other applications' permissions.

macOS may attribute a permission check launched from a terminal or automation tool to that tool. Its result may differ from a normally launched WeShot instance.

## Local builds

Use Swift 6.1 or a compatible toolchain. From the repository directory:

```zsh
WESHOT_SIGNING_IDENTITY=- WESHOT_ALLOW_ADHOC=1 ./scripts/build_app.sh
open build/WeShot.app
```

This local testing mode does not require the maintainer's private key. Updating an ad-hoc build may require permission again; do not distribute it as an official update.

### Fixed signing and DMG packages

On the maintainer's Mac, the build script defaults to the public certificate pinned in `Resources/WeShotSigning.cer`. It finds the matching private key in the keychain and verifies the signer after signing. Updates retain this identity. A missing private key fails the build; the script neither generates a replacement nor silently falls back to ad-hoc signing.

```zsh
./scripts/build_app.sh release
./scripts/build_dmg.sh
```

The app, versioned DMG, and SHA-256 checksum are written to `build/`. The DMG script rejects ad-hoc applications and preserves existing packages of the same version. Increment the version and build number before another release.

- **The public `.cer` certificate may be committed.** It contains the public key, purpose, and validity dates, not the private key. It does not allow someone else to sign maintainer updates.
- **Never commit private keys, `.p12/.pfx` containers holding private keys, or export passwords.** This project's private key stays in the maintainer's login keychain. Back up the identity securely through Keychain Access before changing Macs.
- Fixed local signing is not Apple Developer ID signing or notarization and does not establish first-install trust on other Macs.

## Privacy

Capture and annotation are processed locally. Finishing writes to the system clipboard; saving writes a PNG. Text recognition and privacy detection use macOS Vision. Translation uses macOS Translation, which may download language packs on first use. The app does not use third-party capture, recognition, or translation services.

## Validation

Tests require a Swift toolchain that provides the `Testing` module, such as full Xcode.

```zsh
./scripts/test_all.sh
./scripts/test_system.sh
```

- `test_all.sh`: Swift tests, strict Release build, signing checks, self-test, and off-screen rendering.
- `test_system.sh`: real capture, scrolling capture, visible UI, output, shortcuts, and translation in an unlocked graphical session with effective permissions. It writes test images into `work/`; do not commit them.

See the [test report](docs/TEST_REPORT.md) for recorded results and limitations. Full-suite runs and focused assertion checks are reported separately.

## Layout

```text
Sources/WeShotApp/    AppKit UI, capture, shortcuts, and system services
Sources/WeShotCore/   Geometry, rendering, recognition, redaction, and stitching
Tests/               Core and application regression tests
Resources/           App configuration, icon source, and public signing certificate
scripts/             Build, packaging, and test scripts
```

See [Contributing](CONTRIBUTING.md) for development guidance. Released under the [MIT License](LICENSE).
