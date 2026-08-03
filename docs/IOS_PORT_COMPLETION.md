# iOS OrcaSlicer port — completion criteria

This file is the **source of truth** for whether the port is “done.”  
The durable watcher / scheduler agent must re-evaluate these gates and keep building until **all** must-have gates pass.

Last updated: 2026-08-03 (G5 width ribbons + G6 OctoPrint)

## Philosophy

- **Engine:** official `libslic3r` via `orca_ios_api` (not a Swift rewrite).
- **Shell:** SwiftUI host with real workflows (not demo UI).
- **Done** means a **daily-driver mobile slicer**, not 1:1 wxWidgets clone.

---

## Must-have gates (ALL required for DONE)

### G1 — Engine & build
- [x] `ORCA_LINKED` device + simulator engines link and slice
- [x] Slice path is `Print::apply` / `process` / `export_gcode`
- [x] App installs and runs on physical iPhone

### G2 — Profiles
- [x] Full `resources/profiles` bundled (vendors, machines, process, filament)
- [x] Printer / process / filament pickers with search
- [x] Bed size from selected machine
- [x] Cover / bed texture on plate
- [ ] Compatible-only process/filament filtering after printer select
- [ ] User-saved presets persist across launches

### G3 — Process settings UI
- [x] Enum options use **dropdowns** (brim_type, support_type, wall_generator, seam_position, ironing_type, infill pattern)
- [x] Correct keys (`ironing_type` not bool `ironing`)
- [x] Scalar fields sync from engine after preset apply
- [x] Multi-value temps/diameters take first value in UI; set accepts scalar
- [x] Searchable full settings browser for remaining keys

### G4 — Prepare / objects
- [x] Load / add model, basic transforms, clear plate
- [x] Object list select / delete / duplicate in UI
- [x] Free drag on plate (or better gesture transforms)
- [x] Full **libnest2d** arrange (official `arrange_objects`)
- [x] Multi-plate support

### G5 — Preview
- [x] Basic G-code path preview + layer Z scrubber
- [x] Feature-type toggles (wall/infill/support/travel)
- [x] Better fidelity (width or engine path data)

### G6 — Device / send
- [x] Moonraker connect + G-code upload
- [x] Start print + job status / cancel
- [x] OctoPrint or second host type

### G7 — Project
- [x] Save 3MF
- [x] Open 3MF restores model + config
- [x] Share G-code via system share sheet

### G8 — Product quality
- [ ] No crash on first-run full profile install
- [ ] Memory acceptable with full profile tree
- [ ] Status/errors clear when options fail to apply
- [ ] GitHub `ios-port` builds documented and current

---

## DONE rule (watcher)

```
DONE = all Must-have unchecked boxes are gone (every [ ] above is [x])
```

When DONE:
1. Write `docs/IOS_PORT_STATUS.json` with `"status": "complete"`.
2. Stop scheduling further port work (watcher self-exits).
3. Commit + push final status.

While not DONE:
1. Pick highest incomplete gate (G3 → G4 → G5 → G6 → G7 → G8 → remaining G2).
2. Implement, rebuild if needed, install when device available.
3. Update this checklist (flip `[ ]` → `[x]` only when verified).
4. Update `docs/IOS_PORT_STATUS.json` progress fields.
5. Commit + push meaningful chunks.

---

## Explicitly out of scope for v1 DONE

- Full AMS / multi-material painting
- Support / seam painting tools
- Bambu cloud lock-in
- 1:1 every desktop calibration wizard
- wxWidgets UI port
