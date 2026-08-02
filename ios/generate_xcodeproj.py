#!/usr/bin/env python3
"""Generate a minimal Xcode project for OrcaSlicer iOS host (official tree)."""
from pathlib import Path
import uuid

ROOT = Path(__file__).resolve().parent
APP = ROOT / "OrcaSlicerApp"
PROJ = ROOT / "OrcaSlicer.xcodeproj"
PROJ.mkdir(exist_ok=True)

def uid():
    return uuid.uuid4().hex[:24].upper()

# Fixed IDs for stability
IDs = {
    "project": uid(),
    "target": uid(),
    "sources": uid(),
    "resources": uid(),
    "frameworks": uid(),
    "product": uid(),
    "swift_app": uid(),
    "swift_engine": uid(),
    "plist": uid(),
    "bridge": uid(),
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

pbx = f'''// !$*UTF8*$!
{{
	archiveVersion = 1;
	classes = {{}};
	objectVersion = 56;
	objects = {{

/* Begin PBXBuildFile section */
		{IDs["swift_app"]} /* OrcaSlicerApp.swift in Sources */ = {{isa = PBXBuildFile; fileRef = A10000000000000000000001 /* OrcaSlicerApp.swift */; }};
		{IDs["swift_engine"]} /* OrcaEngine.swift in Sources */ = {{isa = PBXBuildFile; fileRef = A10000000000000000000002 /* OrcaEngine.swift */; }};
/* End PBXBuildFile section */

/* Begin PBXFileReference section */
		A10000000000000000000001 /* OrcaSlicerApp.swift */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = OrcaSlicerApp.swift; sourceTree = "<group>"; }};
		A10000000000000000000002 /* OrcaEngine.swift */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = OrcaEngine.swift; sourceTree = "<group>"; }};
		A10000000000000000000003 /* Info.plist */ = {{isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = Info.plist; sourceTree = "<group>"; }};
		A10000000000000000000004 /* Bridging-Header.h */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.c.h; path = "Bridging-Header.h"; sourceTree = "<group>"; }};
		{IDs["product"]} /* OrcaSlicer.app */ = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = OrcaSlicer.app; sourceTree = BUILT_PRODUCTS_DIR; }};
/* End PBXFileReference section */

/* Begin PBXGroup section */
		{IDs["group_main"]} = {{
			isa = PBXGroup;
			children = (
				{IDs["group_app"]},
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
				ONLY_ACTIVE_ARCH = YES;
				SDKROOT = iphoneos;
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
				SDKROOT = iphoneos;
			}};
			name = Release;
		}};
		{IDs["debug_tgt"]} /* Debug */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{
				ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;
				CODE_SIGN_STYLE = Automatic;
				CURRENT_PROJECT_VERSION = 1;
				DEVELOPMENT_TEAM = "";
				ENABLE_PREVIEWS = YES;
				GENERATE_INFOPLIST_FILE = NO;
				INFOPLIST_FILE = OrcaSlicerApp/Info.plist;
				INFOPLIST_KEY_UIApplicationSceneManifest_Generation = YES;
				LD_RUNPATH_SEARCH_PATHS = (
					"$(inherited)",
					"@executable_path/Frameworks",
				);
				MARKETING_VERSION = 2.5.0;
				PRODUCT_BUNDLE_IDENTIFIER = com.orcaslicer.ios;
				PRODUCT_NAME = "$(TARGET_NAME)";
				SWIFT_EMIT_LOC_STRINGS = YES;
				SWIFT_VERSION = 5.0;
				TARGETED_DEVICE_FAMILY = "1,2";
				SWIFT_OBJC_BRIDGING_HEADER = "OrcaSlicerApp/Bridging-Header.h";
				HEADER_SEARCH_PATHS = (
					"$(SRCROOT)/../src/ios",
					"$(inherited)",
				);
				// After cmake builds orca_ios_api + libslic3r for iOS, add:
				// LIBRARY_SEARCH_PATHS, OTHER_LDFLAGS = -lorca_ios_api -lslic3r ...
				// SWIFT_ACTIVE_COMPILATION_CONDITIONS = ORCA_LINKED
			}};
			name = Debug;
		}};
		{IDs["release_tgt"]} /* Release */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{
				CODE_SIGN_STYLE = Automatic;
				CURRENT_PROJECT_VERSION = 1;
				GENERATE_INFOPLIST_FILE = NO;
				INFOPLIST_FILE = OrcaSlicerApp/Info.plist;
				LD_RUNPATH_SEARCH_PATHS = (
					"$(inherited)",
					"@executable_path/Frameworks",
				);
				MARKETING_VERSION = 2.5.0;
				PRODUCT_BUNDLE_IDENTIFIER = com.orcaslicer.ios;
				PRODUCT_NAME = "$(TARGET_NAME)";
				SWIFT_VERSION = 5.0;
				TARGETED_DEVICE_FAMILY = "1,2";
				SWIFT_OBJC_BRIDGING_HEADER = "OrcaSlicerApp/Bridging-Header.h";
				HEADER_SEARCH_PATHS = (
					"$(SRCROOT)/../src/ios",
					"$(inherited)",
				);
			}};
			name = Release;
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
