# WeShot

[简体中文](README.zh-CN.md)

WeShot is a standalone, native, open-source screenshot app for macOS, built with Swift and AppKit. Capture, annotation, translation, scrolling capture, and pinned images all run locally.

## Features

- Default global shortcut: `⌃⌘A`, configurable and persisted from the menu bar
- Start a freeform selection immediately; no window enumeration or edge snapping
- Move and resize selections, inspect pixels, and copy RGB/HEX colors
- Rectangle, ellipse, arrow, pen, text, emoji, and mosaic annotations
- Scrolling capture limited to the selected region with a live preview
- On-device text extraction and system translation rendered as a translucent layer on the source image
- Privacy redaction for faces, names, phone numbers, and email addresses
- PNG export, clipboard copy, and always-on-top pinned images
- Pinned images retain the captured size by default; use the mouse wheel to scale, drag to move, and double-click to close

Separate text-recognition windows, system sharing buttons, and presentation mode are intentionally out of scope.

## Privacy

- Screen images are processed in local memory unless you save them.
- Text extraction and privacy detection use macOS Vision.
- Translation uses macOS Translation. The system may download a language pack the first time a language pair is used.
- The app does not use third-party capture, recognition, or translation services.

## Requirements

- macOS 15.2 or later
- Apple Silicon
- Swift 6.1 or compatible Xcode Command Line Tools

On first capture, allow WeShot in **System Settings → Privacy & Security → Screen & System Audio Recording**, then restart the app.

## Build and run

```zsh
git clone https://github.com/SC-z/qsnap.git
cd qsnap
./scripts/build_app.sh
open build/WeShot.app
```

The bundle is created at `build/WeShot.app`.

## Use

1. Press `⌃⌘A`, or choose **Capture Screen** from the menu bar icon.
2. Drag to make a selection; move it or resize it with the control points.
3. Use the floating toolbar to annotate, translate, capture a scrolling region, save, or pin the image.
4. Press `Return` to finish and copy, or `Esc` to cancel.

## Test

The full test suite requires Swift Testing from Xcode. Command Line Tools alone can build the app but cannot run these tests.

```zsh
./scripts/test_all.sh
./scripts/test_system.sh
```

- `test_all.sh` runs Swift tests, a strict Release build, bundle-signing checks, self-tests, and off-screen rendering.
- `test_system.sh` verifies real capture, output, scrolling capture, visible UI, global shortcuts, and bidirectional translation in an unlocked graphical session with the required permissions.

## Layout

```text
Sources/WeShotCore/   Geometry, rendering, text detection, and image stitching
Sources/WeShotApp/    AppKit app, overlay, shortcut handling, and system services
Tests/                Swift Testing tests
Resources/            App configuration
scripts/              Build and test scripts
docs/                 Test report and sanitized development record
```

See [SPEC.md](SPEC.md) for product behavior and acceptance criteria, and [CONTRIBUTING.md](CONTRIBUTING.md) for contribution guidance. Released under the [MIT License](LICENSE).
