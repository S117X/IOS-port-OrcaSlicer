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
 */
ORCA_API int orca_session_load_model(orca_session_t *s, const char *path);

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

ORCA_API const char *orca_session_last_error(orca_session_t *s);

ORCA_API const char *orca_version_string(void);

#ifdef __cplusplus
}
#endif
