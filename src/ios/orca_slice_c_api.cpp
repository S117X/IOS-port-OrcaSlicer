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
#include "libslic3r/libslic3r_version.h"

#include <cstdlib>
#include <cstring>
#include <cstdio>
#include <vector>
#include <cmath>
#include <functional>
#include <algorithm>

using namespace Slic3r;

struct orca_session {
    std::string resources_path;
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

    void set_error(const std::string &e) { last_error = e; }
    void clear_error() { last_error.clear(); }
    void report_progress(int pct, const char *msg) {
        if (progress_fn)
            progress_fn(pct, msg, progress_user);
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
    if (!s || !s->has_model)
        return -1;
    try {
        const double rad = double(degrees) * M_PI / 180.0;
        for_each_object(s, index, [&](ModelObject *obj) {
            for (ModelInstance *inst : obj->instances) {
                if (!inst) continue;
                // rotate around Z (bed normal)
                inst->set_rotation(Z, inst->get_rotation(Z) + rad);
            }
            obj->invalidate_bounding_box();
            obj->ensure_on_bed();
        });
        return 0;
    } catch (const std::exception &ex) {
        s->set_error(std::string("rotate: ") + ex.what());
        return -2;
    } catch (...) {
        s->set_error("rotate: unknown error");
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

int orca_session_arrange(orca_session_t *s)
{
    if (!s || !s->has_model)
        return -1;
    try {
        // Simple row arrange with 10mm gap (full libnest2d arrange later)
        double x = 10.0, y = 10.0, row_h = 0.0;
        double bed_w = 220.0, bed_h = 220.0;
        if (const ConfigOptionPoints *pa = s->config.option<ConfigOptionPoints>("printable_area")) {
            if (!pa->values.empty()) {
                BoundingBoxf bedbb;
                for (const Vec2d &p : pa->values)
                    bedbb.merge(Vec2d(p.x(), p.y()));
                bed_w = bedbb.max.x() - bedbb.min.x();
                bed_h = bedbb.max.y() - bedbb.min.y();
                x = bedbb.min.x() + 10.0;
                y = bedbb.min.y() + 10.0;
            }
        }
        const double gap = 10.0;
        for (ModelObject *obj : s->model.objects) {
            if (!obj || obj->instances.empty()) continue;
            BoundingBoxf3 bb = obj->instance_bounding_box(0);
            double w = bb.size().x();
            double h = bb.size().y();
            if (x + w > bed_w - 5.0) {
                x = 10.0;
                y += row_h + gap;
                row_h = 0.0;
            }
            if (y + h > bed_h - 5.0) {
                // overflow: still place, engine may warn on slice
            }
            Vec3d cur = bb.center();
            Vec3d target(x + w * 0.5, y + h * 0.5, cur.z());
            Vec3d delta = target - cur;
            for (ModelInstance *inst : obj->instances) {
                if (!inst) continue;
                inst->set_offset(inst->get_offset() + delta);
            }
            obj->invalidate_bounding_box();
            obj->ensure_on_bed();
            x += w + gap;
            row_h = std::max(row_h, h);
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
