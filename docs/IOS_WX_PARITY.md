# iOS ↔ desktop wxWidgets feature parity

**wxWidgets does not run on iOS.** Desktop Orca uses wx + OpenGL; the iOS port is **SwiftUI + SceneKit** over the **same libslic3r**.

This document tracks **workflow parity** with desktop GUI modules under `src/slic3r/GUI/`.

Status file: `docs/IOS_PORT_STATUS.json` field `wx_parity_percent`.

---

## Done (SwiftUI replacements)

| Desktop (wx) | iOS |
|--------------|-----|
| Plater load/slice/export | Prepare + Slice + Share |
| Process / Filament / Printer tabs | Process sheet + pickers + settings browser |
| 3D bed + mesh | PlateSceneView |
| G-code preview | SceneKit paths + WIDTH ribbons |
| Arrange / orient / transforms | C API + gizmo strip |
| Multi-plate | Plate slots |
| Device / send | Moonraker / OctoPrint / PrusaLink + mDNS |
| Calibration wizards (subset) | Calib sheet + official Calib_Params |
| Cut / mesh boolean repair | C API cut + CGAL repair |
| Object list | Process sheet objects |
| Undo/redo (basic) | 3MF snapshot stack |
| Object settings overrides | Per-object ModelConfig options |
| Preferences / About | Sheets (ellipsis menu) |
| Measure gizmo | Measure mode + tap pick |
| Move / Rotate / Scale gizmos | Gizmo modes + chips |
| Support / seam / MMU / fuzzy paint | FacetsAnnotation via C API + paint gizmos |

---

## Remaining for full wx-parity (watcher continues)

### W1 — Painter gizmos (high effort)
- [x] Support painting (`GLGizmoFdmSupports`) — `orca_session_paint_*` + Support paint gizmo
- [x] Seam painting — Seam paint gizmo → `seam_facets`
- [x] Multi-material / color painting (`GLGizmoMmuSegmentation`) — MMU paint gizmo → `mmu_segmentation_facets`
- [ ] Brim ears paint (point markers, not triangle facets — still open)
- [x] Fuzzy skin paint — Fuzzy paint gizmo → `fuzzy_skin_facets`

### W2 — Advanced mesh tools
- [ ] Advanced cut (non-horizontal planes, connectors)
- [ ] Assembly / multi-part explode
- [ ] Emboss / text (`GLGizmoEmboss`)
- [ ] Mesh boolean union/diff/intersect UI
- [ ] Simplify / remesh

### W3 — Desktop chrome
- [ ] Full ConfigWizard first-run (language, region, printers select)
- [ ] Export preset bundle dialog
- [ ] Auxiliary files / project media
- [ ] Keyboard shortcut map
- [ ] Print host queue history UI

### W4 — Cloud / OEM (optional / policy)
- [ ] Bambu network / login (if licensed for fork)
- [ ] AMS mapping UI (hardware-dependent)

### W5 — Viewer polish
- [ ] Desktop-grade GCodeViewer (toolpath height map, shell/infill layers)
- [ ] Clipping plane
- [ ] Legend / travel toggle parity complete

---

## DONE rule for “wx finished”

```
wx_done = W1–W3 and W5 checked (W4 optional)
status wx_parity_percent = 100
```

Painters (W1) are the largest remaining desktop gap.
