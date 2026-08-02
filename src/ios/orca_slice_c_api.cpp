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
#include "libslic3r/Utils.hpp"

using namespace Slic3r;

struct orca_session {
    std::string resources_path;
    std::string last_error;
    Model       model;
    DynamicPrintConfig config;
    bool        has_model{false};
    bool        has_config{false};

    void set_error(const std::string &e) { last_error = e; }
    void clear_error() { last_error.clear(); }
};

static void ensure_default_config(orca_session *s)
{
    if (s->has_config)
        return;
    // Official defaults from libslic3r PrintConfig
    s->config = PrintConfig::full_print_config();
    s->has_config = true;
}

extern "C" {

orca_session_t *orca_session_create(const char *resources_path)
{
    try {
        auto *s = new orca_session();
        if (resources_path && *resources_path)
            s->resources_path = resources_path;
        // Point utils at bundled resources when set (profiles, etc.)
        if (!s->resources_path.empty()) {
            // set_var_dir used by desktop; keep path for profile loads
        }
        s->config = PrintConfig::full_print_config();
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

int orca_session_load_model(orca_session_t *s, const char *path)
{
    if (!s || !path)
        return -1;
    s->clear_error();
    try {
        DynamicPrintConfig  file_config;
        ConfigSubstitutionContext substitutions(ForwardCompatibilitySubstitutionRule::EnableSilent);
        s->model = Model::read_from_file(
            std::string(path),
            &file_config,
            &substitutions,
            LoadStrategy::AddDefaultInstances);
        if (s->model.objects.empty()) {
            s->set_error("Model has no objects after load");
            s->has_model = false;
            return -2;
        }
        // Merge any config embedded in 3MF into session config
        ensure_default_config(s);
        s->config.apply(file_config);
        s->has_model = true;
        return 0;
    } catch (const std::exception &ex) {
        s->set_error(std::string("load_model: ") + ex.what());
        s->has_model = false;
        return -3;
    } catch (...) {
        s->set_error("load_model: unknown error");
        s->has_model = false;
        return -3;
    }
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

        Print print;
        // Center / place objects if needed — use model as loaded
        auto status = print.apply(s->model, s->config);
        (void) status;
        if (print.empty()) {
            s->set_error("Print empty after apply — objects outside bed or invalid");
            return -3;
        }

        print.set_status_silent();
        print.process();

        GCodeProcessorResult result;
        std::string out = print.export_gcode(std::string(gcode_out_path), &result, nullptr);
        if (out.empty()) {
            s->set_error("export_gcode returned empty path");
            return -4;
        }
        return 0;
    } catch (const std::exception &ex) {
        s->set_error(std::string("slice: ") + ex.what());
        return -5;
    } catch (...) {
        s->set_error("slice: unknown error");
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
    return "OrcaSlicer-ios-port libslic3r-wrapper";
}

} // extern "C"
