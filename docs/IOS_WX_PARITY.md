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
| Brim ears paint | `ModelObject::brim_points` C API + Brim ears gizmo |
| Mesh boolean / simplify / plane cut | mcut boolean + quadric simplify + `cut_object_plane` |

---

## Remaining for full wx-parity (watcher continues)

### W1 — Painter gizmos (high effort)
- [x] Support painting (`GLGizmoFdmSupports`) — `orca_session_paint_*` + Support paint gizmo
- [x] Seam painting — Seam paint gizmo → `seam_facets`
- [x] Multi-material / color painting (`GLGizmoMmuSegmentation`) — MMU paint gizmo → `mmu_segmentation_facets`
- [x] Brim ears paint (point markers → `brim_points` + disc overlay; sets `brim_type=painted`)
- [x] Fuzzy skin paint — Fuzzy paint gizmo → `fuzzy_skin_facets`

### W2 — Advanced mesh tools
- [x] Advanced cut (non-horizontal plane via normal + point; connectors still open)
- [ ] Assembly / multi-part explode
- [ ] Emboss / text (`GLGizmoEmboss`)
- [x] Mesh boolean union/diff/intersect UI (`orca_session_mesh_boolean` mcut)
- [x] Simplify / remesh (`its_quadric_edge_collapse`)

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

W1 complete. Remaining: W2 explode/emboss, W3 chrome, W5 viewer polish.
