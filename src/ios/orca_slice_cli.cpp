/**
 * Minimal CLI to verify orca_ios_api + libslic3r slice path.
 * Usage: orca_slice_cli <model.stl|3mf> [out.gcode] [config.json|ini]
 */
// libslic3r references header-only nanosvg without an implementation TU.
#define NANOSVG_IMPLEMENTATION
#include "nanosvg/nanosvg.h"
#define NANOSVGRAST_IMPLEMENTATION
#include "nanosvg/nanosvgrast.h"

#include "orca_slice_c_api.h"

#include <cstdio>
#include <cstring>
#include <string>

int main(int argc, char **argv)
{
    if (argc < 2) {
        std::fprintf(stderr, "Usage: %s <model> [out.gcode] [config]\n", argv[0]);
        std::fprintf(stderr, "Engine: %s\n", orca_version_string());
        return 1;
    }

    const char *model = argv[1];
    const char *out =
        argc >= 3 ? argv[2] : "plate_1.gcode";
    const char *config = argc >= 4 ? argv[3] : nullptr;

    std::printf("version: %s\n", orca_version_string());
    orca_session_t *s = orca_session_create(nullptr);
    if (!s) {
        std::fprintf(stderr, "orca_session_create failed\n");
        return 2;
    }

    if (config) {
        int rc = orca_session_load_config(s, config);
        if (rc != 0) {
            std::fprintf(stderr, "load_config rc=%d: %s\n", rc, orca_session_last_error(s));
            orca_session_destroy(s);
            return 3;
        }
        std::printf("config loaded: %s\n", config);
    }

    // Sensible defaults for a simple FFF slice without full profile stack
    orca_session_set_option(s, "layer_height", "0.2");
    orca_session_set_option(s, "wall_loops", "2");
    orca_session_set_option(s, "sparse_infill_density", "15%");
    orca_session_set_option(s, "filament_diameter", "1.75");
    orca_session_set_option(s, "nozzle_diameter", "0.4");
    orca_session_set_option(s, "printable_area", "0x0,220x0,220x220,0x220");
    orca_session_set_option(s, "printable_height", "250");

    int rc = orca_session_load_model(s, model);
    if (rc != 0) {
        std::fprintf(stderr, "load_model rc=%d: %s\n", rc, orca_session_last_error(s));
        orca_session_destroy(s);
        return 4;
    }
    std::printf("model loaded: %s\n", model);

    rc = orca_session_slice_to_gcode(s, out);
    if (rc != 0) {
        std::fprintf(stderr, "slice rc=%d: %s\n", rc, orca_session_last_error(s));
        orca_session_destroy(s);
        return 5;
    }
    std::printf("gcode written: %s\n", out);
    orca_session_destroy(s);
    return 0;
}
