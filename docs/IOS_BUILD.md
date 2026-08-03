# iOS port — build notes

Branch: `ios-port`  
Engine: official `libslic3r` via `src/ios/orca_slice_c_api` → `liborca_engine.a`  
Host: SwiftUI app in `ios/OrcaSlicerApp` (`ORCA_LINKED` when engine is linked).

## Prerequisites

- Xcode 16+ / iOS 16.0 deployment target  
- cmake at `$HOME/local/bin/cmake` (or on `PATH`)  
- iOS deps already built under:
  - `deps/build-ios-iphonesimulator-arm64/OrcaSlicer_dep/usr/local`
  - `deps/build-ios-iphoneos-arm64/OrcaSlicer_dep/usr/local`

## Engine rebuild

```bash
export PATH="$HOME/local/bin:$PATH"
# Simulator
./scripts/build_ios_engine_after_deps.sh iphonesimulator arm64
# Device
./scripts/build_ios_engine_after_deps.sh iphoneos arm64
```

Bundles land in:

- `build-ios-iphonesimulator-arm64/engine_bundle/lib/liborca_engine.a`
- `build-ios-iphoneos-arm64/engine_bundle/lib/liborca_engine.a`

## App build

```bash
cd ios
xcodebuild -project OrcaSlicer.xcodeproj -scheme OrcaSlicer \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5' \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
  DEVELOPMENT_TEAM=6PU4X4CG8B CODE_SIGN_STYLE=Automatic \
  build
```

Device install uses team **6PU4X4CG8B**. Prefer arm64-only destinations (engine is arm64).

## Profiles

Full vendor trees live in `ios/OrcaSlicerApp/Resources/profiles` (copied into the app bundle).  
First launch installs them into Documents via `orca_session_load_all_presets` (can take several seconds).  
Subsequent launches **skip reinstall** when `Documents/OrcaSlicer/system/<vendor>/` already exists.  
User process presets: `Documents/OrcaSlicer/user_presets/process/*.json`.

## Memory (full profile tree)

- Official `PresetBundle` keeps system presets in process memory (same model as desktop).
- Mitigations on iOS:
  - Skip vendor reinstall after first run
  - Compatible-only process/filament name lists after printer select
  - Lazy enum lists in the settings browser
  - G-code path cap (~60k points) + travel subsampling; ribbon sampling
  - `UIApplication.didReceiveMemoryWarning` drops G-code preview + option caches
- After load, status line reports approximate RSS (`~N MB`).

## Status

See `docs/IOS_PORT_COMPLETION.md` and `docs/IOS_PORT_STATUS.json`.
