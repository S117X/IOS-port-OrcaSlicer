# iOS OrcaSlicer port — **100% completion criteria**

Source of truth for whether the **full** mobile port is done.  
Durable watcher must keep building until every gate below is `[x]`.

Last updated: 2026-08-03 — expanded from v1 daily-driver to **full port (100%)**

## Philosophy

- **Engine:** official `libslic3r` via `orca_ios_api` only (never a Swift slicer rewrite).
- **Shell:** SwiftUI product workflows matching desktop capability where mobile UX allows.
- **100% DONE** = all gates G1–G16 checked. (wxWidgets 1:1 UI is still not required.)

---

## Phase A — Daily driver (G1–G8) — v1

### G1 — Engine & build
- [x] `ORCA_LINKED` device + simulator engines link and slice
- [x] Slice path is `Print::apply` / `process` / `export_gcode`
- [x] App installs and runs on physical iPhone

### G2 — Profiles
- [x] Full `resources/profiles` bundled
- [x] Printer / process / filament pickers with search
- [x] Bed size + cover / bed texture
- [x] Compatible-only process/filament filter
- [x] User-saved process presets persist

### G3 — Process settings UI
- [x] Enum dropdowns (brim, support, wall, seam, ironing, infill)
- [x] Correct option keys + sync after apply
- [x] Searchable full settings browser

### G4 — Prepare / objects
- [x] Load/add/clear, object list, delete/duplicate
- [x] Free drag on plate
- [x] libnest2d arrange
- [x] Multi-plate slots

### G5 — Preview
- [x] G-code paths + layer scrubber
- [x] Feature-type toggles
- [x] WIDTH ribbon fidelity

### G6 — Device / send
- [x] Moonraker connect/upload/start/cancel/status
- [x] OctoPrint same
- [x] PrusaLink host type (OctoPrint-compatible API path)
- [x] mDNS / Bonjour printer discovery

### G7 — Project
- [x] Save / open 3MF with config
- [x] Share G-code

### G8 — Product quality
- [x] First-run profiles resilient
- [x] Memory mitigations
- [x] Clear option errors
- [x] Build docs

---

## Phase B — Full port to 100% (G9–G16)

### G9 — Full transforms
- [x] Rotate X / Y / Z (not only Z)
- [x] Mirror X / Y / Z
- [x] Scale to fit bed
- [x] Official auto-orient (`orientation::orient`)
- [x] UI chips for all of the above

### G10 — Multi-filament / extruders
- [x] Extruder count from printer
- [x] Per-slot filament assignment UI
- [x] set_filament_preset for slot N + apply

### G11 — Calibration
- [x] Temp tower (official calib path or guided slice)
- [x] Flow rate calibration
- [x] Pressure advance / retraction helper
- [x] Accessible from Process or Device sheet

### G12 — Device completeness
- [x] Moonraker + OctoPrint
- [x] PrusaLink
- [x] Bonjour discovery list
- [x] Live nozzle/bed temps from printer (when host supports)

### G13 — Files & presets
- [x] Recent models list
- [x] Export current config JSON
- [x] Import user filament/process from Files
- [x] Save user filament preset (not only process)

### G14 — Mesh / object ops
- [x] Simple plane cut (split object)
- [x] Repair / manifold hint (or report non-manifold)
- [x] Clone grid (NxM duplicates + arrange)

### G15 — Preview / analysis
- [ ] Layer time estimate display
- [ ] Filament usage by feature (if GCodeProcessor exposes)
- [ ] Color by speed or height option

### G16 — Ship readiness
- [ ] App icons / splash complete
- [ ] Privacy strings for LAN + local network
- [ ] Crash-free cold start with full profiles on device
- [ ] `docs/IOS_PORT_STATUS.json` → `"status": "complete_100"`
- [ ] Tag / release notes on `ios-port`

---

## DONE rule (100%)

```
DONE_100 = every [ ] in G1–G16 is [x]
status file = "complete_100"
```

When DONE_100:
1. Update `docs/IOS_PORT_STATUS.json` with `"status": "complete_100"`.
2. Stop durable scheduler.
3. Commit + push; optional tag `ios-port-100`.

While not done: implement next incomplete gate in order **G9 → G10 → G11 → G12 → G13 → G14 → G15 → G16**, rebuild engines when C API changes, device build with team `6PU4X4CG8B`.

## Still never required for 100%

- Full AMS paint / seam paint GL tools (desktop OpenGL)
- Bambu cloud lock-in
- wxWidgets UI port
- Perfect byte-parity with every desktop dialog
