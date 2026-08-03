# IOS-port-OrcaSlicer

**Community iOS / mobile port of [OrcaSlicer](https://github.com/OrcaSlicer/OrcaSlicer)** — branch `ios-port`.

This fork is **not** a second slicer and **not** the official OrcaSlicer product page.  
It is engineering work to run the **official `libslic3r` engine** on Apple platforms with a **SwiftUI shell**.

| | |
|---|---|
| **Upstream** | [OrcaSlicer/OrcaSlicer](https://github.com/OrcaSlicer/OrcaSlicer) (AGPL-3.0) |
| **This fork** | [S117X/IOS-port-OrcaSlicer](https://github.com/S117X/IOS-port-OrcaSlicer) |
| **Working branch** | [`ios-port`](https://github.com/S117X/IOS-port-OrcaSlicer/tree/ios-port) |

## Simulator (actual device screenshot)

iPhone Simulator — prepare view with **real mesh from official libslic3r** (`ORCA_LINKED` + SceneKit orbit):

<p align="center">
  <img src="docs/images/ios-simulator-prepare.png?raw=1" alt="OrcaSlicer iOS port — iPhone Simulator real mesh + plate orbit" width="320" />
</p>

*Live Simulator capture (Aug 2026): sample cube mesh exported via `orca_session_export_mesh` (20×20×20 mm), drag-to-orbit / pinch-to-zoom SceneKit plate, official logo + teal (`#009688`), Prepare / Preview / Device tabs, Slice plate → G-code path preview.*

---

## What this port is

```
Official libslic3r (C++ — every engine .cpp stays upstream code)
        ↑
   orca_ios_api  (thin C ABI: load model → config → slice → G-code)
        ↑
   SwiftUI app   (ios/ — mobile UI only; replaces wxWidgets on iPhone)
```

- **Engine:** compile upstream `src/libslic3r` for the target (macOS headless + iOS Simulator done).
- **UI:** new SwiftUI host under `ios/` — desktop **wxWidgets** GUI is not portable to iOS.
- **Not a rewrite** of Arachne, supports, G-code export, etc. in Swift.

---

## Status

| Piece | Status |
|---|---|
| C API `src/ios/orca_slice_c_api.{h,cpp}` | Done (+ mesh export, bounds, center, options) |
| macOS headless `libslic3r` + slice CLI | Done — sample cube → real Orca G-code |
| Combined `liborca_engine.a` (Mac + Simulator) | Done |
| Xcode app `ORCA_LINKED` on **My Mac** | Done |
| Xcode app `ORCA_LINKED` on **iOS Simulator** | Done |
| SceneKit plate: real mesh + orbit/pan/zoom | Done |
| G-code path preview after slice | Done (polyline toolpaths + layer Z slider) |
| Object tools (center / arrange / rotate / scale / nudge) | Done |
| Bundled process profile JSON | Done (minimal `process_0.20mm_Standard`) |
| Device tab: Moonraker connect + G-code upload | Done (basic HTTP API) |
| SwiftUI Prepare / Preview / Device + Process sheet | In progress (not desktop GUI parity) |
| Physical device (`iphoneos`) deps + `liborca_engine.a` | Done (arm64) |
| App Store release | **Not ready** — AGPL-3.0 + incomplete UI |

More detail: [`FULL_PORT_REALITY.md`](FULL_PORT_REALITY.md) · plan notes: [`PORT_IOS.md`](PORT_IOS.md)

---

## Layout (port-relevant paths)

```
ios/                         SwiftUI host + Xcode project
  OrcaSlicerApp/
    OrcaSlicerApp.swift      Prepare / Preview / Device shell
    OrcaEngine.swift         Bridge to orca_ios_api
    PlateSceneView.swift     SceneKit bed + mesh + G-code paths
  sample_cube_20mm.stl       Bundled test model
src/ios/                     C ABI over libslic3r (+ CLI for host tests)
  orca_slice_c_api.{h,cpp}   load / config / mesh / slice / G-code
scripts/
  build_macos_headless_api.sh
  build_ios_deps.sh
  build_ios_engine_after_deps.sh
  bundle_engine_libs.sh
cmake/ios.toolchain.cmake
docs/images/                 Simulator screenshots for this port
```

Upstream tree (`src/libslic3r`, `resources/`, `deps/`, …) is still the official OrcaSlicer source.

---

## Build / run (summary)

**Branch:** [`ios-port`](https://github.com/S117X/IOS-port-OrcaSlicer/tree/ios-port).  
**App icon:** 3D Orca (`Assets.xcassets/AppIcon`).  
**Engines:** static `liborca_engine.a` for **iOS Simulator** and **physical device** (`iphoneos`) when built; Mac headless bundle for My Mac.

**Full steps (Simulator + physical iPhone, signing, troubleshooting):**  
→ **[`docs/RUN_ON_DEVICE.md`](docs/RUN_ON_DEVICE.md)**

**Prereqs:** Xcode, Apple ID (for device), CMake ≥ 3.13, large free disk for deps.

```bash
# 1) Mac headless engine + CLI (prove slice)
export PATH="$HOME/local/bin:$PATH"
./scripts/build_macos_headless_api.sh
# then: build-macos-headless-*/src/ios/orca_slice_cli … sample_cube_20mm.stl out.gcode

# 2) Bundle static engine for Xcode (Mac path)
./scripts/bundle_engine_libs.sh

# 3) iOS Simulator deps + engine (long)
./scripts/build_ios_deps.sh iphonesimulator arm64
./scripts/build_ios_engine_after_deps.sh iphonesimulator arm64

# 3b) Physical device deps + engine (long; arm64 iphoneos)
./scripts/build_ios_deps.sh iphoneos arm64
./scripts/build_ios_engine_after_deps.sh iphoneos arm64

# 4) Open host app
open ios/OrcaSlicer.xcodeproj
# Destinations: My Mac, iPhone Simulator, or connected iPhone
# (ORCA_LINKED when the matching engine_bundle lib exists)
```

Logs and local build dirs (`build-*`, `deps/build*`) are **not** published as the product; they are developer artifacts.

---

## License

Same as upstream: **AGPL-3.0**.  
Shipping a closed binary that links this code has serious legal constraints — review before any store release.

Upstream project, downloads, wiki, and community: **[OrcaSlicer](https://github.com/OrcaSlicer/OrcaSlicer)** / [orcaslicer.com](https://www.orcaslicer.com/).  
This repository documents the **iOS port effort only**.
