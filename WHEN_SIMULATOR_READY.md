# When iOS 26 simulator finish — do this next

CMake is already installed at `~/local/bin/cmake` (also `~/Applications/CMake.app`).

```bash
export PATH="$HOME/local/bin:$PATH"
cmake --version   # expect 3.31.x
```

## 1. Confirm Simulator / SDK

```bash
xcodebuild -showsdks | grep -i iphone
xcrun simctl list devices available | head -20
```

You should see `iphonesimulator` and at least one iPhone runtime.

## 2. Open the iOS host (UI works even before libs link)

```bash
open ~/Desktop/OrcaSlicer/ios/OrcaSlicer.xcodeproj
```

Run on a simulator. Slice stays disabled until `ORCA_LINKED` + static libs (expected).

## 3. Check macOS deps build (if started while waiting)

```bash
ls -la ~/Desktop/OrcaSlicer/deps/build-arm64-macos 2>/dev/null
# or log:
tail -f ~/Desktop/OrcaSlicer/build_logs/deps_macos.log
```

When deps finish:

```bash
export PATH="$HOME/local/bin:$PATH"
cd ~/Desktop/OrcaSlicer
./scripts/build_macos_headless_api.sh
```

That builds **`orca_ios_api` + `libslic3r`** (headless, `SLIC3R_GUI=OFF`) on Mac first — proves the C API against official engine.

## 4. Then iOS cross-build (after SDK + deps strategy)

```bash
./scripts/build_ios.sh iphonesimulator arm64
```

(Will still need an iOS-built `CMAKE_PREFIX_PATH` for full link.)

## 5. Tell the agent

Message: **“iOS simulator is done”** — we’ll wire libraries into the Xcode target and try a sim run.
