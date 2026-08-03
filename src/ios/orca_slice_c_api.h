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

/**
 * Full settings browser: enumerate DynamicPrintConfig keys (sorted).
 * Call after presets/options applied. Keys valid until next option_count/refresh.
 */
ORCA_API int orca_session_option_count(orca_session_t *s);
ORCA_API const char *orca_session_option_key(orca_session_t *s, int index);

/**
 * Option metadata from official print_config_def.
 * type_out: 0=bool 1=int 2=float 3=percent 4=string 5=enum 6=other
 * Buffers may be NULL to skip. @return 0 on success
 */
ORCA_API int orca_session_option_info(
    orca_session_t *s,
    const char *key,
    int *type_out,
    char *label_buf, size_t label_len,
    char *category_buf, size_t category_len,
    char *sidetext_buf, size_t sidetext_len);

/** Enum serialize keys / labels for coEnum options (from ConfigOptionDef). */
ORCA_API int orca_session_option_enum_count(orca_session_t *s, const char *key);
ORCA_API const char *orca_session_option_enum_value(orca_session_t *s, const char *key, int index);
ORCA_API const char *orca_session_option_enum_label(orca_session_t *s, const char *key, int index);

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
 * Rotate around axis: axis 0=X, 1=Y, 2=Z (degrees). index = -1 → all.
 */
ORCA_API int orca_session_rotate_object_axis(
    orca_session_t *s, int index, int axis, float degrees);

/**
 * Mirror object on axis 0=X, 1=Y, 2=Z. index = -1 → all.
 */
ORCA_API int orca_session_mirror_object(
    orca_session_t *s, int index, int axis);

/**
 * Uniform scale object about its center. index = -1 → all.
 */
ORCA_API int orca_session_scale_object(
    orca_session_t *s, int index, float factor);

/**
 * Uniform scale so object fits bed with margin_mm padding. index = -1 → all (each).
 */
ORCA_API int orca_session_scale_to_fit(
    orca_session_t *s, int index, float margin_mm);

/**
 * Official auto-orient (libslic3r orient) for object; index = -1 → all.
 */
ORCA_API int orca_session_orient_object(orca_session_t *s, int index);

/**
 * Auto-arrange objects on bed (libnest2d arrange_objects).
 */
ORCA_API int orca_session_arrange(orca_session_t *s);

/**
 * FFF extruder / multi-filament slots from selected printer.
 * @return nozzle count (max(1, nozzle_diameter.size()))
 */
ORCA_API int orca_session_extruder_count(orca_session_t *s);

/**
 * Filament preset name assigned to extruder slot (0-based).
 * Pointer valid until next API call; empty string if unset.
 */
ORCA_API const char *orca_session_filament_slot_name(orca_session_t *s, int slot);

/**
 * Assign system/user filament preset to extruder slot, then apply_presets.
 */
ORCA_API int orca_session_set_filament_slot(
    orca_session_t *s, int slot, const char *filament_name);

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
 * When enabled (default 1), process/filament lists only include presets marked
 * is_compatible with the selected printer (official update_compatible).
 */
ORCA_API void orca_session_set_compatible_only(orca_session_t *s, int enabled);
ORCA_API int orca_session_get_compatible_only(orca_session_t *s);

/**
 * Save current session process-related config as a user process preset JSON
 * under data_dir/user_presets/process/{name}.json. Survives app relaunch.
 */
ORCA_API int orca_session_save_user_process(orca_session_t *s, const char *name);

/** Number of user-saved process presets (also merged into process list). */
ORCA_API int orca_session_user_process_count(orca_session_t *s);
ORCA_API const char *orca_session_user_process_name(orca_session_t *s, int index);

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

/**
 * Lightweight catalog stats for memory / UI budgeting.
 * printers / process / filament counts after last name-cache refresh.
 * @return 0 on success
 */
ORCA_API int orca_session_preset_stats(
    orca_session_t *s, int *printers, int *process, int *filament);

/**
 * Drop settings-browser caches (option key / enum lists). Safe anytime.
 * Call under memory pressure; next option_count rebuilds.
 */
ORCA_API void orca_session_purge_option_caches(orca_session_t *s);

/**
 * Official calibration mode for next slice (Print::set_calib_params).
 * mode matches Slic3r::CalibMode:
 *   0=None 1=PA_Line 2=PA_Pattern 3=PA_Tower 4=Auto_PA_Line
 *   5=Flow_Rate 6=Temp_Tower 7=Vol_speed_Tower 8=VFA_Tower
 *   9=Retraction_tower 10=Input_shaping_freq 11=Input_shaping_damp 12=Cornering
 * start/end/step: tower or PA sweep ranges (temps °C, PA unitless, retraction mm, …).
 * @return 0 on success
 */
ORCA_API int orca_session_set_calib(
    orca_session_t *s, int mode, double start, double end, double step);

/** Clear calibration (mode = None). Next slice is a normal print. */
ORCA_API int orca_session_clear_calib(orca_session_t *s);

/** Current calib mode (CalibMode int), or 0 if none / null session. */
ORCA_API int orca_session_get_calib_mode(orca_session_t *s);

ORCA_API const char *orca_session_last_error(orca_session_t *s);

ORCA_API const char *orca_version_string(void);

#ifdef __cplusplus
}
#endif
