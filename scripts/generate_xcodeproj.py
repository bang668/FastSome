#!/usr/bin/env python3
"""Generate a minimal FastSome.xcodeproj/project.pbxproj."""

from __future__ import annotations

import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def uid() -> str:
    return uuid.uuid4().hex[:24].upper()


SWIFT_FILES = [
    "FastSomeApp.swift",
    "AppState.swift",
    "Models/ShortcutModels.swift",
    "Store/LibraryStore.swift",
    "Store/AppSettings.swift",
    "Services/Launcher.swift",
    "Services/HotKeyManager.swift",
    "Services/LoginItemService.swift",
    "Services/SettingsOpener.swift",
    "Services/AppActivation.swift",
    "Services/DockIconLocator.swift",
    "Services/DesktopSwipe/DesktopSwipeGesture.swift",
    "Services/DesktopSwipe/DesktopSwipeMonitor.swift",
    "Services/DesktopSwipe/DesktopSwipeTrail.swift",
    "Services/DesktopSwipe/DesktopSwipeController.swift",
    "Controllers/AppDelegate.swift",
    "Controllers/StatusItemController.swift",
    "Controllers/PanelController.swift",
    "Views/PanelView.swift",
    "Views/SettingsRootView.swift",
    "Views/RenameGroupPrompt.swift",
    "Views/ConfirmPrompt.swift",
    "Views/EdgeResizeOverlay.swift",
]


def main() -> None:
    project = uid()
    target = uid()
    tests = uid()
    sources = uid()
    resources = uid()
    frameworks = uid()
    tests_sources = uid()
    tests_frameworks = uid()
    products = uid()
    app_product = uid()
    tests_product = uid()
    group_root = uid()
    group_app = uid()
    group_models = uid()
    group_store = uid()
    group_services = uid()
    group_swipe = uid()
    group_controllers = uid()
    group_views = uid()
    group_tests = uid()
    group_products = uid()
    dep = uid()
    container = uid()

    project_configs = uid()
    target_configs = uid()
    tests_configs = uid()
    project_debug = uid()
    project_release = uid()
    target_debug = uid()
    target_release = uid()
    tests_debug = uid()
    tests_release = uid()

    plist = uid()
    assets = uid()
    assets_build = uid()
    entitlements = uid()
    test_file = uid()
    test_build = uid()
    swipe_test_file = uid()
    swipe_test_build = uid()

    file_ids: dict[str, str] = {}
    build_ids: dict[str, str] = {}
    for path in SWIFT_FILES:
        file_ids[path] = uid()
        build_ids[path] = uid()

    def basenames(paths: list[str]) -> str:
        return "\n".join(
            f"\t\t\t\t{file_ids[p]} /* {Path(p).name} */," for p in paths
        )

    build_file_lines = "\n".join(
        f"\t\t{build_ids[p]} /* {Path(p).name} in Sources */ = "
        f"{{isa = PBXBuildFile; fileRef = {file_ids[p]} /* {Path(p).name} */; }};"
        for p in SWIFT_FILES
    )
    build_file_lines += (
        f"\n\t\t{assets_build} /* Assets.xcassets in Resources */ = "
        f"{{isa = PBXBuildFile; fileRef = {assets} /* Assets.xcassets */; }};"
    )
    build_file_lines += (
        f"\n\t\t{test_build} /* LibraryStoreTests.swift in Sources */ = "
        f"{{isa = PBXBuildFile; fileRef = {test_file} /* LibraryStoreTests.swift */; }};"
        f"\n\t\t{swipe_test_build} /* DesktopSwipeGestureTests.swift in Sources */ = "
        f"{{isa = PBXBuildFile; fileRef = {swipe_test_file} /* DesktopSwipeGestureTests.swift */; }};"
    )

    file_ref_lines = [
        f"\t\t{app_product} /* FastSome.app */ = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = FastSome.app; sourceTree = BUILT_PRODUCTS_DIR; }};",
        f"\t\t{tests_product} /* FastSomeTests.xctest */ = {{isa = PBXFileReference; explicitFileType = wrapper.cfbundle; includeInIndex = 0; path = FastSomeTests.xctest; sourceTree = BUILT_PRODUCTS_DIR; }};",
    ]
    for path in SWIFT_FILES:
        name = Path(path).name
        file_ref_lines.append(
            f"\t\t{file_ids[path]} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {name}; sourceTree = \"<group>\"; }};"
        )
    file_ref_lines.extend(
        [
            f"\t\t{plist} /* Info.plist */ = {{isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = Info.plist; sourceTree = \"<group>\"; }};",
            f"\t\t{assets} /* Assets.xcassets */ = {{isa = PBXFileReference; lastKnownFileType = folder.assetcatalog; path = Assets.xcassets; sourceTree = \"<group>\"; }};",
            f"\t\t{entitlements} /* FastSome.entitlements */ = {{isa = PBXFileReference; lastKnownFileType = text.plist.entitlements; path = FastSome.entitlements; sourceTree = \"<group>\"; }};",
            f"\t\t{test_file} /* LibraryStoreTests.swift */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = LibraryStoreTests.swift; sourceTree = \"<group>\"; }};",
            f"\t\t{swipe_test_file} /* DesktopSwipeGestureTests.swift */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = DesktopSwipeGestureTests.swift; sourceTree = \"<group>\"; }};",
        ]
    )

    sources_list = "\n".join(
        f"\t\t\t\t{build_ids[p]} /* {Path(p).name} in Sources */," for p in SWIFT_FILES
    )

    root_swift = [p for p in SWIFT_FILES if "/" not in p]
    models = [p for p in SWIFT_FILES if p.startswith("Models/")]
    store = [p for p in SWIFT_FILES if p.startswith("Store/")]
    services = [p for p in SWIFT_FILES if p.startswith("Services/") and p.count("/") == 1]
    swipe = [p for p in SWIFT_FILES if p.startswith("Services/DesktopSwipe/")]
    controllers = [p for p in SWIFT_FILES if p.startswith("Controllers/")]
    views = [p for p in SWIFT_FILES if p.startswith("Views/")]

    pbx = f"""// !$*UTF8*$!
{{
	archiveVersion = 1;
	classes = {{
	}};
	objectVersion = 56;
	objects = {{

/* Begin PBXBuildFile section */
{build_file_lines}
/* End PBXBuildFile section */

/* Begin PBXContainerItemProxy section */
		{container} /* PBXContainerItemProxy */ = {{
			isa = PBXContainerItemProxy;
			containerPortal = {project} /* Project object */;
			proxyType = 1;
			remoteGlobalIDString = {target};
			remoteInfo = FastSome;
		}};
/* End PBXContainerItemProxy section */

/* Begin PBXFileReference section */
{chr(10).join(file_ref_lines)}
/* End PBXFileReference section */

/* Begin PBXFrameworksBuildPhase section */
		{frameworks} /* Frameworks */ = {{
			isa = PBXFrameworksBuildPhase;
			buildActionMask = 2147483647;
			files = (
			);
			runOnlyForDeploymentPostprocessing = 0;
		}};
		{tests_frameworks} /* Frameworks */ = {{
			isa = PBXFrameworksBuildPhase;
			buildActionMask = 2147483647;
			files = (
			);
			runOnlyForDeploymentPostprocessing = 0;
		}};
/* End PBXFrameworksBuildPhase section */

/* Begin PBXGroup section */
		{group_root} = {{
			isa = PBXGroup;
			children = (
				{group_app} /* FastSome */,
				{group_tests} /* FastSomeTests */,
				{group_products} /* Products */,
			);
			sourceTree = "<group>";
		}};
		{group_products} /* Products */ = {{
			isa = PBXGroup;
			children = (
				{app_product} /* FastSome.app */,
				{tests_product} /* FastSomeTests.xctest */,
			);
			name = Products;
			sourceTree = "<group>";
		}};
		{group_app} /* FastSome */ = {{
			isa = PBXGroup;
			children = (
{basenames(root_swift)}
				{group_models} /* Models */,
				{group_store} /* Store */,
				{group_services} /* Services */,
				{group_controllers} /* Controllers */,
				{group_views} /* Views */,
				{assets} /* Assets.xcassets */,
				{plist} /* Info.plist */,
				{entitlements} /* FastSome.entitlements */,
			);
			path = FastSome;
			sourceTree = "<group>";
		}};
		{group_models} /* Models */ = {{
			isa = PBXGroup;
			children = (
{basenames(models)}
			);
			path = Models;
			sourceTree = "<group>";
		}};
		{group_store} /* Store */ = {{
			isa = PBXGroup;
			children = (
{basenames(store)}
			);
			path = Store;
			sourceTree = "<group>";
		}};
		{group_services} /* Services */ = {{
			isa = PBXGroup;
			children = (
{basenames(services)}
				{group_swipe} /* DesktopSwipe */,
			);
			path = Services;
			sourceTree = "<group>";
		}};
		{group_swipe} /* DesktopSwipe */ = {{
			isa = PBXGroup;
			children = (
{basenames(swipe)}
			);
			path = DesktopSwipe;
			sourceTree = "<group>";
		}};
		{group_controllers} /* Controllers */ = {{
			isa = PBXGroup;
			children = (
{basenames(controllers)}
			);
			path = Controllers;
			sourceTree = "<group>";
		}};
		{group_views} /* Views */ = {{
			isa = PBXGroup;
			children = (
{basenames(views)}
			);
			path = Views;
			sourceTree = "<group>";
		}};
		{group_tests} /* FastSomeTests */ = {{
			isa = PBXGroup;
			children = (
				{test_file} /* LibraryStoreTests.swift */,
				{swipe_test_file} /* DesktopSwipeGestureTests.swift */,
			);
			path = FastSomeTests;
			sourceTree = "<group>";
		}};
/* End PBXGroup section */

/* Begin PBXNativeTarget section */
		{target} /* FastSome */ = {{
			isa = PBXNativeTarget;
			buildConfigurationList = {target_configs} /* Build configuration list for PBXNativeTarget "FastSome" */;
			buildPhases = (
				{sources} /* Sources */,
				{frameworks} /* Frameworks */,
				{resources} /* Resources */,
			);
			buildRules = (
			);
			dependencies = (
			);
			name = FastSome;
			productName = FastSome;
			productReference = {app_product} /* FastSome.app */;
			productType = "com.apple.product-type.application";
		}};
		{tests} /* FastSomeTests */ = {{
			isa = PBXNativeTarget;
			buildConfigurationList = {tests_configs} /* Build configuration list for PBXNativeTarget "FastSomeTests" */;
			buildPhases = (
				{tests_sources} /* Sources */,
				{tests_frameworks} /* Frameworks */,
			);
			buildRules = (
			);
			dependencies = (
				{dep} /* PBXTargetDependency */,
			);
			name = FastSomeTests;
			productName = FastSomeTests;
			productReference = {tests_product} /* FastSomeTests.xctest */;
			productType = "com.apple.product-type.bundle.unit-test";
		}};
/* End PBXNativeTarget section */

/* Begin PBXProject section */
		{project} /* Project object */ = {{
			isa = PBXProject;
			attributes = {{
				BuildIndependentTargetsInParallel = 1;
				LastSwiftUpdateCheck = 1600;
				LastUpgradeCheck = 1600;
				TargetAttributes = {{
					{target} = {{
						CreatedOnToolsVersion = 16.0;
					}};
					{tests} = {{
						CreatedOnToolsVersion = 16.0;
						TestTargetID = {target};
					}};
				}};
			}};
			buildConfigurationList = {project_configs} /* Build configuration list for PBXProject "FastSome" */;
			compatibilityVersion = "Xcode 14.0";
			developmentRegion = en;
			hasScannedForEncodings = 0;
			knownRegions = (
				en,
				Base,
				"zh-Hans",
			);
			mainGroup = {group_root};
			productRefGroup = {group_products} /* Products */;
			projectDirPath = "";
			projectRoot = "";
			targets = (
				{target} /* FastSome */,
				{tests} /* FastSomeTests */,
			);
		}};
/* End PBXProject section */

/* Begin PBXResourcesBuildPhase section */
		{resources} /* Resources */ = {{
			isa = PBXResourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
				{assets_build} /* Assets.xcassets in Resources */,
			);
			runOnlyForDeploymentPostprocessing = 0;
		}};
/* End PBXResourcesBuildPhase section */

/* Begin PBXSourcesBuildPhase section */
		{sources} /* Sources */ = {{
			isa = PBXSourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
{sources_list}
			);
			runOnlyForDeploymentPostprocessing = 0;
		}};
		{tests_sources} /* Sources */ = {{
			isa = PBXSourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
				{test_build} /* LibraryStoreTests.swift in Sources */,
				{swipe_test_build} /* DesktopSwipeGestureTests.swift in Sources */,
			);
			runOnlyForDeploymentPostprocessing = 0;
		}};
/* End PBXSourcesBuildPhase section */

/* Begin PBXTargetDependency section */
		{dep} /* PBXTargetDependency */ = {{
			isa = PBXTargetDependency;
			target = {target} /* FastSome */;
			targetProxy = {container} /* PBXContainerItemProxy */;
		}};
/* End PBXTargetDependency section */

/* Begin XCBuildConfiguration section */
		{project_debug} /* Debug */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{
				ALWAYS_SEARCH_USER_PATHS = NO;
				CLANG_ENABLE_MODULES = YES;
				CLANG_ENABLE_OBJC_ARC = YES;
				COPY_PHASE_STRIP = NO;
				DEBUG_INFORMATION_FORMAT = dwarf;
				ENABLE_TESTABILITY = YES;
				GCC_DYNAMIC_NO_PIC = NO;
				MACOSX_DEPLOYMENT_TARGET = 14.0;
				ONLY_ACTIVE_ARCH = YES;
				SDKROOT = macosx;
				SWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG;
				SWIFT_OPTIMIZATION_LEVEL = "-Onone";
			}};
			name = Debug;
		}};
		{project_release} /* Release */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{
				ALWAYS_SEARCH_USER_PATHS = NO;
				CLANG_ENABLE_MODULES = YES;
				CLANG_ENABLE_OBJC_ARC = YES;
				COPY_PHASE_STRIP = NO;
				DEBUG_INFORMATION_FORMAT = "dwarf-with-dsym";
				MACOSX_DEPLOYMENT_TARGET = 14.0;
				SDKROOT = macosx;
				SWIFT_COMPILATION_MODE = wholemodule;
			}};
			name = Release;
		}};
		{target_debug} /* Debug */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{
				ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;
				CODE_SIGN_ENTITLEMENTS = FastSome/FastSome.entitlements;
				CODE_SIGN_STYLE = Automatic;
				COMBINE_HIDPI_IMAGES = YES;
				CURRENT_PROJECT_VERSION = 1;
				ENABLE_HARDENED_RUNTIME = YES;
				GENERATE_INFOPLIST_FILE = NO;
				INFOPLIST_FILE = FastSome/Info.plist;
				LD_RUNPATH_SEARCH_PATHS = (
					"$(inherited)",
					"@executable_path/../Frameworks",
				);
				MARKETING_VERSION = 1.0.2;
				PRODUCT_BUNDLE_IDENTIFIER = com.fastsome.app;
				PRODUCT_NAME = "$(TARGET_NAME)";
				SWIFT_EMIT_LOC_STRINGS = YES;
				SWIFT_VERSION = 5.0;
			}};
			name = Debug;
		}};
		{target_release} /* Release */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{
				ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;
				CODE_SIGN_ENTITLEMENTS = FastSome/FastSome.entitlements;
				CODE_SIGN_STYLE = Automatic;
				COMBINE_HIDPI_IMAGES = YES;
				CURRENT_PROJECT_VERSION = 1;
				ENABLE_HARDENED_RUNTIME = YES;
				GENERATE_INFOPLIST_FILE = NO;
				INFOPLIST_FILE = FastSome/Info.plist;
				LD_RUNPATH_SEARCH_PATHS = (
					"$(inherited)",
					"@executable_path/../Frameworks",
				);
				MARKETING_VERSION = 1.0.2;
				PRODUCT_BUNDLE_IDENTIFIER = com.fastsome.app;
				PRODUCT_NAME = "$(TARGET_NAME)";
				SWIFT_EMIT_LOC_STRINGS = YES;
				SWIFT_VERSION = 5.0;
			}};
			name = Release;
		}};
		{tests_debug} /* Debug */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{
				BUNDLE_LOADER = "$(TEST_HOST)";
				CODE_SIGN_STYLE = Automatic;
				CURRENT_PROJECT_VERSION = 1;
				GENERATE_INFOPLIST_FILE = YES;
				MACOSX_DEPLOYMENT_TARGET = 14.0;
				MARKETING_VERSION = 1.0.2;
				PRODUCT_BUNDLE_IDENTIFIER = com.fastsome.app.tests;
				PRODUCT_NAME = "$(TARGET_NAME)";
				SWIFT_VERSION = 5.0;
				TEST_HOST = "$(BUILT_PRODUCTS_DIR)/FastSome.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/FastSome";
			}};
			name = Debug;
		}};
		{tests_release} /* Release */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{
				BUNDLE_LOADER = "$(TEST_HOST)";
				CODE_SIGN_STYLE = Automatic;
				CURRENT_PROJECT_VERSION = 1;
				GENERATE_INFOPLIST_FILE = YES;
				MACOSX_DEPLOYMENT_TARGET = 14.0;
				MARKETING_VERSION = 1.0.2;
				PRODUCT_BUNDLE_IDENTIFIER = com.fastsome.app.tests;
				PRODUCT_NAME = "$(TARGET_NAME)";
				SWIFT_VERSION = 5.0;
				TEST_HOST = "$(BUILT_PRODUCTS_DIR)/FastSome.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/FastSome";
			}};
			name = Release;
		}};
/* End XCBuildConfiguration section */

/* Begin XCConfigurationList section */
		{project_configs} /* Build configuration list for PBXProject "FastSome" */ = {{
			isa = XCConfigurationList;
			buildConfigurations = (
				{project_debug} /* Debug */,
				{project_release} /* Release */,
			);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Release;
		}};
		{target_configs} /* Build configuration list for PBXNativeTarget "FastSome" */ = {{
			isa = XCConfigurationList;
			buildConfigurations = (
				{target_debug} /* Debug */,
				{target_release} /* Release */,
			);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Release;
		}};
		{tests_configs} /* Build configuration list for PBXNativeTarget "FastSomeTests" */ = {{
			isa = XCConfigurationList;
			buildConfigurations = (
				{tests_debug} /* Debug */,
				{tests_release} /* Release */,
			);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Release;
		}};
/* End XCConfigurationList section */
	}};
	rootObject = {project} /* Project object */;
}}
"""

    out = ROOT / "FastSome.xcodeproj" / "project.pbxproj"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(pbx)
    print(f"Wrote {out}")


if __name__ == "__main__":
    main()
