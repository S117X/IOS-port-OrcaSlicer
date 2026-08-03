# OrcaSlicer iOS port — 100% release notes (`ios-port`)

**Tag:** `ios-port-100`  
**Branch:** `ios-port`  
**Date:** 2026-08-03  

## Summary

Full mobile port of OrcaSlicer on iOS: official **libslic3r** engine via `orca_ios_api` C ABI, SwiftUI shell for prepare / slice / preview / device workflows. Gates **G1–G16** in `docs/IOS_PORT_COMPLETION.md` are complete.

## Engine

- Slice path: `Print::apply` → `process` → `export_gcode`
- Device + simulator **arm64** static engines (`liborca_engine.a`)
- Full system profiles under `resources/profiles` (installed to Documents on first launch)
- Official calibration (`Print::set_calib_params`), arrange (libnest2d), orient, cut, CGAL mesh repair

## Product surface (mobile)

| Area | Capability |
|------|------------|
| Prepare | Load STL/3MF, multi-object, drag, transforms (R/M/scale/orient), multi-plate |
| Profiles | Printer / process / filament pickers, compatible filter, user process + filament |
| Process | Enum options, full settings browser, save user presets |
| Slice | Progress callback, G-code export, stats + role usage |
| Preview | Toolpaths, layer scrubber, feature toggles, color by feature / height / speed |
| Device | Moonraker, OctoPrint, PrusaLink, mDNS discovery, live temps, upload/start/cancel |
| Calibration | Temp tower, flow rate, PA line, retraction (bundled `resources/calib`) |
| Files | 3MF project, config JSON export/import, recent models, Share |
| Mesh | Clone grid, manifold report, repair, horizontal plane cut |

## Ship readiness

- App icon: 1024×1024 AppIcon asset
- Launch screen: Orca logo on dark brand background
- Local network privacy: `NSLocalNetworkUsageDescription` + Bonjour service types
- Cold start: preset install skip-if-present, memory-pressure cache drop, resilient first-run

## Not in scope (by design)

- Full AMS / seam paint OpenGL tools
- Bambu cloud lock-in
- wxWidgets 1:1 UI
- Byte-parity with every desktop dialog

## Build

```bash
# Engines (after deps)
cmake --build build-ios-iphoneos-arm64 --target orca_ios_api
scripts/bundle_engine_libs.sh build-ios-iphoneos-arm64 \
  deps/build-ios-iphoneos-arm64/OrcaSlicer_dep/usr/local/lib

cd ios && python3 generate_xcodeproj.py
xcodebuild -project OrcaSlicer.xcodeproj -scheme OrcaSlicer \
  -destination 'generic/platform=iOS' \
  DEVELOPMENT_TEAM=6PU4X4CG8B ARCHS=arm64 EXCLUDED_ARCHS=x86_64 build
```

See `docs/IOS_BUILD.md` and `docs/RUN_ON_DEVICE.md`.

## License

AGPL-3.0 — same as OrcaSlicer / libslic3r.
