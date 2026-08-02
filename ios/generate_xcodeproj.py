#!/usr/bin/env python3
"""Generate Xcode project for OrcaSlicer iOS/macOS host (official libslic3r via C ABI)."""
from pathlib import Path
import uuid

ROOT = Path(__file__).resolve().parent
REPO = ROOT.parent
PROJ = ROOT / "OrcaSlicer.xcodeproj"
PROJ.mkdir(exist_ok=True)

ENGINE_MAC = REPO / "build-macos-headless-arm64" / "engine_bundle" / "lib"
ENGINE_IOS = REPO / "build-ios-iphonesimulator-arm64" / "engine_bundle" / "lib"

has_mac_engine = (ENGINE_MAC / "liborca_engine.a").is_file()
has_ios_engine = (ENGINE_IOS / "liborca_engine.a").is_file()


def uid():
    return uuid.uuid4().hex[:24].upper()


IDs = {k: uid() for k in [
    "project", "target", "sources", "resources", "frameworks", "product",
    "swift_app", "swift_engine", "sample_stl",
    "config_list_proj", "config_list_tgt",
    "debug_proj", "release_proj", "debug_tgt", "release_tgt",
    "group_main", "group_app", "group_products",
]}

mac_lib_path = "$(SRCROOT)/../build-macos-headless-arm64/engine_bundle/lib"
ios_lib_path = "$(SRCROOT)/../build-ios-iphonesimulator-arm64/engine_bundle/lib"
hdr_path = "$(SRCROOT)/../src/ios"

mac_ld = (
    "-lorca_engine -lc++ -lz -liconv -lexpat "
    "-framework Foundation -framework ModelIO -framework IOKit "
    "-framework CoreFoundation -framework Security -framework SystemConfiguration"
)
ios_ld = (
    "-lorca_engine -lc++ -lz -liconv -lexpat "
    "-framework Foundation -framework ModelIO "
    "-framework Security -framework SystemConfiguration"
)


def tgt_settings(name: str) -> str:
    # Base: no engine. SDK-conditional ORCA_LINKED + link flags when bundles exist.
    lines = [
        "\t\t\tisa = XCBuildConfiguration;",
        "\t\t\tbuildSettings = {",
        "\t\t\t\tALWAYS_SEARCH_USER_PATHS = NO;",
        "\t\t\t\tASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;",
        "\t\t\t\tCLANG_ENABLE_MODULES = YES;",
        "\t\t\t\tCLANG_ENABLE_OBJC_ARC = YES;",
        "\t\t\t\tCODE_SIGN_STYLE = Automatic;",
        "\t\t\t\tCURRENT_PROJECT_VERSION = 1;",
        '\t\t\t\tDEVELOPMENT_TEAM = "";',
        "\t\t\t\tENABLE_PREVIEWS = YES;",
        "\t\t\t\tGENERATE_INFOPLIST_FILE = NO;",
        "\t\t\t\tHEADER_SEARCH_PATHS = (",
        f'\t\t\t\t\t"{hdr_path}",',
        '\t\t\t\t\t"$(inherited)",',
        "\t\t\t\t);",
        "\t\t\t\tINFOPLIST_FILE = OrcaSlicerApp/Info.plist;",
        "\t\t\t\tINFOPLIST_KEY_UIApplicationSceneManifest_Generation = YES;",
        "\t\t\t\tIPHONEOS_DEPLOYMENT_TARGET = 16.0;",
        "\t\t\t\tLD_RUNPATH_SEARCH_PATHS = (",
        '\t\t\t\t\t"$(inherited)",',
        '\t\t\t\t\t"@executable_path/Frameworks",',
        "\t\t\t\t);",
        "\t\t\t\tLIBRARY_SEARCH_PATHS = (",
        '\t\t\t\t\t"$(inherited)",',
        "\t\t\t\t);",
        "\t\t\t\tMACOSX_DEPLOYMENT_TARGET = 13.0;",
        "\t\t\t\tMARKETING_VERSION = 2.5.0;",
        "\t\t\t\tOTHER_LDFLAGS = (",
        '\t\t\t\t\t"$(inherited)",',
        "\t\t\t\t);",
        "\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = com.orcaslicer.ios;",
        '\t\t\t\tPRODUCT_NAME = "$(TARGET_NAME)";',
        '\t\t\t\tSUPPORTED_PLATFORMS = "iphoneos iphonesimulator macosx";',
        "\t\t\t\tSUPPORTS_MACCATALYST = NO;",
        '\t\t\t\tSWIFT_ACTIVE_COMPILATION_CONDITIONS = "";',
        "\t\t\t\tSWIFT_EMIT_LOC_STRINGS = YES;",
        '\t\t\t\tSWIFT_OBJC_BRIDGING_HEADER = "OrcaSlicerApp/Bridging-Header.h";',
        "\t\t\t\tSWIFT_VERSION = 5.0;",
        '\t\t\t\tTARGETED_DEVICE_FAMILY = "1,2,6";',
    ]
    if has_mac_engine:
        lines += [
            f'\t\t\t\t"LIBRARY_SEARCH_PATHS[sdk=macosx*]" = (',
            f'\t\t\t\t\t"{mac_lib_path}",',
            '\t\t\t\t\t"$(inherited)",',
            "\t\t\t\t);",
            f'\t\t\t\t"OTHER_LDFLAGS[sdk=macosx*]" = (',
            '\t\t\t\t\t"$(inherited)",',
            f'\t\t\t\t\t"{mac_ld}",',
            "\t\t\t\t);",
            '\t\t\t\t"SWIFT_ACTIVE_COMPILATION_CONDITIONS[sdk=macosx*]" = "ORCA_LINKED";',
        ]
    if has_ios_engine:
        lines += [
            f'\t\t\t\t"LIBRARY_SEARCH_PATHS[sdk=iphonesimulator*]" = (',
            f'\t\t\t\t\t"{ios_lib_path}",',
            '\t\t\t\t\t"$(inherited)",',
            "\t\t\t\t);",
            f'\t\t\t\t"OTHER_LDFLAGS[sdk=iphonesimulator*]" = (',
            '\t\t\t\t\t"$(inherited)",',
            f'\t\t\t\t\t"{ios_ld}",',
            "\t\t\t\t);",
            '\t\t\t\t"SWIFT_ACTIVE_COMPILATION_CONDITIONS[sdk=iphonesimulator*]" = "ORCA_LINKED";',
            # Device arm64 uses same path once built for iphoneos (future)
            f'\t\t\t\t"LIBRARY_SEARCH_PATHS[sdk=iphoneos*]" = (',
            f'\t\t\t\t\t"{ios_lib_path}",',
            '\t\t\t\t\t"$(inherited)",',
            "\t\t\t\t);",
            f'\t\t\t\t"OTHER_LDFLAGS[sdk=iphoneos*]" = (',
            '\t\t\t\t\t"$(inherited)",',
            f'\t\t\t\t\t"{ios_ld}",',
            "\t\t\t\t);",
            '\t\t\t\t"SWIFT_ACTIVE_COMPILATION_CONDITIONS[sdk=iphoneos*]" = "ORCA_LINKED";',
        ]
    lines += [
        "\t\t\t};",
        f"\t\t\tname = {name};",
    ]
    return "\n".join(lines)


pbx = f'''// !$*UTF8*$!
{{
	archiveVersion = 1;
	classes = {{}};
	objectVersion = 56;
	objects = {{

/* Begin PBXBuildFile section */
		{IDs["swift_app"]} /* OrcaSlicerApp.swift in Sources */ = {{isa = PBXBuildFile; fileRef = A10000000000000000000001 /* OrcaSlicerApp.swift */; }};
		{IDs["swift_engine"]} /* OrcaEngine.swift in Sources */ = {{isa = PBXBuildFile; fileRef = A10000000000000000000002 /* OrcaEngine.swift */; }};
		{IDs["sample_stl"]} /* sample_cube_20mm.stl in Resources */ = {{isa = PBXBuildFile; fileRef = A10000000000000000000005 /* sample_cube_20mm.stl */; }};
/* End PBXBuildFile section */

/* Begin PBXFileReference section */
		A10000000000000000000001 /* OrcaSlicerApp.swift */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = OrcaSlicerApp.swift; sourceTree = "<group>"; }};
		A10000000000000000000002 /* OrcaEngine.swift */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = OrcaEngine.swift; sourceTree = "<group>"; }};
		A10000000000000000000003 /* Info.plist */ = {{isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = Info.plist; sourceTree = "<group>"; }};
		A10000000000000000000004 /* Bridging-Header.h */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.c.h; path = "Bridging-Header.h"; sourceTree = "<group>"; }};
		A10000000000000000000005 /* sample_cube_20mm.stl */ = {{isa = PBXFileReference; lastKnownFileType = text; name = sample_cube_20mm.stl; path = sample_cube_20mm.stl; sourceTree = "<group>"; }};
		{IDs["product"]} /* OrcaSlicer.app */ = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = OrcaSlicer.app; sourceTree = BUILT_PRODUCTS_DIR; }};
/* End PBXFileReference section */

/* Begin PBXGroup section */
		{IDs["group_main"]} = {{
			isa = PBXGroup;
			children = (
				{IDs["group_app"]},
				A10000000000000000000005 /* sample_cube_20mm.stl */,
				{IDs["group_products"]},
			);
			sourceTree = "<group>";
		}};
		{IDs["group_app"]} = {{
			isa = PBXGroup;
			children = (
				A10000000000000000000001 /* OrcaSlicerApp.swift */,
				A10000000000000000000002 /* OrcaEngine.swift */,
				A10000000000000000000003 /* Info.plist */,
				A10000000000000000000004 /* Bridging-Header.h */,
			);
			path = OrcaSlicerApp;
			sourceTree = "<group>";
		}};
		{IDs["group_products"]} = {{
			isa = PBXGroup;
			children = (
				{IDs["product"]} /* OrcaSlicer.app */,
			);
			name = Products;
			sourceTree = "<group>";
		}};
/* End PBXGroup section */

/* Begin PBXNativeTarget section */
		{IDs["target"]} /* OrcaSlicer */ = {{
			isa = PBXNativeTarget;
			buildConfigurationList = {IDs["config_list_tgt"]} /* Build configuration list for PBXNativeTarget "OrcaSlicer" */;
			buildPhases = (
				{IDs["sources"]} /* Sources */,
				{IDs["frameworks"]} /* Frameworks */,
				{IDs["resources"]} /* Resources */,
			);
			buildRules = (
			);
			dependencies = (
			);
			name = OrcaSlicer;
			productName = OrcaSlicer;
			productReference = {IDs["product"]} /* OrcaSlicer.app */;
			productType = "com.apple.product-type.application";
		}};
/* End PBXNativeTarget section */

/* Begin PBXProject section */
		{IDs["project"]} /* Project object */ = {{
			isa = PBXProject;
			attributes = {{
				BuildIndependentTargetsInParallel = 1;
				LastSwiftUpdateCheck = 1600;
				LastUpgradeCheck = 1600;
			}};
			buildConfigurationList = {IDs["config_list_proj"]} /* Build configuration list for PBXProject "OrcaSlicer" */;
			compatibilityVersion = "Xcode 14.0";
			developmentRegion = en;
			hasScannedForEncodings = 0;
			knownRegions = (
				en,
				Base,
			);
			mainGroup = {IDs["group_main"]};
			productRefGroup = {IDs["group_products"]};
			projectDirPath = "";
			projectRoot = "";
			targets = (
				{IDs["target"]} /* OrcaSlicer */,
			);
		}};
/* End PBXProject section */

/* Begin PBXResourcesBuildPhase section */
		{IDs["resources"]} /* Resources */ = {{
			isa = PBXResourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
				{IDs["sample_stl"]} /* sample_cube_20mm.stl in Resources */,
			);
			runOnlyForDeploymentPostprocessing = 0;
		}};
/* End PBXResourcesBuildPhase section */

/* Begin PBXFrameworksBuildPhase section */
		{IDs["frameworks"]} /* Frameworks */ = {{
			isa = PBXFrameworksBuildPhase;
			buildActionMask = 2147483647;
			files = (
			);
			runOnlyForDeploymentPostprocessing = 0;
		}};
/* End PBXFrameworksBuildPhase section */

/* Begin PBXSourcesBuildPhase section */
		{IDs["sources"]} /* Sources */ = {{
			isa = PBXSourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
				{IDs["swift_app"]} /* OrcaSlicerApp.swift in Sources */,
				{IDs["swift_engine"]} /* OrcaEngine.swift in Sources */,
			);
			runOnlyForDeploymentPostprocessing = 0;
		}};
/* End PBXSourcesBuildPhase section */

/* Begin XCBuildConfiguration section */
		{IDs["debug_proj"]} /* Debug */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{
				ALWAYS_SEARCH_USER_PATHS = NO;
				CLANG_ENABLE_MODULES = YES;
				CLANG_ENABLE_OBJC_ARC = YES;
				IPHONEOS_DEPLOYMENT_TARGET = 16.0;
				MACOSX_DEPLOYMENT_TARGET = 13.0;
				ONLY_ACTIVE_ARCH = YES;
				SDKROOT = auto;
				SUPPORTED_PLATFORMS = "iphoneos iphonesimulator macosx";
			}};
			name = Debug;
		}};
		{IDs["release_proj"]} /* Release */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{
				ALWAYS_SEARCH_USER_PATHS = NO;
				CLANG_ENABLE_MODULES = YES;
				CLANG_ENABLE_OBJC_ARC = YES;
				IPHONEOS_DEPLOYMENT_TARGET = 16.0;
				MACOSX_DEPLOYMENT_TARGET = 13.0;
				SDKROOT = auto;
				SUPPORTED_PLATFORMS = "iphoneos iphonesimulator macosx";
			}};
			name = Release;
		}};
		{IDs["debug_tgt"]} /* Debug */ = {{
{tgt_settings("Debug")}
		}};
		{IDs["release_tgt"]} /* Release */ = {{
{tgt_settings("Release")}
		}};
/* End XCBuildConfiguration section */

/* Begin XCConfigurationList section */
		{IDs["config_list_proj"]} /* Build configuration list for PBXProject "OrcaSlicer" */ = {{
			isa = XCConfigurationList;
			buildConfigurations = (
				{IDs["debug_proj"]} /* Debug */,
				{IDs["release_proj"]} /* Release */,
			);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Release;
		}};
		{IDs["config_list_tgt"]} /* Build configuration list for PBXNativeTarget "OrcaSlicer" */ = {{
			isa = XCConfigurationList;
			buildConfigurations = (
				{IDs["debug_tgt"]} /* Debug */,
				{IDs["release_tgt"]} /* Release */,
			);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Release;
		}};
/* End XCConfigurationList section */
	}};
	rootObject = {IDs["project"]} /* Project object */;
}}
'''

(PROJ / "project.pbxproj").write_text(pbx)
print("Wrote", PROJ / "project.pbxproj")
print("has_mac_engine=", has_mac_engine)
print("has_ios_engine=", has_ios_engine)
