#!/usr/bin/env python3
"""Generate Xcode project for OrcaSlicer iOS/macOS host (official libslic3r via C ABI)."""
from pathlib import Path
import uuid
import os

ROOT = Path(__file__).resolve().parent
REPO = ROOT.parent
APP = ROOT / "OrcaSlicerApp"
PROJ = ROOT / "OrcaSlicer.xcodeproj"
PROJ.mkdir(exist_ok=True)

# Prefer combined engine bundle (macOS arm64 headless build)
ENGINE_MAC = REPO / "build-macos-headless-arm64" / "engine_bundle" / "lib"
ENGINE_IOS = REPO / "build-ios-iphonesimulator-arm64" / "engine_bundle" / "lib"
HEADER = REPO / "src" / "ios"

has_mac_engine = (ENGINE_MAC / "liborca_engine.a").is_file()
has_ios_engine = (ENGINE_IOS / "liborca_engine.a").is_file()

def uid():
    return uuid.uuid4().hex[:24].upper()

IDs = {
    "project": uid(),
    "target": uid(),
    "sources": uid(),
    "resources": uid(),
    "frameworks": uid(),
    "product": uid(),
    "swift_app": uid(),
    "swift_engine": uid(),
    "sample_stl": uid(),
    "config_list_proj": uid(),
    "config_list_tgt": uid(),
    "debug_proj": uid(),
    "release_proj": uid(),
    "debug_tgt": uid(),
    "release_tgt": uid(),
    "group_main": uid(),
    "group_app": uid(),
    "group_products": uid(),
}

# Relative from ios/ project dir
mac_lib_path = "$(SRCROOT)/../build-macos-headless-arm64/engine_bundle/lib"
ios_lib_path = "$(SRCROOT)/../build-ios-iphonesimulator-arm64/engine_bundle/lib"
hdr_path = "$(SRCROOT)/../src/ios"

# When mac engine exists, enable ORCA_LINKED for macOS SDK builds.
# iOS SDK enables when iOS engine exists.
common_linked_flags = (
    "-force_load $(ENGINE_LIB_DIR)/liborca_engine.a "
    "-lc++ -lz -liconv "
    "-framework Foundation -framework ModelIO -framework IOKit "
    "-framework CoreFoundation -framework Security -framework SystemConfiguration -lexpat -lpng -lexpat -lpng"
)

def tgt_settings(name, linked_default):
    # ENGINE_LIB_DIR is set per-SDK via conditional; use mac path as default for multiplatform My Mac
    eng = mac_lib_path if has_mac_engine else ios_lib_path
    conditions = []
    if has_mac_engine or has_ios_engine:
        conditions.append("ORCA_LINKED")
    cond_str = " ".join(conditions) if conditions else ""
    ldflags = common_linked_flags if (has_mac_engine or has_ios_engine) else ""
    lib_search = f'"{eng}"' if (has_mac_engine or has_ios_engine) else '""'
    return f'''
			isa = XCBuildConfiguration;
			buildSettings = {{
				ALWAYS_SEARCH_USER_PATHS = NO;
				ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;
				CLANG_ENABLE_MODULES = YES;
				CLANG_ENABLE_OBJC_ARC = YES;
				CODE_SIGN_STYLE = Automatic;
				CURRENT_PROJECT_VERSION = 1;
				DEVELOPMENT_TEAM = "";
				ENABLE_PREVIEWS = YES;
				ENGINE_LIB_DIR = "{eng}";
				GENERATE_INFOPLIST_FILE = NO;
				HEADER_SEARCH_PATHS = (
					"{hdr_path}",
					"$(inherited)",
				);
				INFOPLIST_FILE = OrcaSlicerApp/Info.plist;
				INFOPLIST_KEY_UIApplicationSceneManifest_Generation = YES;
				IPHONEOS_DEPLOYMENT_TARGET = 16.0;
				LD_RUNPATH_SEARCH_PATHS = (
					"$(inherited)",
					"@executable_path/Frameworks",
				);
				LIBRARY_SEARCH_PATHS = (
					{lib_search},
					"$(inherited)",
				);
				MACOSX_DEPLOYMENT_TARGET = 13.0;
				MARKETING_VERSION = 2.5.0;
				OTHER_LDFLAGS = (
					"$(inherited)",
					{('"' + ldflags + '"') if ldflags else '""'},
				);
				PRODUCT_BUNDLE_IDENTIFIER = com.orcaslicer.ios;
				PRODUCT_NAME = "$(TARGET_NAME)";
				SUPPORTED_PLATFORMS = "iphoneos iphonesimulator macosx";
				SUPPORTS_MACCATALYST = NO;
				SWIFT_ACTIVE_COMPILATION_CONDITIONS = "{cond_str}";
				SWIFT_EMIT_LOC_STRINGS = YES;
				SWIFT_OBJC_BRIDGING_HEADER = "OrcaSlicerApp/Bridging-Header.h";
				SWIFT_VERSION = 5.0;
				TARGETED_DEVICE_FAMILY = "1,2,6";
			}};
			name = {name};
'''

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
		{IDs["debug_tgt"]} /* Debug */ = {{{tgt_settings("Debug", has_mac_engine)}
		}};
		{IDs["release_tgt"]} /* Release */ = {{{tgt_settings("Release", has_mac_engine)}
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
