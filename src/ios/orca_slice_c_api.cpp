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

#include <cstdlib>
#include <cstring>
#include <cstdio>
#include <cctype>
#include <vector>
#include <cmath>
#include <functional>
#include <algorithm>
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
    float       last_filament_mm3{0.f};
    int         last_layers{0};

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
    std::vector<std::string> user_process_names;

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
        // Append user-saved process presets (always listed)
        for (const std::string &u : user_process_names) {
            if (std::find(process_names.begin(), process_names.end(), u) == process_names.end())
                process_names.push_back(u);
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

    void scan_user_process_presets() {
        user_process_names.clear();
        try {
            fs::path dir = user_process_dir();
            if (!fs::exists(dir))
                return;
            for (fs::directory_iterator it(dir), end; it != end; ++it) {
                if (!fs::is_regular_file(it->path()))
                    continue;
                if (it->path().extension() != ".json")
                    continue;
                user_process_names.push_back(it->path().stem().string());
            }
            std::sort(user_process_names.begin(), user_process_names.end());
        } catch (...) {
        }
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
        double vol = 0.0;
        for (const auto &kv : result.print_statistics.model_volumes_per_extruder)
            vol += kv.second;
        s->last_filament_mm3 = float(vol);
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
        // Keep user process JSON if currently active
        DynamicPrintConfig user_overlay;
        const bool had_user = s->active_process_from_user;
        const std::string user_name = s->selected_process_cache;
        if (had_user)
            user_overlay = s->config;

        s->config = s->preset_bundle->full_config(true);
        if (had_user) {
            // Re-apply user process options on top of machine/filament full_config
            s->config.apply(user_overlay);
        }
        s->has_config = true;
        s->sync_selected_caches();
        if (had_user && !user_name.empty())
            s->selected_process_cache = user_name;
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
        // Sanitize filename
        std::string safe;
        for (const char *p = name; *p; ++p) {
            char c = *p;
            if (std::isalnum((unsigned char)c) || c == ' ' || c == '-' || c == '_' || c == '.')
                safe.push_back(c);
            else
                safe.push_back('_');
        }
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
