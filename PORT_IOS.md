# OrcaSlicer → iPhone (iOS) port plan

**Source of truth:** official GitHub only  
https://github.com/OrcaSlicer/OrcaSlicer.git  

**This machine:** shallow clone at `~/Desktop/OrcaSlicer` (`main`, AGPL-3.0).

**Rule:** we **port** this tree. We do **not** re-create a lookalike app.

---

## What the official software is

| Layer | Path | Role | iOS reality |
|---|---|---|---|
| **App entry** | `src/OrcaSlicer.cpp` | Desktop process bootstrap | Replace with `UIApplication` / SwiftUI host |
| **GUI** | `src/slic3r/GUI/*` (**hundreds** of files) | **wxWidgets** + OpenGL UI (plates, preview, dialogs) | **Not portable as-is** — wxWidgets has no production iPhone backend |
| **Slicer core** | `src/libslic3r/*` (**hundreds** of files) | Mesh, arrange, supports, G-code, config | **Portable** C++17 (with deps) |
| **Toolpaths / preview GPU** | `src/libvgcode`, `glad` | Path visualization | Re-bind to Metal / OpenGL ES |
| **Resources** | `resources/` | Printer profiles, filaments, i18n, images | Bundle as app resources |
| **Deps** | `deps/`, `deps_src/` | Boost, TBB, OpenSSL, CURL, Eigen, OpenVDB, OCCT, wx, … | Rebuild **per iOS** (arm64); several are hard |
| **Desktop targets only** | `build_release_macos.sh`, Win/Linux scripts | Official builds | **No iOS target exists upstream** |

CMake already has:

```text
option(SLIC3R_GUI "Compile OrcaSlicer with GUI components (OpenGL, wxWidgets)" 1)
```

A real mobile port **starts with `SLIC3R_GUI=0`** and a thin iOS shell that **calls the same `libslic3r` APIs**.

---

## Why “just compile for iPhone” fails

1. **UI is wxWidgets desktop** — not UIKit/SwiftUI.  
2. **Deps stack is huge** (Boost, TBB, OpenVDB, OCCT, …) — many need cross-compile patches for `iphoneos`.  
3. **App Store + AGPL-3.0** — shipping a closed binary that links this code has **serious licensing constraints** (AGPL). Legal review required before any Store release.  
4. **RAM / thermals** — full plate slice on-device may need reduced presets or server offload.  
5. Upstream **does not maintain iOS** (community discussions confirm no official app).

So a port is a **multi-phase engineering project**, not a UI reskin.

---

## Correct port strategy (from THIS repo)

### Phase 0 — Inventory (done on this machine)
- [x] Clone `https://github.com/OrcaSlicer/OrcaSlicer.git`
- [x] Confirm license **AGPL-3.0**
- [x] Map `libslic3r` vs `slic3r/GUI`
- [x] Document this plan

### Phase 1 — Headless `libslic3r` for iOS (real port)
Goal: static library `libslic3r.a` (or xcframework) for **arm64-iphoneos** + simulator.

Work:
1. Fork branch: `ios-port` off `main`.
2. CMake toolchain file: `cmake/ios.toolchain.cmake` (or use official iOS CMake toolchain).
3. Configure:
   - `SLIC3R_GUI=OFF`
   - disable wx, desktop integration, WebView2, Spacenav, etc.
4. Cross-build minimal deps to iOS: Boost, TBB, Eigen, ZLIB, PNG, (defer OpenVDB/OCCT if possible).
5. Expose a **stable C ABI** wrapper (new small files **in-tree**, not a rewrite):
   - `src/ios/orca_slice_c_api.h` / `.cpp`  
   - load STL/3MF → apply `Print` config → emit G-code path  
   - reuse existing `libslic3r` types (`Model`, `Print`, `DynamicPrintConfig`, …).

Success = unit test on device: **slice a known STL → G-code matches desktop headless within tolerance**.

### Phase 2 — iOS host app (shell only; engine = ported core)
- New Xcode target **in the fork** (or sibling `ios/` that **links** `libslic3r`).
- SwiftUI screens that are **thin clients** of C API:
  - import model (Files / iCloud)
  - pick **official** printer/filament presets from `resources/profiles`
  - slice progress (callbacks from core)
  - export G-code / send to OctoPrint / Klipper / Moonraker (code paths already exist in desktop networking — port carefully)

**Do not** reimplement calibration, Arachne, supports, etc. Call upstream algorithms.

### Phase 3 — 3D preview
- Port or replace `libvgcode` + GL bed with **Metal**.
- Still driven by geometry produced by `libslic3r`, not a new slicer.

### Phase 4 — Optional full GUI parity
- Either:
  - long-term **re-bind** each wx panel to SwiftUI (years), or
  - ship **headless slice + essential mobile UI** (practical product).

---

## What we will not do

- Invent a fake “OrcaSlicer Mobile” with fake slice logic.  
- Copy branding into an unrelated app without using this source.  
- Claim App Store readiness without AGPL/legal review.  
- Expect a full wx GUI on iPhone in one session.

---

## Status (in tree now — Aug 2026)

| Item | Location | Notes |
|---|---|---|
| C ABI | `src/ios/orca_slice_c_api.{h,cpp}` | load/config/mesh export/bounds/transform/arrange/slice/progress |
| CMake target | `src/ios/CMakeLists.txt` → `orca_ios_api` | `ORCA_IOS_API=ON` |
| macOS headless engine | `build-macos-headless-arm64` | Sample cube → real G-code proven |
| **iOS Simulator deps + engine** | `deps/build-ios-iphonesimulator-arm64`, `build-ios-iphonesimulator-arm64` | `liborca_engine.a` linked in Xcode |
| SwiftUI host | `ios/OrcaSlicerApp/*` | Prepare / Preview / Device, SceneKit orbit, real mesh |
| SceneKit plate | `PlateSceneView.swift` | Mesh from `orca_session_export_mesh`, G-code paths + layer Z |
| Process sheet | Process | layer/walls/infill/support/brim/speeds/temps via DynamicPrintConfig |
| Device | Moonraker | `server.info` connect + multipart G-code upload |
| Branch | `ios-port` on [S117X/IOS-port-OrcaSlicer](https://github.com/S117X/IOS-port-OrcaSlicer) | Pushed continuously |

### Still required

1. **Physical device** (`iphoneos`) deps + engine (not built yet — only Simulator arm64).  
2. Fuller profile inheritance (official JSON inherits chains).  
3. Metal/libvgcode-class toolpath preview (current path is SceneKit polylines).  
4. Full desktop GUI parity (years of wx rebind — not the mobile product path).  
5. AGPL compliance strategy before any store distribution.

## Immediate next engineering steps

1. ~~Create branch `ios-port`~~ done.  
2. ~~C API wrapping libslic3r~~ done (expanded).  
3. ~~Swift host shell~~ done + SceneKit plate.  
4. ~~iOS Simulator deps + link ORCA_LINKED~~ done.  
5. ~~Real mesh + orbit + G-code preview~~ done.  
6. Build **iphoneos** dep prefix + device install.  
7. Richer G-code feature-type colors / multi-plate.

---

## Commands (reference)

```bash
# Official source (already cloned)
cd ~/Desktop/OrcaSlicer
git remote -v   # must be github.com/OrcaSlicer/OrcaSlicer.git

# Desktop macOS build (upstream path — for comparison / golden G-code)
# See: https://www.orcaslicer.com/wiki/how_to_build
# ./build_release_macos.sh

# Future iOS (to be implemented on branch ios-port)
# cmake -G Xcode -DCMAKE_TOOLCHAIN_FILE=cmake/toolchains/ios.cmake \
#   -DSLIC3R_GUI=OFF -B build-ios
```

---

## License reminder

**GNU Affero GPL v3.** Network use and combined works have copyleft obligations.  
Any iPhone distribution plan needs a deliberate AGPL compliance strategy (source offer, same license for derivatives, etc.).

---

*Document written against the local clone of the official OrcaSlicer repository. Port work continues only against this tree.*
