# iOS port continuous builder (scheduled agent)

You are continuing the **OrcaSlicer iOS port** on branch `ios-port` at `/Users/x/Desktop/OrcaSlicer`.

## Always do this first

1. Read `docs/IOS_PORT_COMPLETION.md` and `docs/IOS_PORT_STATUS.json`.
2. If `status` is `"complete"` and all must-have checkboxes in the completion doc are `[x]`, **stop** (do not change code). Reply with `PORT_COMPLETE`.
3. Otherwise pick the highest incomplete must-have gate and implement the next concrete slice of work (1–3 focused deliverables per run).

## Rules

- Engine stays **official libslic3r** via `src/ios/orca_slice_c_api.*` — no Swift slicer rewrite.
- Prefer fixing real user-facing correctness (process enums, option keys, bed size, profiles).
- After code changes: rebuild as needed (`cmake` at `$HOME/local/bin` or PATH), regen `ios/generate_xcodeproj.py`, device build with `DEVELOPMENT_TEAM=6PU4X4CG8B` if installing.
- Flip checklist items only when verified.
- Update `docs/IOS_PORT_STATUS.json` every run.
- Commit + push to `origin ios-port` when you make meaningful progress.
- Keep going until time budget for this fire is used (~15–25 min of real work). Do not idle.

## Priority order

G3 process UI polish → G4 objects/arrange → G7 open 3MF → G6 Moonraker print/status → G5 preview → G2 compatible filter + user presets → G8 quality.
