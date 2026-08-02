# OrcaSlicer iOS port — reality check

**Repo:** `S117X/IOS-port-OrcaSlicer` branch `ios-port`  
**Engine:** official `libslic3r` (not a rewrite)  
**UI:** SwiftUI shell calling C ABI `orca_session_*`

## Done (2026-08-02)

| Milestone | Status |
|---|---|
| Official source + C API wrapper | Done |
| macOS headless `libslic3r` + slice CLI | Done — cube → Orca G-code (100 layers) |
| Mac app `ORCA_LINKED` | Done |
| iOS Simulator deps (Boost, TBB, OCCT, OpenVDB, …) | Done |
| iOS Simulator `libslic3r` + `orca_ios_api` | Done |
| Simulator app linked + launched | Done — binary has `orca_session_slice_to_gcode` |
| Device (`iphoneos`) deps/engine | Not yet (same scripts, `iphoneos` target) |

## How to run

```bash
# Simulator with real engine
open ~/Desktop/OrcaSlicer/ios/OrcaSlicer.xcodeproj
# Destination: iPhone 17 Pro (Simulator)
# Load sample cube → Slice

# CLI proof (Mac)
./build-macos-headless-arm64/src/ios/orca_slice_cli.app/Contents/MacOS/orca_slice_cli \
  ios/sample_cube_20mm.stl /tmp/out.gcode
```

## Architecture

```
SwiftUI (ios/OrcaSlicerApp)
    → Bridging-Header → orca_slice_c_api.h
    → liborca_engine.a (orca_ios_api + libslic3r + deps)
    → Slic3r::Model / Print / export_gcode
```

## Scripts

- `scripts/build_macos_headless_api.sh` — Mac engine
- `scripts/build_ios_deps.sh` — iOS deps
- `scripts/build_ios_engine_after_deps.sh` — iOS engine + Xcode regen
- `scripts/bundle_engine_libs.sh` — single `liborca_engine.a`

## License

AGPL-3.0 — App Store distribution needs legal review.
