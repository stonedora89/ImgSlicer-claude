# ImgSlicer

ImgSlicer is a macOS SwiftUI tool for locating and slicing multiple photos from a single imported image or from a folder of images.

It is built for workflows where scanned or photographed sheets contain many individual photo areas. The app detects candidate crop regions, lets the user manually adjust every region, saves edits beside the source folder, and exports the final slices into a separate output directory.

## Features

- Import image files or folders.
- Automatically detect crop candidates in complex multi-row layouts.
- Adjust crop boxes manually on the canvas.
- Add crop boxes when automatic detection misses an item.
- Re-detect the current image using the current manual reference.
- Apply the current crop layout to the whole folder.
- Save per-image edit results automatically when switching images or starting processing.
- Export cropped slices without modifying the original images.
- Package a local macOS `.app` bundle with an installer helper script.

## Requirements

- macOS 14 or later
- Xcode / Swift toolchain with Swift 6 support

The app uses Swift Package Manager and links against:

- SwiftUI
- AppKit
- UniformTypeIdentifiers
- Vision

## Build And Run

From the project root:

```bash
swift build
```

Run the debug build:

```bash
.build/debug/ImgSlicer
```

## Package For macOS

Create a local `.app` bundle and zip package:

```bash
bash scripts/package-mac.sh
```

The generated package is written to `dist/`.

The package script creates:

- `ImgSlicer.app`
- `安装.command`
- `其他Mac打开说明.txt`
- A zip archive for sharing

## Notes About Distribution

The current packaging script uses ad-hoc signing for local testing. If macOS reports that the app is damaged after downloading or receiving it through another app, it is usually Gatekeeper quarantine on an unsigned and unnotarized app.

For normal public distribution, sign the app with an Apple Developer ID certificate and submit it for Apple notarization.

## Repository Contents

This repository is intentionally kept source-only.

Tracked:

- Swift source code in `Sources/`
- Swift Package manifest
- App resources
- Packaging scripts

Ignored:

- Build cache: `.build/`
- Python or local environments: `.venv/`
- Release artifacts: `dist/`
- Local photo folders and generated output
- Local design notes, mockups, and experiments

## Project Structure

```text
.
├── Package.swift
├── Sources/
│   └── ImgSlicer/
│       ├── AppShell.swift
│       ├── AppStore.swift
│       ├── FolderScanner.swift
│       ├── ImageProcessor.swift
│       ├── ImgSlicerApp.swift
│       ├── Models.swift
│       ├── Processing/
│       └── Resources/
└── scripts/
    ├── generate-icon.swift
    ├── package-full-project.sh
    └── package-mac.sh
```
