/**
 * OrcaSlicer iOS C ABI — wraps official libslic3r (not a reimplementation).
 *
 * Uses:
 *   Slic3r::Model::read_from_file
 *   Slic3r::DynamicPrintConfig / PrintConfig::full_print_config
 *   Slic3r::Print::apply / process / export_gcode
 *
 * Source: https://github.com/OrcaSlicer/OrcaSlicer
 * License: AGPL-3.0
 */

#include "orca_slice_c_api.h"

#include <exception>
#include <memory>
#include <string>

#include "libslic3r/Config.hpp"
#include "libslic3r/Model.hpp"
#include "libslic3r/Print.hpp"
#include "libslic3r/PrintConfig.hpp"
#include "libslic3r/GCode/GCodeProcessor.hpp"
#include "libslic3r/ExtrusionEntity.hpp"
#include "libslic3r/TriangleMesh.hpp"
#include "libslic3r/Utils.hpp"
#include "libslic3r/Format/3mf.hpp"
// Generated into build dir as libslic3r_version.h (include path via libslic3r target)
#include "libslic3r_version.h"
#include "libslic3r/PresetBundle.hpp"
#include "libslic3r/Preset.hpp"
#include "libslic3r/AppConfig.hpp"
#include "libslic3r/ModelArrange.hpp"
#include "libslic3r/Arrange.hpp"
#include "libslic3r/Orient.hpp"
#include "libslic3r/calib.hpp"
#include "libslic3r/CutUtils.hpp"
#include "libslic3r/MeshBoolean.hpp"
#include "libslic3r/Geometry.hpp"
#include "libslic3r/TriangleSelector.hpp"
#include "libslic3r/BrimEarsPoint.hpp"
#include "libslic3r/QuadricEdgeCollapse.hpp"

#include <cstdlib>
#include <cstring>
#include <cstdio>
#include <cctype>
#include <vector>
#include <cmath>
#include <functional>
#include <algorithm>
#include <limits>
#include <boost/filesystem.hpp>

using namespace Slic3r;
namespace fs = boost::filesystem;

struct orca_session {
    std::string resources_path;
    std::string data_dir_path;
    std::string last_error;
    Model       model;
    DynamicPrintConfig config;
    bool        has_model{false};
    bool        has_config{false};
    orca_progress_fn progress_fn{nullptr};
    void *      progress_user{nullptr};
    // Last slice stats (from GCodeProcessorResult)
    bool        has_slice_stats{false};
    float       last_time_sec{0.f};
    float       last_initial_layer_time_sec{0.f};
    float       last_filament_mm3{0.f};
    float       last_support_mm3{0.f};
    float       last_wipe_tower_mm3{0.f};
    int         last_layers{0};
    // Filament by extrusion role: name, meters, grams
    std::vector<std::string> role_names;
    std::vector<float>       role_meters;
    std::vector<float>       role_grams;

    // Official calibration (applied at slice via Print::set_calib_params)
    Calib_Params calib_params;

    // Official system preset catalog
    std::unique_ptr<PresetBundle> preset_bundle;
    bool        presets_loaded{false};
    std::vector<std::string> printer_names;
    std::vector<std::string> process_names;
    std::vector<std::string> filament_names;
    std::vector<std::string> printer_vendors; // parallel to printer_names
    std::string cover_path_cache;
    std::string bed_texture_cache;
    std::string selected_printer_cache;
    std::string selected_process_cache;
    std::string selected_filament_cache;

    // Settings browser caches (keys / enum lists valid until next refresh)
    std::vector<std::string> option_keys_cache;
    std::vector<std::string> enum_values_cache;
    std::vector<std::string> enum_labels_cache;
    std::string enum_lookup_key;

    void set_error(const std::string &e) { last_error = e; }
    void clear_error() { last_error.clear(); }
    void report_progress(int pct, const char *msg) {
        if (progress_fn)
            progress_fn(pct, msg, progress_user);
    }

    bool filter_compatible_only{true};
    bool active_process_from_user{false};
    bool active_filament_from_user{false};
    std::vector<std::string> user_process_names;
    std::vector<std::string> user_filament_names;

    // Assembly explode: per-object per-instance baseline offsets (world mm)
    bool has_explode_baseline{false};
    std::vector<std::vector<Vec3d>> explode_baseline_offsets;
    float explode_factor_current{0.f};

    void refresh_name_caches() {
        printer_names.clear();
        process_names.clear();
        filament_names.clear();
        printer_vendors.clear();
        if (!preset_bundle)
            return;
        for (const Preset &p : preset_bundle->printers) {
            if (p.is_default)
                continue;
            printer_names.push_back(p.name);
            if (p.vendor)
                printer_vendors.push_back(p.vendor->name);
            else
                printer_vendors.push_back("");
        }
        // Process / filament: after printer select, only list compatible presets
        // (official is_compatible flag set by PresetBundle::update_compatible).
        for (const Preset &p : preset_bundle->prints) {
            if (p.is_default)
                continue;
            if (filter_compatible_only && !p.is_compatible)
                continue;
            process_names.push_back(p.name);
        }
        for (const Preset &p : preset_bundle->filaments) {
            if (p.is_default)
                continue;
            if (filter_compatible_only && !p.is_compatible)
                continue;
            filament_names.push_back(p.name);
        }
        // Append user-saved process / filament presets (always listed)
        for (const std::string &u : user_process_names) {
            if (std::find(process_names.begin(), process_names.end(), u) == process_names.end())
                process_names.push_back(u);
        }
        for (const std::string &u : user_filament_names) {
            if (std::find(filament_names.begin(), filament_names.end(), u) == filament_names.end())
                filament_names.push_back(u);
        }
        std::sort(printer_names.begin(), printer_names.end());
        // Keep vendors aligned after sort — rebuild vendors map
        std::vector<std::string> vendors_sorted;
        vendors_sorted.reserve(printer_names.size());
        for (const std::string &n : printer_names) {
            const Preset *pp = preset_bundle->printers.find_preset(n);
            if (pp && pp->vendor)
                vendors_sorted.push_back(pp->vendor->name);
            else
                vendors_sorted.push_back("");
        }
        printer_vendors = std::move(vendors_sorted);
        std::sort(process_names.begin(), process_names.end());
        std::sort(filament_names.begin(), filament_names.end());
        sync_selected_caches();
    }

    fs::path user_process_dir() const {
        return fs::path(data_dir_path.empty() ? "." : data_dir_path) / "user_presets" / "process";
    }

    fs::path user_filament_dir() const {
        return fs::path(data_dir_path.empty() ? "." : data_dir_path) / "user_presets" / "filament";
    }

    static std::string sanitize_preset_name(const char *name) {
        std::string safe;
        if (!name)
            return safe;
        for (const char *p = name; *p; ++p) {
            char c = *p;
            if (std::isalnum((unsigned char)c) || c == ' ' || c == '-' || c == '_' || c == '.')
                safe.push_back(c);
            else
                safe.push_back('_');
        }
        return safe;
    }

    static void scan_user_preset_dir(const fs::path &dir, std::vector<std::string> &out) {
        out.clear();
        try {
            if (!fs::exists(dir))
                return;
            for (fs::directory_iterator it(dir), end; it != end; ++it) {
                if (!fs::is_regular_file(it->path()))
                    continue;
                if (it->path().extension() != ".json")
                    continue;
                out.push_back(it->path().stem().string());
            }
            std::sort(out.begin(), out.end());
        } catch (...) {
        }
    }

    void scan_user_process_presets() {
        scan_user_preset_dir(user_process_dir(), user_process_names);
    }

    void scan_user_filament_presets() {
        scan_user_preset_dir(user_filament_dir(), user_filament_names);
    }

    void sync_selected_caches() {
        selected_printer_cache.clear();
        selected_process_cache.clear();
        selected_filament_cache.clear();
        if (!preset_bundle)
            return;
        try {
            selected_printer_cache = preset_bundle->printers.get_selected_preset().name;
            selected_process_cache  = preset_bundle->prints.get_selected_preset().name;
            selected_filament_cache = preset_bundle->filaments.get_selected_preset().name;
        } catch (...) {
        }
    }

    /** Resolve cover / bed art under profiles/{vendor}/… with several name variants. */
    bool resolve_profile_image(const std::string &vendor, const std::string &model,
                               const std::string &suffix, std::string &out) const {
        if (resources_path.empty() || vendor.empty() || model.empty())
            return false;
        const std::string candidates[] = {
            model + suffix,
            model + "_cover.png",
            model + ".png",
        };
        for (const std::string &file : candidates) {
            fs::path p = fs::path(resources_path) / "profiles" / vendor / file;
            if (fs::exists(p)) {
                out = p.string();
                return true;
            }
        }
        return false;
    }
};

static void ensure_default_config(orca_session *s)
{
    if (s->has_config)
        return;
    // Official defaults from libslic3r (API lives on DynamicPrintAndCLIConfig)
    s->config = DynamicPrintAndCLIConfig::full_print_config();
    s->has_config = true;
}

extern "C" {

orca_session_t *orca_session_create(const char *resources_path)
{
    try {
        auto *s = new orca_session();
        if (resources_path && *resources_path)
            s->resources_path = resources_path;
        // Point libslic3r at bundled resources (profiles, nozzle_info.json, …)
        if (!s->resources_path.empty()) {
            set_resources_dir(s->resources_path);
            set_var_dir(s->resources_path);
        }
        s->config = DynamicPrintAndCLIConfig::full_print_config();
        s->has_config = true;
        return s;
    } catch (const std::exception &ex) {
        (void) ex;
        return nullptr;
    } catch (...) {
        return nullptr;
    }
}

void orca_session_destroy(orca_session_t *s)
{
    delete s;
}

static int load_model_impl(orca_session_t *s, const char *path, bool append)
{
    if (!s || !path)
        return -1;
    s->clear_error();
    try {
        DynamicPrintConfig  file_config;
        ConfigSubstitutionContext substitutions(ForwardCompatibilitySubstitutionRule::EnableSilent);
        Model incoming = Model::read_from_file(
            std::string(path),
            &file_config,
            &substitutions,
            LoadStrategy::AddDefaultInstances);
        if (incoming.objects.empty()) {
            s->set_error("Model has no objects after load");
            if (!append) {
                s->has_model = false;
            }
            return -2;
        }
        ensure_default_config(s);
        s->config.apply(file_config);

        if (!append) {
            s->model = std::move(incoming);
        } else {
            // Add objects onto existing plate (official Model::add_object)
            for (ModelObject *obj : incoming.objects) {
                if (!obj)
                    continue;
                ModelObject *added = s->model.add_object(*obj);
                if (added) {
                    for (ModelInstance *inst : added->instances) {
                        if (inst)
                            inst->set_offset(inst->get_offset() + Vec3d(12.0, 12.0, 0.0));
                    }
                    added->invalidate_bounding_box();
                    added->ensure_on_bed();
                }
            }
        }
        for (ModelObject *obj : s->model.objects) {
            if (obj)
                obj->ensure_on_bed();
        }
        s->has_model = !s->model.objects.empty();
        s->has_slice_stats = false;
        return 0;
    } catch (const std::exception &ex) {
        s->set_error(std::string("load_model: ") + ex.what());
        if (!append)
            s->has_model = false;
        return -3;
    } catch (...) {
        s->set_error("load_model: unknown error");
        if (!append)
            s->has_model = false;
        return -3;
    }
}

int orca_session_load_model(orca_session_t *s, const char *path)
{
    return load_model_impl(s, path, false);
}

int orca_session_add_model(orca_session_t *s, const char *path)
{
    return load_model_impl(s, path, true);
}

int orca_session_load_config(orca_session_t *s, const char *config_path)
{
    if (!s || !config_path)
        return -1;
    s->clear_error();
    try {
        ensure_default_config(s);
        std::string path(config_path);
        ConfigSubstitutions subs;
        if (path.size() >= 5 &&
            (path.compare(path.size() - 5, 5, ".json") == 0 ||
             path.compare(path.size() - 5, 5, ".JSON") == 0)) {
            std::map<std::string, std::string> key_values;
            std::string reason;
            ConfigSubstitutionContext ctx(ForwardCompatibilitySubstitutionRule::Enable);
            int rc = s->config.load_from_json(path, ctx, true, key_values, reason);
            if (rc != 0) {
                s->set_error(reason.empty() ? "load_from_json failed" : reason);
                return -2;
            }
        } else {
            // .ini / gcode-style config
            subs = s->config.load_from_ini(path, ForwardCompatibilitySubstitutionRule::Enable);
            (void) subs;
        }
        s->has_config = true;
        return 0;
    } catch (const std::exception &ex) {
        s->set_error(std::string("load_config: ") + ex.what());
        return -3;
    } catch (...) {
        s->set_error("load_config: unknown error");
        return -3;
    }
}

int orca_session_set_option(orca_session_t *s, const char *key, const char *value)
{
    if (!s || !key || !value)
        return -1;
    s->clear_error();
    try {
        ensure_default_config(s);
        // DynamicPrintConfig option set by string (official ConfigBase API)
        s->config.set_deserialize_strict(key, value);
        return 0;
    } catch (const std::exception &ex) {
        s->set_error(std::string("set_option: ") + ex.what());
        return -2;
    } catch (...) {
        s->set_error("set_option: unknown error");
        return -2;
    }
}

void orca_session_set_progress_callback(
    orca_session_t *s, orca_progress_fn fn, void *user)
{
    if (!s)
        return;
    s->progress_fn = fn;
    s->progress_user = user;
}

int orca_session_slice_to_gcode(orca_session_t *s, const char *gcode_out_path)
{
    if (!s || !gcode_out_path)
        return -1;
    s->clear_error();
    if (!s->has_model) {
        s->set_error("No model loaded");
        return -2;
    }
    try {
        ensure_default_config(s);
        s->report_progress(5, "Applying config");

        Print print;
        // Center / place objects if needed — use model as loaded
        auto status = print.apply(s->model, s->config);
        (void) status;
        if (print.empty()) {
            s->set_error("Print empty after apply — objects outside bed or invalid");
            return -3;
        }

        // Official calibration path (temp tower / PA / flow / retraction, …)
        if (s->calib_params.mode != CalibMode::Calib_None) {
            print.set_calib_params(s->calib_params);
            s->report_progress(12, "Calibration mode active");
        }

        print.set_status_silent();
        s->report_progress(15, "Slicing (Print::process)");
        print.process();

        s->report_progress(85, "Exporting G-code");
        GCodeProcessorResult result;
        std::string out = print.export_gcode(std::string(gcode_out_path), &result, nullptr);
        if (out.empty()) {
            s->set_error("export_gcode returned empty path");
            return -4;
        }
        // Capture official GCodeProcessor statistics for UI
        s->has_slice_stats = true;
        s->last_time_sec = result.print_statistics.modes[
            static_cast<size_t>(PrintEstimatedStatistics::ETimeMode::Normal)].time;
        s->last_initial_layer_time_sec = result.initial_layer_time;
        double vol = 0.0;
        for (const auto &kv : result.print_statistics.model_volumes_per_extruder)
            vol += kv.second;
        s->last_filament_mm3 = float(vol);
        double support_vol = 0.0;
        for (const auto &kv : result.print_statistics.support_volumes_per_extruder)
            support_vol += kv.second;
        s->last_support_mm3 = float(support_vol);
        double wipe_vol = 0.0;
        for (const auto &kv : result.print_statistics.wipe_tower_volumes_per_extruder)
            wipe_vol += kv.second;
        s->last_wipe_tower_mm3 = float(wipe_vol);
        // Filament usage by extrusion role (meters + grams)
        s->role_names.clear();
        s->role_meters.clear();
        s->role_grams.clear();
        for (const auto &kv : result.print_statistics.used_filaments_per_role) {
            std::string name = ExtrusionEntity::role_to_string(kv.first);
            s->role_names.push_back(name);
            s->role_meters.push_back(float(kv.second.first));
            s->role_grams.push_back(float(kv.second.second));
        }
        // Layer count estimate from model height / layer_height
        s->last_layers = 0;
        try {
            BoundingBoxf3 bb = s->model.bounding_box_exact();
            double lh = 0.2;
            if (const ConfigOptionFloat *opt = s->config.option<ConfigOptionFloat>("layer_height"))
                lh = opt->value > 1e-6 ? opt->value : 0.2;
            s->last_layers = std::max(1, int(std::ceil(bb.size().z() / lh)));
        } catch (...) {
            s->last_layers = 0;
        }
        s->report_progress(100, "Done");
        return 0;
    } catch (const std::exception &ex) {
        s->set_error(std::string("slice: ") + ex.what());
        return -5;
    } catch (...) {
        s->set_error("slice: unknown error");
        return -5;
    }
}

int orca_session_model_bounds(
    orca_session_t *s,
    float *min_x, float *min_y, float *min_z,
    float *max_x, float *max_y, float *max_z)
{
    if (!s || !s->has_model)
        return -1;
    try {
        BoundingBoxf3 bb = s->model.bounding_box_exact();
        if (min_x) *min_x = float(bb.min.x());
        if (min_y) *min_y = float(bb.min.y());
        if (min_z) *min_z = float(bb.min.z());
        if (max_x) *max_x = float(bb.max.x());
        if (max_y) *max_y = float(bb.max.y());
        if (max_z) *max_z = float(bb.max.z());
        return 0;
    } catch (const std::exception &ex) {
        s->set_error(std::string("bounds: ") + ex.what());
        return -2;
    } catch (...) {
        s->set_error("bounds: unknown error");
        return -2;
    }
}

int orca_session_export_mesh(
    orca_session_t *s,
    float **out_positions,
    size_t *out_vertex_count,
    uint32_t **out_indices,
    size_t *out_index_count)
{
    if (!s || !out_positions || !out_vertex_count || !out_indices || !out_index_count)
        return -1;
    *out_positions = nullptr;
    *out_indices = nullptr;
    *out_vertex_count = 0;
    *out_index_count = 0;
    if (!s->has_model) {
        s->set_error("No model loaded");
        return -2;
    }
    try {
        // Combined mesh of all objects/instances (world / assembly space)
        TriangleMesh mesh = s->model.mesh();
        const indexed_triangle_set &its = mesh.its;
        if (its.vertices.empty() || its.indices.empty()) {
            s->set_error("Mesh empty");
            return -3;
        }

        const size_t nv = its.vertices.size();
        const size_t nf = its.indices.size();
        auto *pos = static_cast<float *>(std::malloc(nv * 3 * sizeof(float)));
        auto *idx = static_cast<uint32_t *>(std::malloc(nf * 3 * sizeof(uint32_t)));
        if (!pos || !idx) {
            std::free(pos);
            std::free(idx);
            s->set_error("out of memory");
            return -4;
        }
        for (size_t i = 0; i < nv; ++i) {
            pos[i * 3 + 0] = its.vertices[i].x();
            pos[i * 3 + 1] = its.vertices[i].y();
            pos[i * 3 + 2] = its.vertices[i].z();
        }
        for (size_t i = 0; i < nf; ++i) {
            idx[i * 3 + 0] = uint32_t(its.indices[i][0]);
            idx[i * 3 + 1] = uint32_t(its.indices[i][1]);
            idx[i * 3 + 2] = uint32_t(its.indices[i][2]);
        }
        *out_positions = pos;
        *out_vertex_count = nv;
        *out_indices = idx;
        *out_index_count = nf * 3;
        return 0;
    } catch (const std::exception &ex) {
        s->set_error(std::string("export_mesh: ") + ex.what());
        return -5;
    } catch (...) {
        s->set_error("export_mesh: unknown error");
        return -5;
    }
}

void orca_free(void *p)
{
    std::free(p);
}

int orca_session_object_count(orca_session_t *s)
{
    if (!s || !s->has_model)
        return 0;
    return int(s->model.objects.size());
}

const char *orca_session_object_name(orca_session_t *s, int index)
{
    if (!s || !s->has_model || index < 0 || index >= int(s->model.objects.size()))
        return nullptr;
    ModelObject *obj = s->model.objects[size_t(index)];
    if (!obj)
        return nullptr;
    // lifetime: session-owned string field
    return obj->name.c_str();
}

int orca_session_get_option(
    orca_session_t *s, const char *key, char *buf, size_t buf_len)
{
    if (!s || !key || !buf || buf_len == 0)
        return -1;
    buf[0] = '\0';
    try {
        ensure_default_config(s);
        const ConfigOption *opt = s->config.option(key);
        if (!opt) {
            s->set_error(std::string("unknown option: ") + key);
            return -2;
        }
        std::string val = opt->serialize();
        if (val.size() >= buf_len) {
            s->set_error("buffer too small");
            return -3;
        }
        std::memcpy(buf, val.c_str(), val.size() + 1);
        return 0;
    } catch (const std::exception &ex) {
        s->set_error(std::string("get_option: ") + ex.what());
        return -4;
    } catch (...) {
        s->set_error("get_option: unknown error");
        return -4;
    }
}

static void refresh_option_keys_cache(orca_session_t *s)
{
    ensure_default_config(s);
    s->option_keys_cache = s->config.keys();
    std::sort(s->option_keys_cache.begin(), s->option_keys_cache.end());
}

static int map_option_type(ConfigOptionType t)
{
    // UI kinds: 0=bool 1=int 2=float 3=percent 4=string 5=enum 6=other
    switch (t) {
    case coBool:
    case coBools:
        return 0;
    case coInt:
    case coInts:
        return 1;
    case coFloat:
    case coFloats:
    case coPoint:
    case coPoints:
    case coPoint3:
        return 2;
    case coPercent:
    case coPercents:
    case coFloatOrPercent:
    case coFloatsOrPercents:
        return 3;
    case coString:
    case coStrings:
        return 4;
    case coEnum:
    case coEnums:
        return 5;
    default:
        return 6;
    }
}

static const ConfigOptionDef *lookup_option_def(const char *key)
{
    if (!key || !*key)
        return nullptr;
    return print_config_def.get(std::string(key));
}

static void load_enum_lists(orca_session_t *s, const char *key)
{
    if (!s || !key)
        return;
    if (s->enum_lookup_key == key && !s->enum_values_cache.empty())
        return;
    s->enum_lookup_key = key;
    s->enum_values_cache.clear();
    s->enum_labels_cache.clear();
    const ConfigOptionDef *def = lookup_option_def(key);
    if (!def)
        return;
    // Prefer explicit enum_values (serialize keys). Labels optional.
    if (!def->enum_values.empty()) {
        s->enum_values_cache = def->enum_values;
        if (def->enum_labels.size() == def->enum_values.size())
            s->enum_labels_cache = def->enum_labels;
        else
            s->enum_labels_cache = def->enum_values;
        return;
    }
    // Fallback: enum_keys_map (value string → int)
    if (def->enum_keys_map) {
        std::vector<std::pair<int, std::string>> ordered;
        ordered.reserve(def->enum_keys_map->size());
        for (const auto &kv : *def->enum_keys_map)
            ordered.emplace_back(kv.second, kv.first);
        std::sort(ordered.begin(), ordered.end());
        for (const auto &p : ordered) {
            s->enum_values_cache.push_back(p.second);
            s->enum_labels_cache.push_back(p.second);
        }
    }
}

int orca_session_option_count(orca_session_t *s)
{
    if (!s)
        return 0;
    try {
        refresh_option_keys_cache(s);
        return (int)s->option_keys_cache.size();
    } catch (...) {
        return 0;
    }
}

const char *orca_session_option_key(orca_session_t *s, int index)
{
    if (!s || index < 0)
        return nullptr;
    if (s->option_keys_cache.empty()) {
        try {
            refresh_option_keys_cache(s);
        } catch (...) {
            return nullptr;
        }
    }
    if (index >= (int)s->option_keys_cache.size())
        return nullptr;
    return s->option_keys_cache[(size_t)index].c_str();
}

static void copy_str_buf(char *buf, size_t len, const std::string &src)
{
    if (!buf || len == 0)
        return;
    if (src.size() >= len) {
        std::memcpy(buf, src.c_str(), len - 1);
        buf[len - 1] = '\0';
    } else {
        std::memcpy(buf, src.c_str(), src.size() + 1);
    }
}

int orca_session_option_info(
    orca_session_t *s,
    const char *key,
    int *type_out,
    char *label_buf, size_t label_len,
    char *category_buf, size_t category_len,
    char *sidetext_buf, size_t sidetext_len)
{
    if (!s || !key)
        return -1;
    try {
        ensure_default_config(s);
        const ConfigOptionDef *def = lookup_option_def(key);
        int type = 6;
        std::string label = key;
        std::string category;
        std::string sidetext;
        if (def) {
            type = map_option_type(def->type);
            if (!def->label.empty())
                label = def->label;
            else if (!def->full_label.empty())
                label = def->full_label;
            category = def->category;
            sidetext = def->sidetext;
            // Open enum-style float/int combos still expose enum_values
            if (type != 5 && !def->enum_values.empty())
                type = 5;
        } else {
            // Infer from live option if def missing
            if (const ConfigOption *opt = s->config.option(key))
                type = map_option_type(opt->type());
        }
        if (type_out)
            *type_out = type;
        copy_str_buf(label_buf, label_len, label);
        copy_str_buf(category_buf, category_len, category);
        copy_str_buf(sidetext_buf, sidetext_len, sidetext);
        return 0;
    } catch (const std::exception &ex) {
        s->set_error(std::string("option_info: ") + ex.what());
        return -2;
    } catch (...) {
        s->set_error("option_info: unknown error");
        return -2;
    }
}

int orca_session_option_enum_count(orca_session_t *s, const char *key)
{
    if (!s || !key)
        return 0;
    try {
        load_enum_lists(s, key);
        return (int)s->enum_values_cache.size();
    } catch (...) {
        return 0;
    }
}

const char *orca_session_option_enum_value(orca_session_t *s, const char *key, int index)
{
    if (!s || !key || index < 0)
        return nullptr;
    try {
        load_enum_lists(s, key);
        if (index >= (int)s->enum_values_cache.size())
            return nullptr;
        return s->enum_values_cache[(size_t)index].c_str();
    } catch (...) {
        return nullptr;
    }
}

const char *orca_session_option_enum_label(orca_session_t *s, const char *key, int index)
{
    if (!s || !key || index < 0)
        return nullptr;
    try {
        load_enum_lists(s, key);
        if (index >= (int)s->enum_labels_cache.size()) {
            // Fall back to value string
            if (index < (int)s->enum_values_cache.size())
                return s->enum_values_cache[(size_t)index].c_str();
            return nullptr;
        }
        return s->enum_labels_cache[(size_t)index].c_str();
    } catch (...) {
        return nullptr;
    }
}

int orca_session_center_on_bed(orca_session_t *s)
{
    if (!s || !s->has_model)
        return -1;
    try {
        ensure_default_config(s);
        // printable_area is a Points polygon; compute center from config if present
        BoundingBoxf3 bb = s->model.bounding_box_exact();
        Vec3d center = bb.center();
        double bed_cx = 110.0, bed_cy = 110.0;
        if (const ConfigOptionPoints *pa = s->config.option<ConfigOptionPoints>("printable_area")) {
            if (!pa->values.empty()) {
                BoundingBoxf bedbb;
                for (const Vec2d &p : pa->values)
                    bedbb.merge(Vec2d(p.x(), p.y()));
                bed_cx = (bedbb.min.x() + bedbb.max.x()) * 0.5;
                bed_cy = (bedbb.min.y() + bedbb.max.y()) * 0.5;
            }
        }
        Vec3d shift(bed_cx - center.x(), bed_cy - center.y(), 0.0);
        for (ModelObject *obj : s->model.objects) {
            if (!obj) continue;
            for (ModelInstance *inst : obj->instances) {
                if (!inst) continue;
                inst->set_offset(inst->get_offset() + shift);
            }
            obj->invalidate_bounding_box();
            obj->ensure_on_bed();
        }
        return 0;
    } catch (const std::exception &ex) {
        s->set_error(std::string("center_on_bed: ") + ex.what());
        return -2;
    } catch (...) {
        s->set_error("center_on_bed: unknown error");
        return -2;
    }
}

static void for_each_object(orca_session_t *s, int index, const std::function<void(ModelObject *)> &fn)
{
    if (index < 0) {
        for (ModelObject *obj : s->model.objects)
            if (obj) fn(obj);
    } else if (index < int(s->model.objects.size())) {
        if (ModelObject *obj = s->model.objects[size_t(index)])
            fn(obj);
    }
}

int orca_session_translate_object(
    orca_session_t *s, int index, float dx, float dy, float dz)
{
    if (!s || !s->has_model)
        return -1;
    try {
        const Vec3d delta(dx, dy, dz);
        for_each_object(s, index, [&](ModelObject *obj) {
            for (ModelInstance *inst : obj->instances) {
                if (!inst) continue;
                inst->set_offset(inst->get_offset() + delta);
            }
            obj->invalidate_bounding_box();
        });
        return 0;
    } catch (const std::exception &ex) {
        s->set_error(std::string("translate: ") + ex.what());
        return -2;
    } catch (...) {
        s->set_error("translate: unknown error");
        return -2;
    }
}

int orca_session_rotate_object_z(orca_session_t *s, int index, float degrees)
{
    return orca_session_rotate_object_axis(s, index, 2, degrees);
}

int orca_session_rotate_object_axis(
    orca_session_t *s, int index, int axis, float degrees)
{
    if (!s || !s->has_model || axis < 0 || axis > 2)
        return -1;
    try {
        const double rad = double(degrees) * M_PI / 180.0;
        const Axis ax = axis == 0 ? X : (axis == 1 ? Y : Z);
        for_each_object(s, index, [&](ModelObject *obj) {
            for (ModelInstance *inst : obj->instances) {
                if (!inst) continue;
                inst->set_rotation(ax, inst->get_rotation(ax) + rad);
            }
            obj->invalidate_bounding_box();
            obj->ensure_on_bed();
        });
        return 0;
    } catch (const std::exception &ex) {
        s->set_error(std::string("rotate_axis: ") + ex.what());
        return -2;
    } catch (...) {
        s->set_error("rotate_axis: unknown error");
        return -2;
    }
}

int orca_session_mirror_object(orca_session_t *s, int index, int axis)
{
    if (!s || !s->has_model || axis < 0 || axis > 2)
        return -1;
    try {
        const Axis ax = axis == 0 ? X : (axis == 1 ? Y : Z);
        for_each_object(s, index, [&](ModelObject *obj) {
            for (ModelInstance *inst : obj->instances) {
                if (!inst) continue;
                // Flip mirror sign on axis
                Vec3d m = inst->get_mirror();
                m[ax] = -m[ax];
                inst->set_mirror(m);
            }
            obj->invalidate_bounding_box();
            obj->ensure_on_bed();
        });
        return 0;
    } catch (const std::exception &ex) {
        s->set_error(std::string("mirror: ") + ex.what());
        return -2;
    } catch (...) {
        s->set_error("mirror: unknown error");
        return -2;
    }
}

int orca_session_scale_object(orca_session_t *s, int index, float factor)
{
    if (!s || !s->has_model || factor <= 0.f)
        return -1;
    try {
        for_each_object(s, index, [&](ModelObject *obj) {
            for (ModelInstance *inst : obj->instances) {
                if (!inst) continue;
                Vec3d sc = inst->get_scaling_factor();
                inst->set_scaling_factor(sc * double(factor));
            }
            obj->invalidate_bounding_box();
            obj->ensure_on_bed();
        });
        return 0;
    } catch (const std::exception &ex) {
        s->set_error(std::string("scale: ") + ex.what());
        return -2;
    } catch (...) {
        s->set_error("scale: unknown error");
        return -2;
    }
}

int orca_session_scale_to_fit(orca_session_t *s, int index, float margin_mm)
{
    if (!s || !s->has_model)
        return -1;
    try {
        ensure_default_config(s);
        float bed_w = 220.f, bed_d = 220.f, bed_h = 250.f;
        orca_session_bed_size(s, &bed_w, &bed_d, &bed_h);
        const double margin = std::max(0.0, double(margin_mm));
        const double usable_w = std::max(1.0, double(bed_w) - 2.0 * margin);
        const double usable_d = std::max(1.0, double(bed_d) - 2.0 * margin);
        const double usable_h = std::max(1.0, double(bed_h) - margin);

        for_each_object(s, index, [&](ModelObject *obj) {
            if (obj->instances.empty())
                return;
            BoundingBoxf3 bb = obj->instance_bounding_box(0);
            const double sx = bb.size().x();
            const double sy = bb.size().y();
            const double sz = bb.size().z();
            if (sx < 1e-6 || sy < 1e-6 || sz < 1e-6)
                return;
            double f = std::min({usable_w / sx, usable_d / sy, usable_h / sz, 1e6});
            if (f >= 0.999 && f <= 1.001)
                return; // already fits; still allow slight shrink only
            if (f > 1.0)
                f = 1.0; // only shrink to fit (do not auto-enlarge)
            for (ModelInstance *inst : obj->instances) {
                if (!inst) continue;
                Vec3d sc = inst->get_scaling_factor();
                inst->set_scaling_factor(sc * f);
            }
            obj->invalidate_bounding_box();
            obj->ensure_on_bed();
        });
        return 0;
    } catch (const std::exception &ex) {
        s->set_error(std::string("scale_to_fit: ") + ex.what());
        return -2;
    } catch (...) {
        s->set_error("scale_to_fit: unknown error");
        return -2;
    }
}

int orca_session_orient_object(orca_session_t *s, int index)
{
    if (!s || !s->has_model)
        return -1;
    try {
        for_each_object(s, index, [&](ModelObject *obj) {
            // Official auto-orient (Slic3r::orientation)
            for (ModelInstance *inst : obj->instances) {
                if (inst)
                    orientation::orient(inst);
            }
            try {
                orientation::orient(obj);
            } catch (...) {
            }
            obj->invalidate_bounding_box();
            obj->ensure_on_bed();
        });
        return 0;
    } catch (const std::exception &ex) {
        s->set_error(std::string("orient: ") + ex.what());
        return -2;
    } catch (...) {
        s->set_error("orient: unknown error");
        return -2;
    }
}

int orca_session_extruder_count(orca_session_t *s)
{
    if (!s)
        return 1;
    try {
        ensure_default_config(s);
        if (const ConfigOptionFloats *nd = s->config.option<ConfigOptionFloats>("nozzle_diameter")) {
            if (!nd->values.empty())
                return int(nd->values.size());
        }
        if (s->preset_bundle) {
            int n = s->preset_bundle->get_printer_extruder_count();
            if (n > 0)
                return n;
        }
        return 1;
    } catch (...) {
        return 1;
    }
}

const char *orca_session_filament_slot_name(orca_session_t *s, int slot)
{
    static thread_local std::string empty;
    empty.clear();
    if (!s || !s->preset_bundle || slot < 0)
        return empty.c_str();
    try {
        const auto &fps = s->preset_bundle->filament_presets;
        if (size_t(slot) >= fps.size())
            return empty.c_str();
        // Cache into selected_filament_cache only for slot 0; use cover_path_cache as temp for others
        // Prefer dedicated static storage per call via session string
        s->selected_filament_cache = fps[size_t(slot)];
        return s->selected_filament_cache.c_str();
    } catch (...) {
        return empty.c_str();
    }
}

int orca_session_set_filament_slot(orca_session_t *s, int slot, const char *filament_name)
{
    if (!s || !s->preset_bundle || !filament_name || slot < 0)
        return -1;
    try {
        // Grow filament_presets if needed
        auto &fps = s->preset_bundle->filament_presets;
        if (size_t(slot) >= fps.size())
            fps.resize(size_t(slot) + 1, fps.empty() ? std::string() : fps.front());
        if (!s->preset_bundle->filaments.select_preset_by_name(filament_name, true)) {
            s->set_error(std::string("filament not found: ") + filament_name);
            return -2;
        }
        s->preset_bundle->set_filament_preset(size_t(slot), filament_name);
        if (slot == 0)
            s->sync_selected_caches();
        s->config = s->preset_bundle->full_config(true);
        s->has_config = true;
        return 0;
    } catch (const std::exception &ex) {
        s->set_error(std::string("set_filament_slot: ") + ex.what());
        return -3;
    }
}

int orca_session_arrange(orca_session_t *s)
{
    if (!s || !s->has_model)
        return -1;
    try {
        ensure_default_config(s);
        s->model.add_default_instances();

        // Official libnest2d path (same family as desktop arrange_objects)
        Points bedpts = get_bed_shape(s->config);
        if (bedpts.size() < 3) {
            // Fallback 220² bed if printable_area missing
            bedpts = {
                Point(scaled(0.), scaled(0.)),
                Point(scaled(220.), scaled(0.)),
                Point(scaled(220.), scaled(220.)),
                Point(scaled(0.), scaled(220.))
            };
        }
        BoundingBox bedbb = get_extents(bedpts);
        arrangement::ArrangeParams params;
        // min_obj_distance is scaled; 6mm gap between objects is reasonable mobile default
        params.min_obj_distance = scaled(6.);
        params.accuracy = 0.65f;
        params.parallel = true;

        // Soft virtual-bed callback: do not throw if some items need a second plate
        auto vfn = [](arrangement::ArrangePolygon &ap) {
            if (ap.bed_idx == arrangement::UNARRANGED)
                ap.bed_idx = 0;
        };
        bool ok = arrange_objects(s->model, bedbb, params, vfn);
        if (!ok)
            s->set_error("arrange: some objects may not fit a single plate");
        for (ModelObject *obj : s->model.objects) {
            if (!obj) continue;
            obj->invalidate_bounding_box();
            obj->ensure_on_bed();
        }
        return 0;
    } catch (const std::exception &ex) {
        s->set_error(std::string("arrange: ") + ex.what());
        return -2;
    } catch (...) {
        s->set_error("arrange: unknown error");
        return -2;
    }
}

int orca_session_delete_object(orca_session_t *s, int index)
{
    if (!s || !s->has_model || index < 0 || index >= int(s->model.objects.size()))
        return -1;
    try {
        s->model.delete_object(size_t(index));
        if (s->model.objects.empty()) {
            s->has_model = false;
        }
        return 0;
    } catch (const std::exception &ex) {
        s->set_error(std::string("delete_object: ") + ex.what());
        return -2;
    } catch (...) {
        s->set_error("delete_object: unknown error");
        return -2;
    }
}

int orca_session_clear_model(orca_session_t *s)
{
    if (!s)
        return -1;
    try {
        s->model.clear_objects();
        s->has_model = false;
        return 0;
    } catch (const std::exception &ex) {
        s->set_error(std::string("clear_model: ") + ex.what());
        return -2;
    } catch (...) {
        s->set_error("clear_model: unknown error");
        return -2;
    }
}

int orca_session_bed_size(orca_session_t *s, float *width, float *depth, float *height)
{
    if (!s)
        return -1;
    try {
        ensure_default_config(s);
        float w = 220.f, d = 220.f, h = 250.f;
        if (const ConfigOptionPoints *pa = s->config.option<ConfigOptionPoints>("printable_area")) {
            if (!pa->values.empty()) {
                BoundingBoxf bedbb;
                for (const Vec2d &p : pa->values)
                    bedbb.merge(Vec2d(p.x(), p.y()));
                w = float(bedbb.max.x() - bedbb.min.x());
                d = float(bedbb.max.y() - bedbb.min.y());
            }
        }
        if (const ConfigOptionFloat *ph = s->config.option<ConfigOptionFloat>("printable_height")) {
            h = float(ph->value);
        }
        if (width) *width = w;
        if (depth) *depth = d;
        if (height) *height = h;
        return 0;
    } catch (const std::exception &ex) {
        s->set_error(std::string("bed_size: ") + ex.what());
        return -2;
    } catch (...) {
        s->set_error("bed_size: unknown error");
        return -2;
    }
}

int orca_session_set_printable_area(
    orca_session_t *s, float width, float depth, float height)
{
    if (!s || width <= 0.f || depth <= 0.f || height <= 0.f)
        return -1;
    s->clear_error();
    try {
        ensure_default_config(s);
        // Rectangular bed polygon: SW, SE, NE, NW (same convention as CLI / Swift setBedSize)
        char area[128];
        std::snprintf(area, sizeof(area), "0x0,%.6gx0,%.6gx%.6g,0x%.6g",
                      double(width), double(width), double(depth), double(depth));
        s->config.set_deserialize_strict("printable_area", area);
        char hbuf[64];
        std::snprintf(hbuf, sizeof(hbuf), "%.6g", double(height));
        s->config.set_deserialize_strict("printable_height", hbuf);
        return 0;
    } catch (const std::exception &ex) {
        s->set_error(std::string("set_printable_area: ") + ex.what());
        return -2;
    } catch (...) {
        s->set_error("set_printable_area: unknown error");
        return -2;
    }
}

int orca_session_model_info(
    orca_session_t *s, int *object_count, float *volume_mm3)
{
    if (!s)
        return -1;
    if (!s->has_model || s->model.objects.empty()) {
        if (object_count) *object_count = 0;
        if (volume_mm3) *volume_mm3 = 0.f;
        s->set_error("No model loaded");
        return -1;
    }
    try {
        if (object_count)
            *object_count = int(s->model.objects.size());
        if (volume_mm3) {
            // Approximate solid volume (mm³) via libslic3r its_volume on instance-transformed meshes.
            double vol = 0.0;
            for (ModelObject *obj : s->model.objects) {
                if (!obj) continue;
                TriangleMesh mesh = obj->mesh();
                float v = its_volume(mesh.its);
                if (v <= 0.f && mesh.stats().volume > 0.f)
                    v = mesh.stats().volume;
                if (v > 0.f)
                    vol += double(v);
            }
            *volume_mm3 = float(vol);
        }
        return 0;
    } catch (const std::exception &ex) {
        s->set_error(std::string("model_info: ") + ex.what());
        return -2;
    } catch (...) {
        s->set_error("model_info: unknown error");
        return -2;
    }
}

int orca_session_duplicate_object(orca_session_t *s, int index)
{
    if (!s || !s->has_model || index < 0 || index >= int(s->model.objects.size()))
        return -1;
    try {
        ModelObject *src = s->model.objects[size_t(index)];
        if (!src)
            return -2;
        ModelObject *dup = s->model.add_object(*src);
        if (!dup)
            return -3;
        // Nudge clone so it is visible next to original
        for (ModelInstance *inst : dup->instances) {
            if (!inst) continue;
            inst->set_offset(inst->get_offset() + Vec3d(15.0, 0.0, 0.0));
        }
        dup->invalidate_bounding_box();
        dup->ensure_on_bed();
        return int(s->model.objects.size()) - 1;
    } catch (const std::exception &ex) {
        s->set_error(std::string("duplicate: ") + ex.what());
        return -4;
    } catch (...) {
        s->set_error("duplicate: unknown error");
        return -4;
    }
}

int orca_session_export_object_mesh(
    orca_session_t *s,
    int index,
    float **out_positions,
    size_t *out_vertex_count,
    uint32_t **out_indices,
    size_t *out_index_count)
{
    if (!s || !out_positions || !out_vertex_count || !out_indices || !out_index_count)
        return -1;
    *out_positions = nullptr;
    *out_indices = nullptr;
    *out_vertex_count = 0;
    *out_index_count = 0;
    if (!s->has_model || index < 0 || index >= int(s->model.objects.size())) {
        s->set_error("bad object index");
        return -2;
    }
    try {
        ModelObject *obj = s->model.objects[size_t(index)];
        if (!obj) {
            s->set_error("null object");
            return -3;
        }
        // mesh() includes instance transforms (world / assembly)
        TriangleMesh mesh = obj->mesh();
        const indexed_triangle_set &its = mesh.its;
        if (its.vertices.empty() || its.indices.empty()) {
            s->set_error("object mesh empty");
            return -4;
        }
        const size_t nv = its.vertices.size();
        const size_t nf = its.indices.size();
        auto *pos = static_cast<float *>(std::malloc(nv * 3 * sizeof(float)));
        auto *idx = static_cast<uint32_t *>(std::malloc(nf * 3 * sizeof(uint32_t)));
        if (!pos || !idx) {
            std::free(pos);
            std::free(idx);
            s->set_error("out of memory");
            return -5;
        }
        for (size_t i = 0; i < nv; ++i) {
            pos[i * 3 + 0] = its.vertices[i].x();
            pos[i * 3 + 1] = its.vertices[i].y();
            pos[i * 3 + 2] = its.vertices[i].z();
        }
        for (size_t i = 0; i < nf; ++i) {
            idx[i * 3 + 0] = uint32_t(its.indices[i][0]);
            idx[i * 3 + 1] = uint32_t(its.indices[i][1]);
            idx[i * 3 + 2] = uint32_t(its.indices[i][2]);
        }
        *out_positions = pos;
        *out_vertex_count = nv;
        *out_indices = idx;
        *out_index_count = nf * 3;
        return 0;
    } catch (const std::exception &ex) {
        s->set_error(std::string("export_object_mesh: ") + ex.what());
        return -6;
    } catch (...) {
        s->set_error("export_object_mesh: unknown error");
        return -6;
    }
}

int orca_session_save_3mf(orca_session_t *s, const char *path)
{
    if (!s || !path)
        return -1;
    s->clear_error();
    if (!s->has_model) {
        s->set_error("No model to save");
        return -2;
    }
    try {
        ensure_default_config(s);
        // Official store_3mf(path, model, config, fullpath_sources, thumbnail, zip64)
        bool ok = store_3mf(path, &s->model, &s->config, false, nullptr, true);
        if (!ok) {
            s->set_error("store_3mf failed");
            return -3;
        }
        return 0;
    } catch (const std::exception &ex) {
        s->set_error(std::string("save_3mf: ") + ex.what());
        return -4;
    } catch (...) {
        s->set_error("save_3mf: unknown error");
        return -4;
    }
}

int orca_session_last_slice_stats(
    orca_session_t *s,
    float *time_sec,
    float *filament_mm3,
    int *layers)
{
    if (!s || !s->has_slice_stats)
        return -1;
    if (time_sec) *time_sec = s->last_time_sec;
    if (filament_mm3) *filament_mm3 = s->last_filament_mm3;
    if (layers) *layers = s->last_layers;
    return 0;
}

int orca_session_last_slice_analysis(
    orca_session_t *s,
    float *time_sec,
    float *initial_layer_time_sec,
    float *avg_layer_time_sec,
    float *filament_mm3,
    float *support_mm3,
    float *wipe_tower_mm3,
    int *layers)
{
    if (!s || !s->has_slice_stats)
        return -1;
    if (time_sec) *time_sec = s->last_time_sec;
    if (initial_layer_time_sec) *initial_layer_time_sec = s->last_initial_layer_time_sec;
    if (avg_layer_time_sec) {
        if (s->last_layers > 0)
            *avg_layer_time_sec = s->last_time_sec / float(s->last_layers);
        else
            *avg_layer_time_sec = 0.f;
    }
    if (filament_mm3) *filament_mm3 = s->last_filament_mm3;
    if (support_mm3) *support_mm3 = s->last_support_mm3;
    if (wipe_tower_mm3) *wipe_tower_mm3 = s->last_wipe_tower_mm3;
    if (layers) *layers = s->last_layers;
    return 0;
}

int orca_session_filament_role_count(orca_session_t *s)
{
    if (!s || !s->has_slice_stats)
        return 0;
    return int(s->role_names.size());
}

const char *orca_session_filament_role_name(orca_session_t *s, int index)
{
    if (!s || index < 0 || index >= int(s->role_names.size()))
        return nullptr;
    return s->role_names[size_t(index)].c_str();
}

float orca_session_filament_role_meters(orca_session_t *s, int index)
{
    if (!s || index < 0 || index >= int(s->role_meters.size()))
        return 0.f;
    return s->role_meters[size_t(index)];
}

float orca_session_filament_role_grams(orca_session_t *s, int index)
{
    if (!s || index < 0 || index >= int(s->role_grams.size()))
        return 0.f;
    return s->role_grams[size_t(index)];
}

int orca_session_set_data_dir(orca_session_t *s, const char *data_path)
{
    if (!s || !data_path || !*data_path)
        return -1;
    try {
        s->data_dir_path = data_path;
        set_data_dir(s->data_dir_path);
        return 0;
    } catch (...) {
        s->set_error("set_data_dir failed");
        return -2;
    }
}

int orca_session_load_all_presets(orca_session_t *s)
{
    if (!s)
        return -1;
    s->clear_error();
    try {
        if (s->resources_path.empty()) {
            s->set_error("resources_path empty");
            return -2;
        }
        if (s->data_dir_path.empty()) {
            // Fallback under resources (may be read-only on device — prefer set_data_dir)
            s->data_dir_path = (fs::path(s->resources_path) / "orca_data").string();
        }
        set_resources_dir(s->resources_path);
        set_data_dir(s->data_dir_path);
        set_var_dir(s->resources_path);

        // Collect vendor index names from resources/profiles/*.json
        fs::path prof = fs::path(s->resources_path) / "profiles";
        if (!fs::exists(prof)) {
            s->set_error("profiles/ not found in resources (bundle full profiles)");
            return -3;
        }
        std::vector<std::string> vendors;
        for (fs::directory_iterator it(prof), end; it != end; ++it) {
            if (!fs::is_regular_file(it->path()))
                continue;
            if (it->path().extension() != ".json")
                continue;
            std::string stem = it->path().stem().string();
            if (stem == "blacklist")
                continue;
            vendors.push_back(stem);
        }
        if (vendors.empty()) {
            s->set_error("no vendor json in profiles/");
            return -4;
        }

        s->preset_bundle = std::make_unique<PresetBundle>();
        s->preset_bundle->setup_directories();

        // Install each vendor into data_dir/system (continue on individual failures)
        // Prefer OrcaFilamentLibrary first so inheritance base exists on disk
        std::sort(vendors.begin(), vendors.end(), [](const std::string &a, const std::string &b) {
            if (a == "OrcaFilamentLibrary") return true;
            if (b == "OrcaFilamentLibrary") return false;
            return a < b;
        });
        // Install vendors only if not already present under data_dir/system
        // (avoids re-copy of ~80MB profile tree every launch — peak disk + RAM).
        int installed = 0;
        int skipped = 0;
        fs::path system_root = fs::path(s->data_dir_path) / "system";
        for (const std::string &v : vendors) {
            try {
                fs::path vendor_dir = system_root / v;
                bool already = false;
                if (fs::exists(vendor_dir) && fs::is_directory(vendor_dir)) {
                    // Treat as installed if vendor index or any child exists
                    already = fs::exists(vendor_dir / (v + ".json"))
                        || !fs::is_empty(vendor_dir);
                }
                if (already) {
                    ++skipped;
                    ++installed; // count as available for load_presets
                    continue;
                }
                if (install_vendor_bundles_from_resources({v}))
                    ++installed;
            } catch (...) {
                // keep going
            }
        }
        if (installed == 0) {
            s->set_error("install_vendor_bundles_from_resources failed for all vendors");
            return -5;
        }
        (void) skipped;

        // Public path: load_presets → private load_system_presets_from_json
        AppConfig app_config;
        try {
            s->preset_bundle->load_presets(
                app_config, ForwardCompatibilitySubstitutionRule::EnableSilent);
        } catch (const std::exception &ex) {
            s->set_error(std::string("load_presets: ") + ex.what());
            return -6;
        }

        // Make all system presets visible for mobile catalog
        for (Preset &p : s->preset_bundle->printers)
            p.is_visible = true;
        for (Preset &p : s->preset_bundle->prints)
            p.is_visible = true;
        for (Preset &p : s->preset_bundle->filaments)
            p.is_visible = true;

        s->preset_bundle->update_compatible(PresetSelectCompatibleType::Never);
        s->scan_user_process_presets();
        s->scan_user_filament_presets();
        s->refresh_name_caches();
        s->presets_loaded = !s->printer_names.empty();
        if (!s->presets_loaded) {
            s->set_error(std::string("no printers after load; installed=") + std::to_string(installed));
            return -7;
        }
        return 0;
    } catch (const std::exception &ex) {
        s->set_error(std::string("load_all_presets: ") + ex.what());
        return -7;
    } catch (...) {
        s->set_error("load_all_presets: unknown error");
        return -7;
    }
}

int orca_session_printer_count(orca_session_t *s)
{
    return s ? int(s->printer_names.size()) : 0;
}
const char *orca_session_printer_name(orca_session_t *s, int index)
{
    if (!s || index < 0 || index >= int(s->printer_names.size()))
        return nullptr;
    return s->printer_names[size_t(index)].c_str();
}
const char *orca_session_printer_vendor(orca_session_t *s, int index)
{
    if (!s || index < 0 || index >= int(s->printer_vendors.size()))
        return nullptr;
    return s->printer_vendors[size_t(index)].c_str();
}

int orca_session_process_count(orca_session_t *s)
{
    return s ? int(s->process_names.size()) : 0;
}
const char *orca_session_process_name(orca_session_t *s, int index)
{
    if (!s || index < 0 || index >= int(s->process_names.size()))
        return nullptr;
    return s->process_names[size_t(index)].c_str();
}

int orca_session_filament_count(orca_session_t *s)
{
    return s ? int(s->filament_names.size()) : 0;
}
const char *orca_session_filament_name(orca_session_t *s, int index)
{
    if (!s || index < 0 || index >= int(s->filament_names.size()))
        return nullptr;
    return s->filament_names[size_t(index)].c_str();
}

int orca_session_select_printer(orca_session_t *s, const char *name)
{
    if (!s || !name || !s->preset_bundle)
        return -1;
    try {
        if (!s->preset_bundle->printers.select_preset_by_name(name, true)) {
            s->set_error(std::string("printer not found: ") + name);
            return -2;
        }
        s->preset_bundle->update_compatible(PresetSelectCompatibleType::Always);
        // Prefer printer's default process/filament when present
        {
            const Preset &pr = s->preset_bundle->printers.get_selected_preset();
            std::string def_print = pr.config.opt_string("default_print_profile");
            std::string def_fil;
            if (const ConfigOptionStrings *dfs = pr.config.option<ConfigOptionStrings>("default_filament_profile")) {
                if (!dfs->values.empty())
                    def_fil = dfs->values.front();
            } else {
                def_fil = pr.config.opt_string("default_filament_profile");
            }
            if (!def_print.empty())
                s->preset_bundle->prints.select_preset_by_name(def_print, true);
            else
                s->preset_bundle->prints.select_preset(s->preset_bundle->prints.first_compatible_idx());
            // Re-filter filaments against newly selected process
            s->preset_bundle->update_compatible(PresetSelectCompatibleType::Always);
            if (!def_fil.empty()) {
                s->preset_bundle->filaments.select_preset_by_name(def_fil, true);
                s->preset_bundle->set_filament_preset(0, def_fil);
            } else {
                s->preset_bundle->filaments.select_preset(s->preset_bundle->filaments.first_compatible_idx());
                s->preset_bundle->set_filament_preset(
                    0, s->preset_bundle->filaments.get_selected_preset_name());
            }
        }
        // Rebuild process/filament name lists to compatible-only
        s->refresh_name_caches();
        return 0;
    } catch (const std::exception &ex) {
        s->set_error(std::string("select_printer: ") + ex.what());
        return -3;
    }
}

int orca_session_select_process(orca_session_t *s, const char *name)
{
    if (!s || !name || !s->preset_bundle)
        return -1;
    try {
        // User-saved process JSON (not in system PresetBundle)
        fs::path user_json = s->user_process_dir() / (std::string(name) + ".json");
        if (fs::exists(user_json)) {
            ensure_default_config(s);
            std::map<std::string, std::string> key_values;
            std::string reason;
            ConfigSubstitutionContext ctx(ForwardCompatibilitySubstitutionRule::Enable);
            int rc = s->config.load_from_json(user_json.string(), ctx, true, key_values, reason);
            if (rc != 0) {
                s->set_error(reason.empty() ? "load user process failed" : reason);
                return -4;
            }
            s->has_config = true;
            s->selected_process_cache = name;
            s->active_process_from_user = true;
            return 0;
        }
        s->active_process_from_user = false;
        if (!s->preset_bundle->prints.select_preset_by_name(name, true)) {
            s->set_error(std::string("process not found: ") + name);
            return -2;
        }
        // Filament compatibility can depend on selected process
        s->preset_bundle->update_compatible(PresetSelectCompatibleType::Always);
        s->refresh_name_caches();
        return 0;
    } catch (const std::exception &ex) {
        s->set_error(std::string("select_process: ") + ex.what());
        return -3;
    }
}

int orca_session_select_filament(orca_session_t *s, const char *name)
{
    if (!s || !name || !s->preset_bundle)
        return -1;
    try {
        // User-saved filament JSON
        fs::path user_json = s->user_filament_dir() / (std::string(name) + ".json");
        if (fs::exists(user_json)) {
            ensure_default_config(s);
            std::map<std::string, std::string> key_values;
            std::string reason;
            ConfigSubstitutionContext ctx(ForwardCompatibilitySubstitutionRule::Enable);
            int rc = s->config.load_from_json(user_json.string(), ctx, true, key_values, reason);
            if (rc != 0) {
                s->set_error(reason.empty() ? "load user filament failed" : reason);
                return -4;
            }
            s->has_config = true;
            s->selected_filament_cache = name;
            s->active_filament_from_user = true;
            return 0;
        }
        s->active_filament_from_user = false;
        if (!s->preset_bundle->filaments.select_preset_by_name(name, true)) {
            s->set_error(std::string("filament not found: ") + name);
            return -2;
        }
        s->preset_bundle->set_filament_preset(0, name);
        s->sync_selected_caches();
        return 0;
    } catch (const std::exception &ex) {
        s->set_error(std::string("select_filament: ") + ex.what());
        return -3;
    }
}

int orca_session_apply_presets(orca_session_t *s)
{
    if (!s || !s->preset_bundle)
        return -1;
    try {
        // Keep user process / filament JSON overlays if currently active
        DynamicPrintConfig user_process_overlay;
        DynamicPrintConfig user_filament_overlay;
        const bool had_user_proc = s->active_process_from_user;
        const bool had_user_fil = s->active_filament_from_user;
        const std::string user_proc_name = s->selected_process_cache;
        const std::string user_fil_name = s->selected_filament_cache;
        if (had_user_proc || had_user_fil) {
            // Snapshot full session config; overlays re-applied after full_config
            if (had_user_proc)
                user_process_overlay = s->config;
            if (had_user_fil)
                user_filament_overlay = s->config;
        }

        s->config = s->preset_bundle->full_config(true);
        if (had_user_proc)
            s->config.apply(user_process_overlay);
        if (had_user_fil)
            s->config.apply(user_filament_overlay);
        s->has_config = true;
        s->sync_selected_caches();
        if (had_user_proc && !user_proc_name.empty())
            s->selected_process_cache = user_proc_name;
        if (had_user_fil && !user_fil_name.empty())
            s->selected_filament_cache = user_fil_name;
        return 0;
    } catch (const std::exception &ex) {
        s->set_error(std::string("apply_presets: ") + ex.what());
        return -2;
    }
}

void orca_session_set_compatible_only(orca_session_t *s, int enabled)
{
    if (!s)
        return;
    s->filter_compatible_only = enabled != 0;
    try {
        if (s->preset_bundle) {
            if (s->filter_compatible_only)
                s->preset_bundle->update_compatible(PresetSelectCompatibleType::Never);
            s->refresh_name_caches();
        }
    } catch (...) {
    }
}

int orca_session_get_compatible_only(orca_session_t *s)
{
    return (s && s->filter_compatible_only) ? 1 : 0;
}

int orca_session_save_user_process(orca_session_t *s, const char *name)
{
    if (!s || !name || !*name)
        return -1;
    s->clear_error();
    try {
        ensure_default_config(s);
        fs::path dir = s->user_process_dir();
        fs::create_directories(dir);
        std::string safe = orca_session::sanitize_preset_name(name);
        if (safe.empty()) {
            s->set_error("invalid preset name");
            return -2;
        }
        fs::path path = dir / (safe + ".json");
        // Official DynamicPrintConfig::save_to_json
        s->config.save_to_json(path.string(), safe, "User", SoftFever_VERSION);
        s->scan_user_process_presets();
        s->refresh_name_caches();
        s->selected_process_cache = safe;
        s->active_process_from_user = true;
        return 0;
    } catch (const std::exception &ex) {
        s->set_error(std::string("save_user_process: ") + ex.what());
        return -3;
    } catch (...) {
        s->set_error("save_user_process: unknown error");
        return -3;
    }
}

int orca_session_user_process_count(orca_session_t *s)
{
    if (!s)
        return 0;
    return (int)s->user_process_names.size();
}

const char *orca_session_user_process_name(orca_session_t *s, int index)
{
    if (!s || index < 0 || index >= (int)s->user_process_names.size())
        return nullptr;
    return s->user_process_names[(size_t)index].c_str();
}

int orca_session_save_user_filament(orca_session_t *s, const char *name)
{
    if (!s || !name || !*name)
        return -1;
    s->clear_error();
    try {
        ensure_default_config(s);
        fs::path dir = s->user_filament_dir();
        fs::create_directories(dir);
        std::string safe = orca_session::sanitize_preset_name(name);
        if (safe.empty()) {
            s->set_error("invalid filament name");
            return -2;
        }
        fs::path path = dir / (safe + ".json");
        s->config.save_to_json(path.string(), safe, "User", SoftFever_VERSION);
        s->scan_user_filament_presets();
        s->refresh_name_caches();
        s->selected_filament_cache = safe;
        s->active_filament_from_user = true;
        return 0;
    } catch (const std::exception &ex) {
        s->set_error(std::string("save_user_filament: ") + ex.what());
        return -3;
    } catch (...) {
        s->set_error("save_user_filament: unknown error");
        return -3;
    }
}

int orca_session_user_filament_count(orca_session_t *s)
{
    if (!s)
        return 0;
    return (int)s->user_filament_names.size();
}

const char *orca_session_user_filament_name(orca_session_t *s, int index)
{
    if (!s || index < 0 || index >= (int)s->user_filament_names.size())
        return nullptr;
    return s->user_filament_names[(size_t)index].c_str();
}

int orca_session_export_config(orca_session_t *s, const char *path)
{
    if (!s || !path || !*path)
        return -1;
    s->clear_error();
    try {
        ensure_default_config(s);
        std::string name = s->selected_process_cache.empty() ? "OrcaConfig" : s->selected_process_cache;
        s->config.save_to_json(std::string(path), name, "User", SoftFever_VERSION);
        return 0;
    } catch (const std::exception &ex) {
        s->set_error(std::string("export_config: ") + ex.what());
        return -2;
    } catch (...) {
        s->set_error("export_config: unknown error");
        return -2;
    }
}

int orca_session_import_config(orca_session_t *s, const char *path)
{
    if (!s || !path || !*path)
        return -1;
    s->clear_error();
    try {
        ensure_default_config(s);
        std::map<std::string, std::string> key_values;
        std::string reason;
        ConfigSubstitutionContext ctx(ForwardCompatibilitySubstitutionRule::Enable);
        int rc = s->config.load_from_json(std::string(path), ctx, true, key_values, reason);
        if (rc != 0) {
            s->set_error(reason.empty() ? "import_config failed" : reason);
            return -2;
        }
        s->has_config = true;
        return 0;
    } catch (const std::exception &ex) {
        s->set_error(std::string("import_config: ") + ex.what());
        return -3;
    } catch (...) {
        s->set_error("import_config: unknown error");
        return -3;
    }
}

int orca_session_import_user_preset(orca_session_t *s, const char *path, int kind)
{
    if (!s || !path || !*path)
        return -1;
    if (kind != 0 && kind != 1) {
        s->set_error("import_user_preset kind must be 0=process or 1=filament");
        return -2;
    }
    s->clear_error();
    try {
        fs::path src(path);
        if (!fs::exists(src) || !fs::is_regular_file(src)) {
            s->set_error("preset file not found");
            return -3;
        }
        std::string stem = src.stem().string();
        std::string safe = orca_session::sanitize_preset_name(stem.c_str());
        if (safe.empty())
            safe = kind == 0 ? "Imported Process" : "Imported Filament";
        fs::path dest_dir = kind == 0 ? s->user_process_dir() : s->user_filament_dir();
        fs::create_directories(dest_dir);
        fs::path dest = dest_dir / (safe + ".json");
        // Load via official API then re-save into user_presets catalog
        ensure_default_config(s);
        std::map<std::string, std::string> key_values;
        std::string reason;
        ConfigSubstitutionContext ctx(ForwardCompatibilitySubstitutionRule::Enable);
        int rc = s->config.load_from_json(src.string(), ctx, true, key_values, reason);
        if (rc != 0) {
            s->set_error(reason.empty() ? "import preset load failed" : reason);
            return -5;
        }
        s->has_config = true;
        s->config.save_to_json(dest.string(), safe, "User", SoftFever_VERSION);
        if (kind == 0) {
            s->scan_user_process_presets();
            s->refresh_name_caches();
            s->selected_process_cache = safe;
            s->active_process_from_user = true;
            return 0;
        } else {
            s->scan_user_filament_presets();
            s->refresh_name_caches();
            s->selected_filament_cache = safe;
            s->active_filament_from_user = true;
            return 0;
        }
    } catch (const std::exception &ex) {
        s->set_error(std::string("import_user_preset: ") + ex.what());
        return -4;
    } catch (...) {
        s->set_error("import_user_preset: unknown error");
        return -4;
    }
}

int orca_session_clone_grid(orca_session_t *s, int index, int nx, int ny, float spacing_mm)
{
    if (!s || !s->has_model || index < 0 || index >= int(s->model.objects.size()))
        return -1;
    if (nx < 1 || ny < 1 || nx > 20 || ny > 20) {
        s->set_error("clone_grid: nx/ny must be 1..20");
        return -2;
    }
    s->clear_error();
    try {
        ModelObject *src = s->model.objects[size_t(index)];
        if (!src)
            return -3;
        const float spacing = spacing_mm > 0.f ? spacing_mm : 15.f;
        // Keep original at (0,0) relative offsets; add (nx*ny - 1) clones
        for (int iy = 0; iy < ny; ++iy) {
            for (int ix = 0; ix < nx; ++ix) {
                if (ix == 0 && iy == 0)
                    continue;
                ModelObject *dup = s->model.add_object(*src);
                if (!dup)
                    continue;
                const Vec3d delta(double(ix) * spacing, double(iy) * spacing, 0.0);
                for (ModelInstance *inst : dup->instances) {
                    if (!inst) continue;
                    inst->set_offset(inst->get_offset() + delta);
                }
                dup->name = src->name + " [" + std::to_string(ix) + "," + std::to_string(iy) + "]";
                dup->invalidate_bounding_box();
                dup->ensure_on_bed();
            }
        }
        // Nest onto bed if many clones (reuse official arrange path)
        try {
            Points bedpts = get_bed_shape(s->config);
            if (bedpts.size() >= 3) {
                BoundingBox bedbb = get_extents(bedpts);
                arrangement::ArrangeParams params;
                params.min_obj_distance = scaled(6.);
                params.accuracy = 0.65f;
                params.parallel = true;
                auto vfn = [](arrangement::ArrangePolygon &ap) {
                    if (ap.bed_idx == arrangement::UNARRANGED)
                        ap.bed_idx = 0;
                };
                arrange_objects(s->model, bedbb, params, vfn);
                for (ModelObject *obj : s->model.objects) {
                    if (!obj) continue;
                    obj->invalidate_bounding_box();
                    obj->ensure_on_bed();
                }
            }
        } catch (...) {
            // arrange optional — grid offsets still valid
        }
        // Object graph changed — invalidate explode baseline
        s->has_explode_baseline = false;
        s->explode_baseline_offsets.clear();
        s->explode_factor_current = 0.f;
        return int(s->model.objects.size());
    } catch (const std::exception &ex) {
        s->set_error(std::string("clone_grid: ") + ex.what());
        return -4;
    } catch (...) {
        s->set_error("clone_grid: unknown error");
        return -4;
    }
}

// ---------------------------------------------------------------------------
// W2: Assembly explode / collapse + emboss-lite text plate (box)
// ---------------------------------------------------------------------------

static void bed_center_xy(orca_session_t *s, double &bed_cx, double &bed_cy)
{
    bed_cx = 110.0;
    bed_cy = 110.0;
    if (!s) return;
    if (const ConfigOptionPoints *pa = s->config.option<ConfigOptionPoints>("printable_area")) {
        if (!pa->values.empty()) {
            BoundingBoxf bedbb;
            for (const Vec2d &p : pa->values)
                bedbb.merge(Vec2d(p.x(), p.y()));
            bed_cx = (bedbb.min.x() + bedbb.max.x()) * 0.5;
            bed_cy = (bedbb.min.y() + bedbb.max.y()) * 0.5;
        }
    }
}

static void save_explode_baseline(orca_session_t *s)
{
    s->explode_baseline_offsets.clear();
    s->explode_baseline_offsets.reserve(s->model.objects.size());
    for (ModelObject *obj : s->model.objects) {
        std::vector<Vec3d> inst_offs;
        if (obj) {
            inst_offs.reserve(obj->instances.size());
            for (ModelInstance *inst : obj->instances) {
                if (inst)
                    inst_offs.push_back(inst->get_offset());
                else
                    inst_offs.push_back(Vec3d::Zero());
            }
        }
        s->explode_baseline_offsets.push_back(std::move(inst_offs));
    }
    s->has_explode_baseline = true;
}

static void restore_explode_baseline(orca_session_t *s)
{
    if (!s->has_explode_baseline)
        return;
    const size_t n = std::min(s->model.objects.size(), s->explode_baseline_offsets.size());
    for (size_t oi = 0; oi < n; ++oi) {
        ModelObject *obj = s->model.objects[oi];
        if (!obj) continue;
        const auto &offs = s->explode_baseline_offsets[oi];
        const size_t ni = std::min(obj->instances.size(), offs.size());
        for (size_t ii = 0; ii < ni; ++ii) {
            if (ModelInstance *inst = obj->instances[ii])
                inst->set_offset(offs[ii]);
        }
        obj->invalidate_bounding_box();
        obj->ensure_on_bed();
    }
    s->explode_factor_current = 0.f;
}

int orca_session_explode_objects(orca_session_t *s, float factor, float spacing_mm)
{
    if (!s || !s->has_model || s->model.objects.empty())
        return -1;
    s->clear_error();
    try {
        ensure_default_config(s);
        const float spacing = spacing_mm > 0.f ? spacing_mm : 20.f;
        const float f = factor;

        // Collapse → restore baseline offsets
        if (f <= 0.001f) {
            if (s->has_explode_baseline)
                restore_explode_baseline(s);
            return 0;
        }

        // Save baseline on first explode (or when object count changed)
        if (!s->has_explode_baseline
            || s->explode_baseline_offsets.size() != s->model.objects.size()) {
            // If re-exploding after partial edits with mismatched baseline, use current as new base
            save_explode_baseline(s);
        } else if (s->explode_factor_current > 0.001f) {
            // Already exploded — restore first so we re-apply from original layout
            restore_explode_baseline(s);
            // restore clears factor; re-mark baseline still valid
            s->has_explode_baseline = true;
        }

        double bed_cx = 110.0, bed_cy = 110.0;
        bed_center_xy(s, bed_cx, bed_cy);

        const size_t n = s->model.objects.size();
        if (n == 0)
            return 0;

        for (size_t i = 0; i < n; ++i) {
            ModelObject *obj = s->model.objects[i];
            if (!obj || obj->instances.empty())
                continue;

            // Radial offset: factor * index * spacing around bed center
            const double radius = double(f) * double(i) * double(spacing);
            const double angle = (n > 1)
                ? (2.0 * M_PI * double(i) / double(n))
                : 0.0;
            const double tx = bed_cx + radius * std::cos(angle);
            const double ty = bed_cy + radius * std::sin(angle);

            // Move first instance so object AABB center XY lands on (tx, ty)
            ModelInstance *inst0 = obj->instances[0];
            if (!inst0) continue;
            obj->invalidate_bounding_box();
            BoundingBoxf3 bb = obj->instance_bounding_box(0, /*dont_translate=*/false);
            const Vec3d cur_c = bb.center();
            const Vec3d delta(tx - cur_c.x(), ty - cur_c.y(), 0.0);
            for (ModelInstance *inst : obj->instances) {
                if (!inst) continue;
                inst->set_offset(inst->get_offset() + delta);
            }
            obj->invalidate_bounding_box();
            obj->ensure_on_bed();
        }
        s->explode_factor_current = f;
        return 0;
    } catch (const std::exception &ex) {
        s->set_error(std::string("explode_objects: ") + ex.what());
        return -2;
    } catch (...) {
        s->set_error("explode_objects: unknown error");
        return -2;
    }
}

int orca_session_add_box(
    orca_session_t *s, const char *name,
    float size_x, float size_y, float size_z)
{
    if (!s)
        return -1;
    s->clear_error();
    try {
        ensure_default_config(s);
        const double sx = std::max(0.5, double(size_x > 0.f ? size_x : 40.f));
        const double sy = std::max(0.5, double(size_y > 0.f ? size_y : 10.f));
        const double sz = std::max(0.5, double(size_z > 0.f ? size_z : 2.f));
        TriangleMesh mesh = make_cube(sx, sy, sz);
        // Center cube on origin in XY, bottom on Z=0
        mesh.translate(float(-sx * 0.5), float(-sy * 0.5), 0.f);

        const char *obj_name = (name && name[0]) ? name : "Text plate";
        ModelObject *obj = s->model.add_object(obj_name, "", std::move(mesh));
        if (!obj) {
            s->set_error("add_box: failed to create object");
            return -2;
        }
        if (obj->instances.empty())
            obj->add_instance();
        // Place near bed center
        double bed_cx = 110.0, bed_cy = 110.0;
        bed_center_xy(s, bed_cx, bed_cy);
        for (ModelInstance *inst : obj->instances) {
            if (!inst) continue;
            inst->set_offset(Vec3d(bed_cx, bed_cy, 0.0));
        }
        obj->invalidate_bounding_box();
        obj->ensure_on_bed();
        s->has_model = true;
        s->has_explode_baseline = false;
        s->explode_baseline_offsets.clear();
        s->explode_factor_current = 0.f;
        return int(s->model.objects.size()) - 1;
    } catch (const std::exception &ex) {
        s->set_error(std::string("add_box: ") + ex.what());
        return -3;
    } catch (...) {
        s->set_error("add_box: unknown error");
        return -3;
    }
}

int orca_session_mesh_stats(
    orca_session_t *s, int index,
    int *facets, int *open_edges, int *parts, float *volume_mm3)
{
    if (!s || !s->has_model)
        return -1;
    s->clear_error();
    try {
        TriangleMeshStats st;
        if (index < 0) {
            for (ModelObject *obj : s->model.objects) {
                if (!obj) continue;
                st = st.merge(obj->get_object_stl_stats());
            }
        } else {
            if (index >= int(s->model.objects.size()))
                return -2;
            ModelObject *obj = s->model.objects[size_t(index)];
            if (!obj)
                return -2;
            st = obj->get_object_stl_stats();
        }
        if (facets) *facets = int(st.number_of_facets);
        if (open_edges) *open_edges = st.open_edges;
        if (parts) *parts = st.number_of_parts;
        if (volume_mm3) *volume_mm3 = st.volume;
        return 0;
    } catch (const std::exception &ex) {
        s->set_error(std::string("mesh_stats: ") + ex.what());
        return -3;
    } catch (...) {
        s->set_error("mesh_stats: unknown error");
        return -3;
    }
}

int orca_session_repair_mesh(orca_session_t *s, int index)
{
    if (!s || !s->has_model)
        return -1;
    s->clear_error();
    try {
        std::vector<int> indices;
        if (index < 0) {
            for (int i = 0; i < int(s->model.objects.size()); ++i)
                indices.push_back(i);
        } else {
            if (index >= int(s->model.objects.size()))
                return -2;
            indices.push_back(index);
        }
        int repaired_vols = 0;
        std::string last_err;
        for (int oi : indices) {
            ModelObject *obj = s->model.objects[size_t(oi)];
            if (!obj) continue;
            for (ModelVolume *vol : obj->volumes) {
                if (!vol || !vol->is_model_part())
                    continue;
                TriangleMesh mesh = vol->mesh();
                RepairedMeshErrors errs;
                std::string err;
                if (MeshBoolean::cgal::repair(mesh, &errs, &err)) {
                    vol->set_mesh(std::move(mesh));
                    vol->calculate_convex_hull();
                    vol->invalidate_convex_hull_2d();
                    ++repaired_vols;
                } else if (!err.empty()) {
                    last_err = err;
                }
            }
            obj->invalidate_bounding_box();
            obj->ensure_on_bed();
        }
        if (repaired_vols == 0 && !last_err.empty()) {
            s->set_error(std::string("repair: ") + last_err);
            return -3;
        }
        // Success even if already manifold (0 vols changed)
        return 0;
    } catch (const std::exception &ex) {
        s->set_error(std::string("repair_mesh: ") + ex.what());
        return -4;
    } catch (...) {
        s->set_error("repair_mesh: unknown error");
        return -4;
    }
}

int orca_session_cut_object_z(
    orca_session_t *s, int index, float z_mm, int keep_upper, int keep_lower)
{
    if (!s || !s->has_model || index < 0 || index >= int(s->model.objects.size()))
        return -1;
    if (!keep_upper && !keep_lower) {
        s->set_error("cut: keep_upper and/or keep_lower required");
        return -2;
    }
    s->clear_error();
    try {
        ModelObject *object = s->model.objects[size_t(index)];
        if (!object || object->instances.empty()) {
            s->set_error("cut: invalid object");
            return -3;
        }
        const size_t instance_idx = 0;
        const Vec3d instance_offset = object->instances[instance_idx]->get_offset();
        ModelObjectCutAttributes attrs =
            (keep_upper ? ModelObjectCutAttribute::KeepUpper : ModelObjectCutAttributes{}) |
            (keep_lower ? ModelObjectCutAttribute::KeepLower : ModelObjectCutAttributes{});
        // Official Cut plane (same as calib cut_model helper)
        Cut cut(object, int(instance_idx),
                Geometry::translation_transform(double(z_mm) * Vec3d::UnitZ() - instance_offset),
                attrs);
        const ModelObjectPtrs new_objects = cut.perform_with_plane();
        s->model.delete_object(size_t(index));
        for (ModelObject *mo : new_objects) {
            if (!mo) continue;
            ModelObject *added = s->model.add_object(*mo);
            if (added) {
                added->sort_volumes(true);
                added->ensure_on_bed();
            }
        }
        s->has_model = !s->model.objects.empty();
        return int(s->model.objects.size());
    } catch (const std::exception &ex) {
        s->set_error(std::string("cut_object_z: ") + ex.what());
        return -4;
    } catch (...) {
        s->set_error("cut_object_z: unknown error");
        return -4;
    }
}

static int copy_path_to_buf(orca_session_t *s, const std::string &path, char *buf, size_t buf_len)
{
    if (path.empty())
        return -3;
    if (path.size() >= buf_len) {
        s->set_error("buffer too small for path");
        return -4;
    }
    std::memcpy(buf, path.c_str(), path.size() + 1);
    return 0;
}

int orca_session_printer_cover_path(orca_session_t *s, char *buf, size_t buf_len)
{
    if (!s || !buf || buf_len == 0 || !s->preset_bundle)
        return -1;
    buf[0] = '\0';
    try {
        const Preset &pr = s->preset_bundle->printers.get_selected_preset();
        std::string model = pr.config.opt_string("printer_model");
        std::string vendor;
        if (pr.vendor)
            vendor = pr.vendor->id.empty() ? pr.vendor->name : pr.vendor->id;
        if (model.empty())
            return -2;
        // Prefer official cover naming, then bed texture, then vendor name variants
        s->cover_path_cache.clear();
        if (!vendor.empty() && s->resolve_profile_image(vendor, model, "_cover.png", s->cover_path_cache))
            return copy_path_to_buf(s, s->cover_path_cache, buf, buf_len);
        // Vendor folder may use name instead of id
        if (pr.vendor && !pr.vendor->name.empty() && pr.vendor->name != vendor) {
            if (s->resolve_profile_image(pr.vendor->name, model, "_cover.png", s->cover_path_cache))
                return copy_path_to_buf(s, s->cover_path_cache, buf, buf_len);
        }
        // Fallback: official bed texture (often the plate logo)
        std::string tex = s->preset_bundle->get_texture_for_printer_model(model);
        if (!tex.empty() && fs::exists(tex)) {
            s->cover_path_cache = tex;
            return copy_path_to_buf(s, s->cover_path_cache, buf, buf_len);
        }
        return -3;
    } catch (...) {
        return -5;
    }
}

int orca_session_printer_bed_texture_path(orca_session_t *s, char *buf, size_t buf_len)
{
    if (!s || !buf || buf_len == 0 || !s->preset_bundle)
        return -1;
    buf[0] = '\0';
    try {
        const Preset &pr = s->preset_bundle->printers.get_selected_preset();
        std::string model = pr.config.opt_string("printer_model");
        if (model.empty())
            return -2;
        std::string tex = s->preset_bundle->get_texture_for_printer_model(model);
        if (tex.empty() || !fs::exists(tex)) {
            // Fall back to cover art as plate graphic
            char tmp[1024];
            if (orca_session_printer_cover_path(s, tmp, sizeof(tmp)) != 0)
                return -3;
            s->bed_texture_cache = tmp;
            return copy_path_to_buf(s, s->bed_texture_cache, buf, buf_len);
        }
        s->bed_texture_cache = tex;
        return copy_path_to_buf(s, s->bed_texture_cache, buf, buf_len);
    } catch (...) {
        return -5;
    }
}

const char *orca_session_selected_printer(orca_session_t *s)
{
    return s ? s->selected_printer_cache.c_str() : "";
}
const char *orca_session_selected_process(orca_session_t *s)
{
    return s ? s->selected_process_cache.c_str() : "";
}
const char *orca_session_selected_filament(orca_session_t *s)
{
    return s ? s->selected_filament_cache.c_str() : "";
}

int orca_session_presets_loaded(orca_session_t *s)
{
    return (s && s->presets_loaded) ? 1 : 0;
}

int orca_session_preset_stats(
    orca_session_t *s, int *printers, int *process, int *filament)
{
    if (!s)
        return -1;
    if (printers) *printers = int(s->printer_names.size());
    if (process) *process = int(s->process_names.size());
    if (filament) *filament = int(s->filament_names.size());
    return 0;
}

void orca_session_purge_option_caches(orca_session_t *s)
{
    if (!s)
        return;
    s->option_keys_cache.clear();
    s->option_keys_cache.shrink_to_fit();
    s->enum_values_cache.clear();
    s->enum_values_cache.shrink_to_fit();
    s->enum_labels_cache.clear();
    s->enum_labels_cache.shrink_to_fit();
    s->enum_lookup_key.clear();
}

int orca_session_set_calib(
    orca_session_t *s, int mode, double start, double end, double step)
{
    if (!s)
        return -1;
    s->clear_error();
    // Clamp to known CalibMode range (None … Cornering)
    if (mode < 0 || mode > static_cast<int>(CalibMode::Calib_Cornering)) {
        s->set_error("invalid calib mode");
        return -2;
    }
    s->calib_params = Calib_Params();
    s->calib_params.mode = static_cast<CalibMode>(mode);
    s->calib_params.start = start;
    s->calib_params.end = end;
    s->calib_params.step = step;
    // Temp tower / VFA: default nozzle-based resize on (matches desktop)
    s->calib_params.nozzle_based_resize = true;
    return 0;
}

int orca_session_clear_calib(orca_session_t *s)
{
    if (!s)
        return -1;
    s->calib_params = Calib_Params();
    s->calib_params.mode = CalibMode::Calib_None;
    return 0;
}

int orca_session_get_calib_mode(orca_session_t *s)
{
    if (!s)
        return 0;
    return static_cast<int>(s->calib_params.mode);
}

int orca_session_set_object_option(
    orca_session_t *s, int index, const char *key, const char *value)
{
    if (!s || !s->has_model || !key || !value || index < 0
        || index >= int(s->model.objects.size()))
        return -1;
    try {
        ModelObject *obj = s->model.objects[size_t(index)];
        if (!obj)
            return -2;
        ConfigSubstitutionContext ctx(ForwardCompatibilitySubstitutionRule::EnableSilent);
        obj->config.set_deserialize(key, value, ctx);
        return 0;
    } catch (const std::exception &ex) {
        s->set_error(std::string("set_object_option: ") + ex.what());
        return -3;
    }
}

int orca_session_get_object_option(
    orca_session_t *s, int index, const char *key, char *buf, size_t buf_len)
{
    if (!s || !buf || buf_len == 0 || !key || index < 0
        || index >= int(s->model.objects.size()))
        return -1;
    buf[0] = '\0';
    try {
        ModelObject *obj = s->model.objects[size_t(index)];
        if (!obj || !obj->config.has(key))
            return -2; // not overridden
        std::string val = obj->config.opt_serialize(key);
        if (val.size() >= buf_len) {
            s->set_error("buffer too small");
            return -3;
        }
        std::memcpy(buf, val.c_str(), val.size() + 1);
        return 0;
    } catch (const std::exception &ex) {
        s->set_error(std::string("get_object_option: ") + ex.what());
        return -4;
    }
}

int orca_session_erase_object_option(
    orca_session_t *s, int index, const char *key)
{
    if (!s || !s->has_model || !key || index < 0
        || index >= int(s->model.objects.size()))
        return -1;
    try {
        ModelObject *obj = s->model.objects[size_t(index)];
        if (!obj)
            return -2;
        obj->config.erase(key);
        return 0;
    } catch (const std::exception &ex) {
        s->set_error(std::string("erase_object_option: ") + ex.what());
        return -3;
    }
}

int orca_session_set_object_extruder(
    orca_session_t *s, int index, int extruder_1based)
{
    char buf[32];
    std::snprintf(buf, sizeof(buf), "%d", extruder_1based);
    return orca_session_set_object_option(s, index, "extruder", buf);
}

int orca_session_snapshot(orca_session_t *s, const char *path)
{
    return orca_session_save_3mf(s, path);
}

int orca_session_restore_snapshot(orca_session_t *s, const char *path)
{
    if (!s || !path)
        return -1;
    // Preserve bed size across restore when possible
    float bw = 220, bd = 220, bh = 250;
    orca_session_bed_size(s, &bw, &bd, &bh);
    int rc = orca_session_load_model(s, path); // 3MF load applies embedded config
    if (rc != 0)
        return rc;
    // Re-assert bed if stripped
    float w2 = 0, d2 = 0, h2 = 0;
    if (orca_session_bed_size(s, &w2, &d2, &h2) != 0 || w2 < 1.f)
        orca_session_set_printable_area(s, bw, bd, bh);
    return 0;
}

} // extern "C"

// -----------------------------------------------------------------------------
// Facet painting (support / seam / MMU / fuzzy) via ModelVolume FacetsAnnotation
// Helpers are C++-only (not extern "C") because they return Eigen types.
// -----------------------------------------------------------------------------

namespace {

FacetsAnnotation *paint_annotation_for(ModelVolume *vol, int paint_kind)
{
    if (!vol)
        return nullptr;
    switch (paint_kind) {
    case 0: return &vol->supported_facets;
    case 1: return &vol->seam_facets;
    case 2: return &vol->mmu_segmentation_facets;
    case 3: return &vol->fuzzy_skin_facets;
    default: return nullptr;
    }
}

bool paint_state_valid(int paint_kind, int state)
{
    if (state < 0)
        return false;
    if (paint_kind == 0 || paint_kind == 1)
        return state <= 2; // NONE / ENFORCER / BLOCKER
    if (paint_kind == 2)
        return state <= int(EnforcerBlockerType::ExtruderMax);
    if (paint_kind == 3)
        return state <= 1; // NONE / FUZZY_SKIN(=ENFORCER)
    return false;
}

Transform3d volume_world_matrix(const ModelObject *obj, const ModelVolume *vol)
{
    Transform3d inst = Transform3d::Identity();
    if (obj && !obj->instances.empty() && obj->instances[0])
        inst = obj->instances[0]->get_transformation().get_matrix();
    return inst * vol->get_matrix();
}

int paint_volume_near_point(
    ModelVolume *vol,
    const Transform3d &world_matrix,
    const Vec3f &hit_world,
    float radius_mm,
    int paint_kind,
    EnforcerBlockerType ebt)
{
    FacetsAnnotation *ann = paint_annotation_for(vol, paint_kind);
    if (!ann)
        return 0;
    const indexed_triangle_set &its = vol->mesh().its;
    if (its.indices.empty())
        return 0;

    const float r2 = radius_mm * radius_mm;
    const float r_min = std::max(radius_mm, 0.15f);
    const float r2_min = r_min * r_min;

    TriangleSelector selector(vol->mesh());
    // Keep existing paint when present
    if (!ann->empty())
        selector.deserialize(ann->get_data(), false);

    int painted = 0;
    int closest_idx = -1;
    float closest_d2 = std::numeric_limits<float>::max();

    for (int fi = 0; fi < int(its.indices.size()); ++fi) {
        const stl_triangle_vertex_indices &face = its.indices[size_t(fi)];
        const Vec3f &a = its.vertices[size_t(face[0])];
        const Vec3f &b = its.vertices[size_t(face[1])];
        const Vec3f &c = its.vertices[size_t(face[2])];
        const Vec3f centroid_local = (a + b + c) / 3.f;
        const Vec3d cw = world_matrix * centroid_local.cast<double>();
        const Vec3f cwf = cw.cast<float>();
        const float d2 = (cwf - hit_world).squaredNorm();
        if (d2 < closest_d2) {
            closest_d2 = d2;
            closest_idx = fi;
        }
        if (d2 <= r2) {
            selector.set_facet(fi, ebt);
            ++painted;
        }
    }
    // Always paint at least the nearest facet if within a small snap radius
    if (painted == 0 && closest_idx >= 0 && closest_d2 <= r2_min * 4.f) {
        selector.set_facet(closest_idx, ebt);
        painted = 1;
    }
    if (painted > 0)
        ann->set(selector);
    return painted;
}

int paint_volume_all(ModelVolume *vol, int paint_kind, EnforcerBlockerType ebt)
{
    FacetsAnnotation *ann = paint_annotation_for(vol, paint_kind);
    if (!ann)
        return 0;
    const indexed_triangle_set &its = vol->mesh().its;
    if (its.indices.empty())
        return 0;
    TriangleSelector selector(vol->mesh());
    if (!ann->empty())
        selector.deserialize(ann->get_data(), false);
    for (int fi = 0; fi < int(its.indices.size()); ++fi)
        selector.set_facet(fi, ebt);
    ann->set(selector);
    return int(its.indices.size());
}

void append_its_world(
    const indexed_triangle_set &src,
    const Transform3d &world,
    std::vector<float> &pos,
    std::vector<uint32_t> &idx)
{
    const uint32_t base = uint32_t(pos.size() / 3);
    for (const Vec3f &v : src.vertices) {
        const Vec3d w = world * v.cast<double>();
        pos.push_back(float(w.x()));
        pos.push_back(float(w.y()));
        pos.push_back(float(w.z()));
    }
    for (const auto &f : src.indices) {
        idx.push_back(base + uint32_t(f[0]));
        idx.push_back(base + uint32_t(f[1]));
        idx.push_back(base + uint32_t(f[2]));
    }
}

int count_painted_on_volume(const ModelVolume *vol, int paint_kind, int state_filter)
{
    const FacetsAnnotation *ann = nullptr;
    switch (paint_kind) {
    case 0: ann = &vol->supported_facets; break;
    case 1: ann = &vol->seam_facets; break;
    case 2: ann = &vol->mmu_segmentation_facets; break;
    case 3: ann = &vol->fuzzy_skin_facets; break;
    default: return 0;
    }
    if (!ann || ann->empty())
        return 0;
    if (state_filter >= 0) {
        return ann->has_facets(*vol, EnforcerBlockerType(state_filter))
            ? int(ann->get_facets(*vol, EnforcerBlockerType(state_filter)).indices.size())
            : 0;
    }
    // Any non-NONE: count ENFORCER..max
    int total = 0;
    const int max_s = (paint_kind == 2)
        ? int(EnforcerBlockerType::ExtruderMax)
        : 2;
    for (int st = 1; st <= max_s; ++st) {
        if (ann->has_facets(*vol, EnforcerBlockerType(st)))
            total += int(ann->get_facets(*vol, EnforcerBlockerType(st)).indices.size());
    }
    return total;
}

} // namespace

extern "C" {

int orca_session_paint_at(
    orca_session_t *s,
    int object_index,
    float x, float y, float z,
    int paint_kind,
    int state,
    float radius_mm)
{
    if (!s || !s->has_model)
        return -1;
    if (paint_kind < 0 || paint_kind > 3 || !paint_state_valid(paint_kind, state)) {
        s->set_error("paint_at: bad paint_kind/state");
        return -2;
    }
    if (radius_mm < 0.f)
        radius_mm = 0.f;
    try {
        const Vec3f hit(x, y, z);
        const EnforcerBlockerType ebt = EnforcerBlockerType(state);
        int total = 0;

        auto paint_object = [&](ModelObject *obj) -> int {
            if (!obj)
                return 0;
            int n = 0;
            for (ModelVolume *vol : obj->volumes) {
                if (!vol || !vol->is_model_part())
                    continue;
                const Transform3d world = volume_world_matrix(obj, vol);
                n += paint_volume_near_point(vol, world, hit, radius_mm, paint_kind, ebt);
            }
            return n;
        };

        if (object_index >= 0) {
            if (object_index >= int(s->model.objects.size())) {
                s->set_error("paint_at: bad object index");
                return -3;
            }
            total = paint_object(s->model.objects[size_t(object_index)]);
        } else {
            // Auto: paint only the object whose volume is closest to the hit
            int best_obj = -1;
            float best_d2 = std::numeric_limits<float>::max();
            for (int oi = 0; oi < int(s->model.objects.size()); ++oi) {
                ModelObject *obj = s->model.objects[size_t(oi)];
                if (!obj)
                    continue;
                for (ModelVolume *vol : obj->volumes) {
                    if (!vol || !vol->is_model_part())
                        continue;
                    const Transform3d world = volume_world_matrix(obj, vol);
                    const indexed_triangle_set &its = vol->mesh().its;
                    for (const auto &face : its.indices) {
                        const Vec3f c =
                            (its.vertices[size_t(face[0])]
                             + its.vertices[size_t(face[1])]
                             + its.vertices[size_t(face[2])])
                            / 3.f;
                        const Vec3f cw = (world * c.cast<double>()).cast<float>();
                        const float d2 = (cw - hit).squaredNorm();
                        if (d2 < best_d2) {
                            best_d2 = d2;
                            best_obj = oi;
                        }
                    }
                }
            }
            if (best_obj >= 0)
                total = paint_object(s->model.objects[size_t(best_obj)]);
        }
        return total;
    } catch (const std::exception &ex) {
        s->set_error(std::string("paint_at: ") + ex.what());
        return -4;
    } catch (...) {
        s->set_error("paint_at: unknown error");
        return -4;
    }
}

int orca_session_paint_fill(
    orca_session_t *s, int object_index, int paint_kind, int state)
{
    if (!s || !s->has_model || object_index < 0
        || object_index >= int(s->model.objects.size()))
        return -1;
    if (paint_kind < 0 || paint_kind > 3 || !paint_state_valid(paint_kind, state)) {
        s->set_error("paint_fill: bad paint_kind/state");
        return -2;
    }
    try {
        ModelObject *obj = s->model.objects[size_t(object_index)];
        if (!obj)
            return -3;
        const EnforcerBlockerType ebt = EnforcerBlockerType(state);
        int total = 0;
        for (ModelVolume *vol : obj->volumes) {
            if (!vol || !vol->is_model_part())
                continue;
            total += paint_volume_all(vol, paint_kind, ebt);
        }
        return total;
    } catch (const std::exception &ex) {
        s->set_error(std::string("paint_fill: ") + ex.what());
        return -4;
    }
}

int orca_session_paint_clear(
    orca_session_t *s, int object_index, int paint_kind)
{
    if (!s || !s->has_model)
        return -1;
    if (paint_kind < 0 || paint_kind > 3) {
        s->set_error("paint_clear: bad paint_kind");
        return -2;
    }
    try {
        auto clear_obj = [paint_kind](ModelObject *obj) {
            if (!obj)
                return;
            for (ModelVolume *vol : obj->volumes) {
                if (!vol)
                    continue;
                if (FacetsAnnotation *ann = paint_annotation_for(vol, paint_kind))
                    ann->reset();
            }
        };
        if (object_index < 0) {
            for (ModelObject *obj : s->model.objects)
                clear_obj(obj);
        } else {
            if (object_index >= int(s->model.objects.size()))
                return -3;
            clear_obj(s->model.objects[size_t(object_index)]);
        }
        return 0;
    } catch (const std::exception &ex) {
        s->set_error(std::string("paint_clear: ") + ex.what());
        return -4;
    }
}

int orca_session_paint_stats(
    orca_session_t *s, int object_index, int paint_kind, int state,
    int *painted_count)
{
    if (!s || !painted_count)
        return -1;
    *painted_count = 0;
    if (!s->has_model)
        return 0;
    if (paint_kind < 0 || paint_kind > 3)
        return -2;
    try {
        int total = 0;
        auto acc = [&](ModelObject *obj) {
            if (!obj)
                return;
            for (ModelVolume *vol : obj->volumes) {
                if (!vol || !vol->is_model_part())
                    continue;
                total += count_painted_on_volume(vol, paint_kind, state);
            }
        };
        if (object_index < 0) {
            for (ModelObject *obj : s->model.objects)
                acc(obj);
        } else {
            if (object_index >= int(s->model.objects.size()))
                return -3;
            acc(s->model.objects[size_t(object_index)]);
        }
        *painted_count = total;
        return 0;
    } catch (const std::exception &ex) {
        s->set_error(std::string("paint_stats: ") + ex.what());
        return -4;
    }
}

int orca_session_export_paint_mesh(
    orca_session_t *s,
    int object_index,
    int paint_kind,
    int state,
    float **out_positions,
    size_t *out_vertex_count,
    uint32_t **out_indices,
    size_t *out_index_count)
{
    if (!s || !out_positions || !out_vertex_count || !out_indices || !out_index_count)
        return -1;
    *out_positions = nullptr;
    *out_indices = nullptr;
    *out_vertex_count = 0;
    *out_index_count = 0;
    if (!s->has_model || paint_kind < 0 || paint_kind > 3)
        return -2;
    try {
        std::vector<float> pos;
        std::vector<uint32_t> idx;

        auto export_obj = [&](ModelObject *obj) {
            if (!obj)
                return;
            for (ModelVolume *vol : obj->volumes) {
                if (!vol || !vol->is_model_part())
                    continue;
                FacetsAnnotation *ann = paint_annotation_for(vol, paint_kind);
                if (!ann || ann->empty())
                    continue;
                const Transform3d world = volume_world_matrix(obj, vol);
                if (state >= 0) {
                    indexed_triangle_set its =
                        ann->get_facets(*vol, EnforcerBlockerType(state));
                    if (!its.indices.empty())
                        append_its_world(its, world, pos, idx);
                } else {
                    const int max_s = (paint_kind == 2)
                        ? int(EnforcerBlockerType::ExtruderMax)
                        : 2;
                    for (int st = 1; st <= max_s; ++st) {
                        if (!ann->has_facets(*vol, EnforcerBlockerType(st)))
                            continue;
                        indexed_triangle_set its =
                            ann->get_facets(*vol, EnforcerBlockerType(st));
                        if (!its.indices.empty())
                            append_its_world(its, world, pos, idx);
                    }
                }
            }
        };

        if (object_index < 0) {
            for (ModelObject *obj : s->model.objects)
                export_obj(obj);
        } else {
            if (object_index >= int(s->model.objects.size()))
                return -3;
            export_obj(s->model.objects[size_t(object_index)]);
        }

        if (pos.empty())
            return 0;

        auto *p = static_cast<float *>(std::malloc(pos.size() * sizeof(float)));
        auto *i = static_cast<uint32_t *>(std::malloc(idx.size() * sizeof(uint32_t)));
        if (!p || !i) {
            std::free(p);
            std::free(i);
            s->set_error("export_paint_mesh: oom");
            return -4;
        }
        std::memcpy(p, pos.data(), pos.size() * sizeof(float));
        std::memcpy(i, idx.data(), idx.size() * sizeof(uint32_t));
        *out_positions = p;
        *out_vertex_count = pos.size() / 3;
        *out_indices = i;
        *out_index_count = idx.size();
        return 0;
    } catch (const std::exception &ex) {
        s->set_error(std::string("export_paint_mesh: ") + ex.what());
        return -5;
    } catch (...) {
        s->set_error("export_paint_mesh: unknown error");
        return -5;
    }
}

// ---------------------------------------------------------------------------
// W1: Brim ears (ModelObject::brim_points — point markers, not facets)
// ---------------------------------------------------------------------------

static Transform3d object_instance_matrix(const ModelObject *obj)
{
    if (obj && !obj->instances.empty() && obj->instances[0])
        return obj->instances[0]->get_transformation().get_matrix();
    return Transform3d::Identity();
}

static float brim_ear_default_radius(const orca_session_t *s)
{
    // Desktop: initial_layer_line_width * nozzle * 8, clamped 0.1–100.
    // Fallback 5 mm when config incomplete.
    double nozzle = 0.4;
    if (s->config.has("nozzle_diameter")) {
        if (const auto *opt = s->config.option<ConfigOptionFloats>("nozzle_diameter")) {
            if (!opt->values.empty())
                nozzle = opt->values.front();
        }
    }
    double ilw = nozzle;
    if (s->config.has("initial_layer_line_width")) {
        try {
            ilw = s->config.get_abs_value("initial_layer_line_width", nozzle);
        } catch (...) {
            ilw = nozzle;
        }
    }
    return std::clamp(float(ilw * 8.0), 0.1f, 100.f);
}

static void ensure_brim_type_painted(orca_session_t *s, ModelObject *obj)
{
    // Prefer object-level + global brim_type=painted so MakeBrim uses brim_points.
    ConfigSubstitutionContext ctx(ForwardCompatibilitySubstitutionRule::Enable);
    if (obj)
        obj->config.set_deserialize("brim_type", "painted", ctx);
    s->config.set_deserialize("brim_type", "painted", ctx);
}

int orca_session_brim_ear_add(
    orca_session_t *s, int object_index,
    float world_x, float world_y, float radius_mm)
{
    if (!s || !s->has_model)
        return -1;
    if (object_index < 0)
        object_index = 0;
    if (object_index >= int(s->model.objects.size())) {
        s->set_error("brim_ear_add: bad object index");
        return -2;
    }
    try {
        ModelObject *obj = s->model.objects[size_t(object_index)];
        if (!obj || obj->instances.empty()) {
            s->set_error("brim_ear_add: invalid object");
            return -3;
        }
        if (radius_mm <= 0.f)
            radius_mm = brim_ear_default_radius(s);

        const Transform3d trsf = object_instance_matrix(obj);
        // Desktop: place ear on bed plane (world z ≈ 0−), then store object-space.
        Vec3d world_pos(double(world_x), double(world_y), -0.0001);
        Vec3d object_pos = trsf.inverse() * world_pos;
        obj->brim_points.emplace_back(
            float(object_pos.x()), float(object_pos.y()), float(object_pos.z()),
            radius_mm);
        ensure_brim_type_painted(s, obj);
        return int(obj->brim_points.size());
    } catch (const std::exception &ex) {
        s->set_error(std::string("brim_ear_add: ") + ex.what());
        return -4;
    }
}

int orca_session_brim_ear_remove_nearest(
    orca_session_t *s, int object_index,
    float world_x, float world_y, float max_dist_mm)
{
    if (!s || !s->has_model)
        return -1;
    if (object_index < 0)
        object_index = 0;
    if (object_index >= int(s->model.objects.size()))
        return -2;
    if (max_dist_mm <= 0.f)
        max_dist_mm = 5.f;
    try {
        ModelObject *obj = s->model.objects[size_t(object_index)];
        if (!obj)
            return -3;
        const Transform3d trsf = object_instance_matrix(obj);
        const float max_d2 = max_dist_mm * max_dist_mm;
        int best = -1;
        float best_d2 = max_d2;
        for (int i = 0; i < int(obj->brim_points.size()); ++i) {
            // BrimPoint::transform is non-const; apply matrix manually
            const Vec3d w = trsf * obj->brim_points[size_t(i)].pos.cast<double>();
            const float dx = float(w.x()) - world_x;
            const float dy = float(w.y()) - world_y;
            const float d2 = dx * dx + dy * dy;
            if (d2 <= best_d2) {
                best_d2 = d2;
                best = i;
            }
        }
        if (best < 0)
            return int(obj->brim_points.size()); // nothing removed
        obj->brim_points.erase(obj->brim_points.begin() + best);
        return int(obj->brim_points.size());
    } catch (const std::exception &ex) {
        s->set_error(std::string("brim_ear_remove: ") + ex.what());
        return -4;
    }
}

int orca_session_brim_ear_clear(orca_session_t *s, int object_index)
{
    if (!s || !s->has_model)
        return -1;
    try {
        if (object_index < 0) {
            for (ModelObject *obj : s->model.objects)
                if (obj)
                    obj->brim_points.clear();
        } else {
            if (object_index >= int(s->model.objects.size()))
                return -2;
            if (ModelObject *obj = s->model.objects[size_t(object_index)])
                obj->brim_points.clear();
        }
        return 0;
    } catch (const std::exception &ex) {
        s->set_error(std::string("brim_ear_clear: ") + ex.what());
        return -3;
    }
}

int orca_session_brim_ear_count(orca_session_t *s, int object_index, int *count)
{
    if (!s || !count)
        return -1;
    *count = 0;
    if (!s->has_model)
        return 0;
    try {
        if (object_index < 0) {
            for (const ModelObject *obj : s->model.objects)
                if (obj)
                    *count += int(obj->brim_points.size());
        } else {
            if (object_index >= int(s->model.objects.size()))
                return -2;
            if (const ModelObject *obj = s->model.objects[size_t(object_index)])
                *count = int(obj->brim_points.size());
        }
        return 0;
    } catch (...) {
        return -3;
    }
}

int orca_session_brim_ear_list(
    orca_session_t *s, int object_index,
    float **out_xyzr, size_t *count)
{
    if (!s || !out_xyzr || !count)
        return -1;
    *out_xyzr = nullptr;
    *count = 0;
    if (!s->has_model)
        return 0;
    try {
        std::vector<float> flat;
        auto acc = [&](ModelObject *obj) {
            if (!obj)
                return;
            const Transform3d trsf = object_instance_matrix(obj);
            for (const BrimPoint &bp : obj->brim_points) {
                const Vec3d w = trsf * bp.pos.cast<double>();
                flat.push_back(float(w.x()));
                flat.push_back(float(w.y()));
                flat.push_back(float(w.z()));
                flat.push_back(bp.head_front_radius);
            }
        };
        if (object_index < 0) {
            for (ModelObject *obj : s->model.objects)
                acc(obj);
        } else {
            if (object_index >= int(s->model.objects.size()))
                return -2;
            acc(s->model.objects[size_t(object_index)]);
        }
        if (flat.empty())
            return 0;
        auto *p = static_cast<float *>(std::malloc(flat.size() * sizeof(float)));
        if (!p) {
            s->set_error("brim_ear_list: oom");
            return -3;
        }
        std::memcpy(p, flat.data(), flat.size() * sizeof(float));
        *out_xyzr = p;
        *count = flat.size() / 4;
        return 0;
    } catch (const std::exception &ex) {
        s->set_error(std::string("brim_ear_list: ") + ex.what());
        return -4;
    }
}

int orca_session_export_brim_ear_mesh(
    orca_session_t *s, int object_index,
    float **out_positions, size_t *out_vertex_count,
    uint32_t **out_indices, size_t *out_index_count)
{
    if (!s || !out_positions || !out_vertex_count || !out_indices || !out_index_count)
        return -1;
    *out_positions = nullptr;
    *out_indices = nullptr;
    *out_vertex_count = 0;
    *out_index_count = 0;
    if (!s->has_model)
        return 0;
    try {
        std::vector<float> pos;
        std::vector<uint32_t> idx;
        constexpr int N = 16; // disc sides
        auto add_disc = [&](float cx, float cy, float cz, float r) {
            const uint32_t base = uint32_t(pos.size() / 3);
            // center + ring
            pos.push_back(cx);
            pos.push_back(cy);
            pos.push_back(cz + 0.05f);
            for (int i = 0; i < N; ++i) {
                const double a = 2.0 * M_PI * i / N;
                pos.push_back(cx + r * float(std::cos(a)));
                pos.push_back(cy + r * float(std::sin(a)));
                pos.push_back(cz + 0.05f);
            }
            for (int i = 0; i < N; ++i) {
                idx.push_back(base);
                idx.push_back(base + 1 + uint32_t(i));
                idx.push_back(base + 1 + uint32_t((i + 1) % N));
            }
        };
        auto acc = [&](ModelObject *obj) {
            if (!obj)
                return;
            const Transform3d trsf = object_instance_matrix(obj);
            for (const BrimPoint &bp : obj->brim_points) {
                const Vec3d w = trsf * bp.pos.cast<double>();
                add_disc(float(w.x()), float(w.y()), 0.f, std::max(0.2f, bp.head_front_radius));
            }
        };
        if (object_index < 0) {
            for (ModelObject *obj : s->model.objects)
                acc(obj);
        } else {
            if (object_index >= int(s->model.objects.size()))
                return -2;
            acc(s->model.objects[size_t(object_index)]);
        }
        if (pos.empty())
            return 0;
        auto *p = static_cast<float *>(std::malloc(pos.size() * sizeof(float)));
        auto *i = static_cast<uint32_t *>(std::malloc(idx.size() * sizeof(uint32_t)));
        if (!p || !i) {
            std::free(p);
            std::free(i);
            s->set_error("export_brim_ear_mesh: oom");
            return -3;
        }
        std::memcpy(p, pos.data(), pos.size() * sizeof(float));
        std::memcpy(i, idx.data(), idx.size() * sizeof(uint32_t));
        *out_positions = p;
        *out_vertex_count = pos.size() / 3;
        *out_indices = i;
        *out_index_count = idx.size();
        return 0;
    } catch (const std::exception &ex) {
        s->set_error(std::string("export_brim_ear_mesh: ") + ex.what());
        return -4;
    }
}

// ---------------------------------------------------------------------------
// W2: Mesh boolean + simplify + advanced plane cut
// ---------------------------------------------------------------------------

int orca_session_mesh_boolean(
    orca_session_t *s, int object_a, int object_b, int op, int delete_b)
{
    if (!s || !s->has_model)
        return -1;
    if (object_a < 0 || object_b < 0
        || object_a >= int(s->model.objects.size())
        || object_b >= int(s->model.objects.size())
        || object_a == object_b) {
        s->set_error("mesh_boolean: need two distinct valid object indices");
        return -2;
    }
    if (op < 0 || op > 2) {
        s->set_error("mesh_boolean: op 0=union 1=diff 2=intersect");
        return -3;
    }
    try {
        ModelObject *A = s->model.objects[size_t(object_a)];
        ModelObject *B = s->model.objects[size_t(object_b)];
        if (!A || !B) {
            s->set_error("mesh_boolean: null object");
            return -4;
        }
        const char *op_str = (op == 0) ? "UNION" : (op == 1) ? "A_NOT_B" : "INTERSECTION";
        // Transform B mesh into A's instance frame so booleans align in world space.
        TriangleMesh mesh_a = A->mesh();
        TriangleMesh mesh_b = B->mesh();
        const Transform3d ta = object_instance_matrix(A);
        const Transform3d tb = object_instance_matrix(B);
        // Bring both to world, boolean, then back into A local (identity after replace).
        mesh_a.transform(ta);
        mesh_b.transform(tb);

        std::vector<TriangleMesh> results;
        MeshBoolean::mcut::make_boolean(mesh_a, mesh_b, results, op_str);
        if (results.empty()) {
            s->set_error("mesh_boolean: empty result");
            return -5;
        }
        // Put result into A's local space (un-apply A instance)
        const Transform3d inv_a = ta.inverse();
        A->clear_volumes();
        int i = 1;
        for (TriangleMesh &m : results) {
            m.transform(inv_a);
            ModelVolume *vol = A->add_volume(std::move(m));
            if (vol)
                vol->name = A->name + "_" + std::to_string(i++);
        }
        A->invalidate_bounding_box();
        A->ensure_on_bed();

        if (delete_b) {
            // delete higher index first if needed — object_b may shift if a < b after delete
            s->model.delete_object(size_t(object_b));
        }
        s->has_model = !s->model.objects.empty();
        return 0;
    } catch (const std::exception &ex) {
        s->set_error(std::string("mesh_boolean: ") + ex.what());
        return -6;
    } catch (...) {
        s->set_error("mesh_boolean: unknown error");
        return -6;
    }
}

int orca_session_simplify_mesh(
    orca_session_t *s, int object_index, int target_faces)
{
    if (!s || !s->has_model)
        return -1;
    if (object_index < 0)
        object_index = 0;
    if (object_index >= int(s->model.objects.size())) {
        s->set_error("simplify_mesh: bad object index");
        return -2;
    }
    try {
        ModelObject *obj = s->model.objects[size_t(object_index)];
        if (!obj) {
            s->set_error("simplify_mesh: null object");
            return -3;
        }
        int total_faces = 0;
        for (ModelVolume *vol : obj->volumes) {
            if (!vol || !vol->is_model_part())
                continue;
            TriangleMesh mesh = vol->mesh();
            indexed_triangle_set &its = mesh.its;
            if (its.indices.empty())
                continue;
            const int cur = int(its.indices.size());
            uint32_t want = 0;
            if (target_faces > 0)
                want = uint32_t(std::max(4, std::min(target_faces, cur)));
            else
                want = uint32_t(std::max(4, cur / 2));
            if (want >= uint32_t(cur)) {
                total_faces += cur;
                continue;
            }
            its_quadric_edge_collapse(its, want, nullptr, nullptr, nullptr);
            vol->set_mesh(std::move(mesh));
            vol->calculate_convex_hull();
            vol->invalidate_convex_hull_2d();
            total_faces += int(vol->mesh().its.indices.size());
        }
        obj->invalidate_bounding_box();
        return total_faces;
    } catch (const std::exception &ex) {
        s->set_error(std::string("simplify_mesh: ") + ex.what());
        return -4;
    } catch (...) {
        s->set_error("simplify_mesh: unknown error");
        return -4;
    }
}

int orca_session_cut_object_plane(
    orca_session_t *s, int index,
    float px, float py, float pz,
    float nx, float ny, float nz,
    int keep_upper, int keep_lower)
{
    if (!s || !s->has_model || index < 0 || index >= int(s->model.objects.size()))
        return -1;
    if (!keep_upper && !keep_lower) {
        s->set_error("cut_plane: keep_upper and/or keep_lower required");
        return -2;
    }
    try {
        ModelObject *object = s->model.objects[size_t(index)];
        if (!object || object->instances.empty()) {
            s->set_error("cut_plane: invalid object");
            return -3;
        }
        Vec3d n = Vec3d(double(nx), double(ny), double(nz));
        const double nlen = n.norm();
        if (nlen < 1e-9) {
            s->set_error("cut_plane: zero normal");
            return -4;
        }
        n /= nlen;
        // Build cut matrix: rotation that maps +Z to n, then translate so origin is on plane.
        // Cut expects transform of the cut plane (local XY plane → world cut plane).
        Matrix3d rot_m = Matrix3d::Identity();
        Vec3d axis = Vec3d::UnitX();
        double phi = 0.;
        Geometry::rotation_from_two_vectors(Vec3d::UnitZ(), n, axis, phi, &rot_m);
        Transform3d rot = Transform3d::Identity();
        rot.linear() = rot_m;
        const Vec3d point = Vec3d(double(px), double(py), double(pz));
        const size_t instance_idx = 0;
        const Vec3d instance_offset = object->instances[instance_idx]->get_offset();
        // Plane point relative to instance offset (same convention as cut_object_z)
        Transform3d cut_matrix = Geometry::translation_transform(point - instance_offset) * rot;

        ModelObjectCutAttributes attrs =
            (keep_upper ? ModelObjectCutAttribute::KeepUpper : ModelObjectCutAttributes{}) |
            (keep_lower ? ModelObjectCutAttribute::KeepLower : ModelObjectCutAttributes{});
        Cut cut(object, int(instance_idx), cut_matrix, attrs);
        const ModelObjectPtrs new_objects = cut.perform_with_plane();
        s->model.delete_object(size_t(index));
        for (ModelObject *mo : new_objects) {
            if (!mo)
                continue;
            ModelObject *added = s->model.add_object(*mo);
            if (added) {
                added->sort_volumes(true);
                added->ensure_on_bed();
            }
        }
        s->has_model = !s->model.objects.empty();
        return int(s->model.objects.size());
    } catch (const std::exception &ex) {
        s->set_error(std::string("cut_object_plane: ") + ex.what());
        return -5;
    } catch (...) {
        s->set_error("cut_object_plane: unknown error");
        return -5;
    }
}

const char *orca_session_last_error(orca_session_t *s)
{
    if (!s)
        return "null session";
    return s->last_error.c_str();
}

const char *orca_version_string(void)
{
    // Real Orca version from generated libslic3r_version.h + port tag
    return "OrcaSlicer " SoftFever_VERSION " (iOS port · official libslic3r)";
}

} // extern "C"
