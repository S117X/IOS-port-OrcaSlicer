# iOS port glue (official tree)

These files are the **iOS-facing ABI** for the **existing** `libslic3r` library from
https://github.com/OrcaSlicer/OrcaSlicer

- Do **not** implement slicing here.
- Implementation must call `Slic3r::Model`, `Slic3r::Print`, `Slic3r::DynamicPrintConfig`, etc.
- See `/PORT_IOS.md` at repo root.
