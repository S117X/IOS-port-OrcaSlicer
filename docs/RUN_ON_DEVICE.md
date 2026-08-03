# Run the iOS port (Simulator + physical iPhone)

Branch: **`ios-port`** on this fork.  
Engine: **official `libslic3r`** exposed through a thin C ABI (`src/ios/orca_slice_c_api.*`) — **not** a Swift rewrite of the slicer.

The SwiftUI host lives under `ios/`. Desktop **wxWidgets** is not used on iPhone.

---

## Prerequisites

| Requirement | Notes |
|---|---|
| **macOS** | Recent macOS with enough free disk (deps builds are large) |
| **Xcode** | Full Xcode from the App Store (not only Command Line Tools). Open once and accept the license. |
| **Apple ID** | Free Apple ID is enough for personal device installs; paid Apple Developer Program optional |
| **CMake ≥ 3.13** | Needed only if you rebuild deps/engine scripts |
| **USB cable** (device) | For first install / trust on a physical iPhone |

Optional: set `PATH` so a custom CMake is found, e.g. `export PATH="$HOME/local/bin:$PATH"`.

---

## Simulator run

1. Ensure Simulator engine libraries exist (or rebuild — see [Rebuild engine](#rebuild-engine-if-needed)):
   - `build-ios-iphonesimulator-arm64/engine_bundle/lib/liborca_engine.a`
2. Open the host project:
   ```bash
   open ios/OrcaSlicer.xcodeproj
   ```
3. In Xcode, choose an **iPhone Simulator** destination (e.g. iPhone 16 / 17).
4. Press **Run** (⌘R).
5. In the app: load the sample cube (or import a model) → **Slice plate**. With `ORCA_LINKED`, slicing uses official `libslic3r` via the C API.

**Mac “My Mac”** destination also works when the macOS headless engine bundle is present (`build-macos-headless-arm64/engine_bundle`).

---

## Physical iPhone

### 1. Trust the Mac / cable

1. Connect the iPhone with a data-capable USB cable.
2. Unlock the phone; if prompted, tap **Trust This Computer** and enter the passcode.

### 2. Developer Mode (iOS 16+)

On iOS 16 and later, apps signed for development require **Developer Mode**:

1. On the iPhone: **Settings → Privacy & Security → Developer Mode** → enable.
2. Restart when prompted, then confirm.
3. If the toggle is missing, connect the device to Xcode once (or install any development build); the option usually appears afterward.

### 3. Signing Team in Xcode

1. Open `ios/OrcaSlicer.xcodeproj`.
2. Select the **OrcaSlicer** target → **Signing & Capabilities**.
3. Enable **Automatically manage signing**.
4. Choose your **Team** (personal team from your Apple ID is fine for local install).
5. If the bundle id `com.orcaslicer.ios` is already taken for your team, change **Bundle Identifier** to something unique (e.g. `com.yourname.orcaslicer.ios`).

`generate_xcodeproj.py` leaves `DEVELOPMENT_TEAM` empty so each developer picks their own Team in the UI (or sets it in the project).

### 4. Device engine + Run

1. Confirm the **device** engine library exists:
   - `build-ios-iphoneos-arm64/engine_bundle/lib/liborca_engine.a`  
   If missing, rebuild for `iphoneos` (below).
2. Select your **physical iPhone** as the run destination.
3. Press **Run** (⌘R). First install may take longer; keep the device unlocked.
4. On the phone, if you see an untrusted developer alert, follow [Untrusted developer](#untrusted-developer) below, then launch the app again.

---

## Rebuild engine if needed

Build **deps first**, then the **engine** (and Xcode project regen). Target and arch:

| Destination | `TARGET` | `ARCH` | Engine bundle path |
|---|---|---|---|
| iOS Simulator | `iphonesimulator` | `arm64` | `build-ios-iphonesimulator-arm64/engine_bundle/` |
| Physical iPhone | `iphoneos` | `arm64` | `build-ios-iphoneos-arm64/engine_bundle/` |

```bash
cd /path/to/OrcaSlicer   # this repo, branch ios-port
export PATH="$HOME/local/bin:$PATH"

# Simulator
./scripts/build_ios_deps.sh iphonesimulator arm64
./scripts/build_ios_engine_after_deps.sh iphonesimulator arm64

# Physical device
./scripts/build_ios_deps.sh iphoneos arm64
./scripts/build_ios_engine_after_deps.sh iphoneos arm64
```

- Deps install under `deps/build-ios-<target>-arm64/OrcaSlicer_dep/usr/local`.
- Engine script configures CMake with `ORCA_IOS=ON` / `ORCA_IOS_API=ON`, builds `orca_ios_api`, runs `bundle_engine_libs.sh`, and regenerates `ios/OrcaSlicer.xcodeproj`.
- Logs: `build_logs/ios_deps_*.log`, engine configure/build logs under `build_logs/`.
- After a successful engine build, rebuild/run from Xcode so `ORCA_LINKED` links `liborca_engine.a`.

**macOS headless proof** (optional, not required for iPhone install):

```bash
./scripts/build_macos_headless_api.sh
./scripts/bundle_engine_libs.sh
```

---

## Troubleshooting

### Signing / provisioning

- **Failed to register bundle identifier** — pick a unique Bundle ID under Signing & Capabilities.
- **No profiles for team** — sign in to Xcode with your Apple ID (**Xcode → Settings → Accounts**), select a Team, clean build folder (⇧⌘K), try again.
- **Device not listed** — unlock phone, trust the Mac, use a data cable; check **Window → Devices and Simulators**.

### Untrusted developer

After first install from a free/personal team:

1. On iPhone: **Settings → General → VPN & Device Management** (wording varies by iOS version).
2. Select your developer certificate / Apple ID.
3. Tap **Trust**, then open the app from the home screen.

### Icon cache (stale app icon)

The port ships a **3D Orca** app icon via `ios/OrcaSlicerApp/Assets.xcassets/AppIcon.appiconset`. If the home screen still shows an old/generic icon:

1. Delete the app from the device/simulator.
2. In Xcode: **Product → Clean Build Folder**.
3. Rebuild and reinstall.
4. If needed on Simulator: **Device → Erase All Content and Settings**, or reboot the physical device.

### Missing `ORCA_LINKED` / slice disabled

- Engine static lib missing for that SDK → rebuild deps + engine for `iphonesimulator` or `iphoneos` as appropriate.
- After building engine, reopen or regenerate the Xcode project (`python3 ios/generate_xcodeproj.py` is also run by `build_ios_engine_after_deps.sh`).

### Link errors for `liborca_engine`

Confirm the library path matches the destination:

- Simulator → `build-ios-iphonesimulator-arm64/engine_bundle/lib`
- Device → `build-ios-iphoneos-arm64/engine_bundle/lib`

Do not mix simulator and device archives.

---

## Architecture note

```
Official libslic3r (C++ — upstream engine sources)
        ↑
   orca_ios_api  (src/ios — thin C ABI)
        ↑
   SwiftUI app   (ios/OrcaSlicerApp — mobile UI only)
```

This is a **port host** for the official engine, not a reimplementation of Arachne, supports, or G-code export in Swift.

**License:** same as upstream — **AGPL-3.0**. Review obligations before any App Store or closed distribution.
