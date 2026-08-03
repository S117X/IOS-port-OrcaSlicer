/**
 * OrcaSlicer iOS C ABI — thin wrapper over official libslic3r.
 * Port surface only; algorithms live in src/libslic3r (upstream).
 *
 * Source: https://github.com/OrcaSlicer/OrcaSlicer
 * License: AGPL-3.0
 */
#pragma once

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#if defined(_WIN32) || defined(__CYGWIN__)
  #define ORCA_API
#else
  #define ORCA_API __attribute__((visibility("default")))
#endif

typedef struct orca_session orca_session_t;

/** Create session (optional path to official resources/ bundle). */
ORCA_API orca_session_t *orca_session_create(const char *resources_path);

ORCA_API void orca_session_destroy(orca_session_t *s);

/**
 * Load model (STL/3MF path).
 * Implementation: Slic3r::Model::read_from_file
 * @param append 0 = replace plate; nonzero = add objects onto existing plate
 */
ORCA_API int orca_session_load_model(orca_session_t *s, const char *path);

/** Same as load_model with append=1 (keep existing objects). */
ORCA_API int orca_session_add_model(orca_session_t *s, const char *path);

/**
 * Load config from official .json / .ini profile.
 * Implementation: DynamicPrintConfig::load_from_json / load_from_ini
 */
ORCA_API int orca_session_load_config(orca_session_t *s, const char *config_path);

/**
 * Set a single DynamicPrintConfig option (e.g. "layer_height", "0.2").
 */
ORCA_API int orca_session_set_option(orca_session_t *s, const char *key, const char *value);

/**
 * Optional progress callback during slice (percent 0–100, message may be null).
 * Called from the slicing thread; keep work light / hop to main for UI.
 */
typedef void (*orca_progress_fn)(int percent, const char *message, void *user);

ORCA_API void orca_session_set_progress_callback(
    orca_session_t *s, orca_progress_fn fn, void *user);

/**
 * Slice and write G-code.
 * Implementation: Print::apply + Print::process + Print::export_gcode
 * @return 0 on success
 */
ORCA_API int orca_session_slice_to_gcode(orca_session_t *s, const char *gcode_out_path);

/**
 * Axis-aligned bounding box of loaded model (mm).
 * @return 0 on success
 */
ORCA_API int orca_session_model_bounds(
    orca_session_t *s,
    float *min_x, float *min_y, float *min_z,
    float *max_x, float *max_y, float *max_z);

/**
 * Export triangle mesh for 3D preview (object-space mm).
 * Caller must free *out_positions and *out_indices with orca_free().
 * positions: xyz float triples (vertex_count * 3)
 * indices: triangle vertex indices (index_count, multiple of 3)
 * @return 0 on success
 */
ORCA_API int orca_session_export_mesh(
    orca_session_t *s,
    float **out_positions,
    size_t *out_vertex_count,
    uint32_t **out_indices,
    size_t *out_index_count);

/** Free memory returned by orca_session_export_mesh. */
ORCA_API void orca_free(void *p);

/** Number of model objects currently loaded. */
ORCA_API int orca_session_object_count(orca_session_t *s);

/**
 * Name of model object at index (0-based).
 * @return pointer valid until next API call on this session; NULL if OOB
 */
ORCA_API const char *orca_session_object_name(orca_session_t *s, int index);

/**
 * Read a DynamicPrintConfig option as string into buf.
 * @return 0 on success
 */
ORCA_API int orca_session_get_option(
    orca_session_t *s, const char *key, char *buf, size_t buf_len);

/** Center all objects on the printable bed (XY). */
ORCA_API int orca_session_center_on_bed(orca_session_t *s);

/**
 * Translate object by delta mm (world XY/Z). index = -1 applies to all objects.
 * @return 0 on success
 */
ORCA_API int orca_session_translate_object(
    orca_session_t *s, int index, float dx, float dy, float dz);

/**
 * Rotate object around Z by degrees (plate yaw). index = -1 → all.
 */
ORCA_API int orca_session_rotate_object_z(
    orca_session_t *s, int index, float degrees);

/**
 * Uniform scale object about its center. index = -1 → all.
 */
ORCA_API int orca_session_scale_object(
    orca_session_t *s, int index, float factor);

/**
 * Auto-arrange objects on bed (simple grid, not full nest2d).
 */
ORCA_API int orca_session_arrange(orca_session_t *s);

/**
 * Delete model object at index. Reindexes remaining objects.
 * @return 0 on success
 */
ORCA_API int orca_session_delete_object(orca_session_t *s, int index);

/**
 * Clear all model objects.
 */
ORCA_API int orca_session_clear_model(orca_session_t *s);

/**
 * Read printable bed size from config (printable_area polygon extents).
 * @return 0 on success
 */
ORCA_API int orca_session_bed_size(orca_session_t *s, float *width, float *depth, float *height);

/**
 * Convenience: set rectangular printable area 0..w × 0..d and printable_height h (mm).
 * Writes printable_area + printable_height into DynamicPrintConfig.
 * @return 0 on success
 */
ORCA_API int orca_session_set_printable_area(
    orca_session_t *s, float width, float depth, float height);

/**
 * Model summary for UI: object count and approximate solid volume (mm³).
 * volume_mm3 may be NULL to skip volume (cheaper). Volume uses mesh stats / its_volume.
 * @return 0 on success (has model); -1 if no model
 */
ORCA_API int orca_session_model_info(
    orca_session_t *s, int *object_count, float *volume_mm3);

/**
 * Duplicate object at index (clone + offset).
 * @return new object index, or <0 on error
 */
ORCA_API int orca_session_duplicate_object(orca_session_t *s, int index);

/**
 * Export mesh for a single object (world space after instances).
 * Same layout as orca_session_export_mesh; free with orca_free.
 */
ORCA_API int orca_session_export_object_mesh(
    orca_session_t *s,
    int index,
    float **out_positions,
    size_t *out_vertex_count,
    uint32_t **out_indices,
    size_t *out_index_count);

/**
 * Save project as 3MF (model + DynamicPrintConfig).
 * Implementation: Slic3r::store_3mf
 * @return 0 on success
 */
ORCA_API int orca_session_save_3mf(orca_session_t *s, const char *path);

/**
 * Stats from last successful slice (from GCodeProcessorResult).
 * time_sec: estimated print time (normal mode)
 * filament_mm3: total model extrusion volume (mm³)
 * layers: estimated layer count from Z range / layer_height (0 if unknown)
 * @return 0 if stats available
 */
ORCA_API int orca_session_last_slice_stats(
    orca_session_t *s,
    float *time_sec,
    float *filament_mm3,
    int *layers);

/**
 * Writable data dir for installed system presets (Documents/OrcaSlicer).
 * Call after create, before load_all_presets.
 */
ORCA_API int orca_session_set_data_dir(orca_session_t *s, const char *data_path);

/**
 * Install + load ALL system profiles from resources/profiles via official PresetBundle.
 * May take several seconds on first run (copies to data_dir/system).
 * @return 0 on success (partial vendor failures still return 0 if any loaded)
 */
ORCA_API int orca_session_load_all_presets(orca_session_t *s);

/** Number of system printer (machine) presets after load_all_presets. */
ORCA_API int orca_session_printer_count(orca_session_t *s);
ORCA_API const char *orca_session_printer_name(orca_session_t *s, int index);

ORCA_API int orca_session_process_count(orca_session_t *s);
ORCA_API const char *orca_session_process_name(orca_session_t *s, int index);

ORCA_API int orca_session_filament_count(orca_session_t *s);
ORCA_API const char *orca_session_filament_name(orca_session_t *s, int index);

/** Select machine / process / filament by exact preset name, then merge into session config. */
ORCA_API int orca_session_select_printer(orca_session_t *s, const char *name);
ORCA_API int orca_session_select_process(orca_session_t *s, const char *name);
ORCA_API int orca_session_select_filament(orca_session_t *s, const char *name);

/**
 * Apply currently selected presets → session DynamicPrintConfig (full_config).
 * Updates bed size from printable_area.
 */
ORCA_API int orca_session_apply_presets(orca_session_t *s);

/**
 * Path to machine cover PNG / bed texture under resources/profiles (may be empty).
 * Tries official bed_texture, then Vendor/Model_cover.png.
 */
ORCA_API int orca_session_printer_cover_path(
    orca_session_t *s, char *buf, size_t buf_len);

/**
 * Official bed texture path (grid/logo PNG from vendor model).
 * Prefer this for plate surface; cover is for picker thumbnails.
 */
ORCA_API int orca_session_printer_bed_texture_path(
    orca_session_t *s, char *buf, size_t buf_len);

/** Vendor id string for printer at index (empty if unknown). */
ORCA_API const char *orca_session_printer_vendor(orca_session_t *s, int index);

/** Currently selected preset names (empty string if none). */
ORCA_API const char *orca_session_selected_printer(orca_session_t *s);
ORCA_API const char *orca_session_selected_process(orca_session_t *s);
ORCA_API const char *orca_session_selected_filament(orca_session_t *s);

/** Whether system presets finished loading. */
ORCA_API int orca_session_presets_loaded(orca_session_t *s);

ORCA_API const char *orca_session_last_error(orca_session_t *s);

ORCA_API const char *orca_version_string(void);

#ifdef __cplusplus
}
#endif
