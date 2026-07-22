#!/usr/bin/env python3
"""Generate ios/BromureRemote/BromureRemote.xcodeproj — the runnable iOS app.

The SwiftPM package (ios/BromureRemote/Package.swift) is the compile-check
target; this script emits a real .xcodeproj app target that compiles the SAME
sources (the iOS-only files + the _shared symlink farm) in place and links the
five remote SwiftPM dependencies. Regenerate after adding/removing source files
or changing dependencies:

    python3 scripts/gen-ios-sources.py     # refresh the shared symlinks first
    python3 scripts/gen-ios-project.py     # then the project
    xcodebuild -project ios/BromureRemote/BromureRemote.xcodeproj \\
      -scheme BromureRemote -destination 'generic/platform=iOS Simulator' build

UUIDs are derived deterministically from stable keys so regeneration produces a
minimal diff.
"""
import hashlib
import os
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PKG = os.path.join(REPO, "ios", "BromureRemote")
SRC = os.path.join(PKG, "Sources", "BromureRemote")
PROJ = os.path.join(PKG, "BromureRemote.xcodeproj")

BUNDLE_ID = "io.bromure.remote"
DEPLOYMENT_TARGET = "17.0"

# (name, repo url, requirement kind, requirement value) — kept in lockstep with
# Package.swift.
PACKAGES = [
    ("swift-crypto", "https://github.com/apple/swift-crypto.git", "upToNextMajorVersion", "3.7.0"),
    ("swift-nio", "https://github.com/apple/swift-nio.git", "upToNextMajorVersion", "2.65.0"),
    ("swift-nio-ssh", "https://github.com/apple/swift-nio-ssh.git", "upToNextMajorVersion", "0.9.0"),
    ("swift-markdown-ui", "https://github.com/gonzalezreal/swift-markdown-ui.git", "upToNextMajorVersion", "2.4.0"),
    ("SwiftTerm", "https://github.com/migueldeicaza/SwiftTerm.git", "upToNextMajorVersion", "1.2.0"),
]
# (product, package name)
PRODUCTS = [
    ("Crypto", "swift-crypto"),
    ("NIOCore", "swift-nio"),
    ("NIOPosix", "swift-nio"),
    ("NIOSSH", "swift-nio-ssh"),
    ("MarkdownUI", "swift-markdown-ui"),
    ("SwiftTerm", "SwiftTerm"),
]

_used = set()


def uid(key):
    """A stable 24-hex-uppercase id from a key (Xcode object identifier)."""
    h = hashlib.sha1(key.encode()).hexdigest().upper()[:24]
    while h in _used:
        h = hashlib.sha1((key + "!").encode()).hexdigest().upper()[:24]
        key += "!"
    _used.add(h)
    return h


def swift_sources():
    files = []
    for root, _dirs, names in os.walk(SRC):
        for n in sorted(names):
            if n.endswith(".swift"):
                files.append(os.path.relpath(os.path.join(root, n), PKG))
    return sorted(files)


def main():
    sources = swift_sources()
    if not sources:
        print("no sources found — run gen-ios-sources.py first", file=sys.stderr)
        return 1

    # Object ids.
    proj_id = uid("project")
    main_group = uid("mainGroup")
    products_group = uid("productsGroup")
    src_group = uid("srcGroup")
    app_group = uid("appGroup")
    target_id = uid("target")
    product_ref = uid("productRef")
    sources_phase = uid("sourcesPhase")
    frameworks_phase = uid("frameworksPhase")
    resources_phase = uid("resourcesPhase")
    cfg_list_proj = uid("cfgListProj")
    cfg_list_tgt = uid("cfgListTgt")
    cfg_proj_debug = uid("cfgProjDebug")
    cfg_proj_release = uid("cfgProjRelease")
    cfg_tgt_debug = uid("cfgTgtDebug")
    cfg_tgt_release = uid("cfgTgtRelease")

    # Per-file refs + build files.
    file_refs = {}     # relpath -> fileRef id
    build_files = {}   # relpath -> buildFile id
    for rel in sources:
        file_refs[rel] = uid("fileRef:" + rel)
        build_files[rel] = uid("buildFile:" + rel)
    info_ref = uid("fileRef:App/Info.plist")
    assets_ref = uid("fileRef:App/Assets.xcassets")
    assets_build = uid("buildFile:App/Assets.xcassets")

    # Package refs + product deps.
    pkg_ref = {name: uid("pkgRef:" + name) for name, *_ in PACKAGES}
    prod_dep = {prod: uid("prodDep:" + prod) for prod, _ in PRODUCTS}
    prod_build = {prod: uid("prodBuild:" + prod) for prod, _ in PRODUCTS}

    L = []
    L.append("// !$*UTF8*$!")
    L.append("{")
    L.append("\tarchiveVersion = 1;")
    L.append("\tclasses = {};")
    L.append("\tobjectVersion = 56;")
    L.append("\tobjects = {")

    # PBXBuildFile (sources)
    L.append("\n/* Begin PBXBuildFile section */")
    for rel in sources:
        base = os.path.basename(rel)
        L.append(f"\t\t{build_files[rel]} /* {base} in Sources */ = {{isa = PBXBuildFile; fileRef = {file_refs[rel]} /* {base} */; }};")
    L.append(f"\t\t{assets_build} /* Assets.xcassets in Resources */ = {{isa = PBXBuildFile; fileRef = {assets_ref} /* Assets.xcassets */; }};")
    for prod, _ in PRODUCTS:
        L.append(f"\t\t{prod_build[prod]} /* {prod} */ = {{isa = PBXBuildFile; productRef = {prod_dep[prod]} /* {prod} */; }};")
    L.append("/* End PBXBuildFile section */")

    # PBXFileReference
    L.append("\n/* Begin PBXFileReference section */")
    for rel in sources:
        base = os.path.basename(rel)
        L.append(f'\t\t{file_refs[rel]} /* {base} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; name = "{base}"; path = "{rel}"; sourceTree = "<group>"; }};')
    L.append(f'\t\t{info_ref} /* Info.plist */ = {{isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = "App/Info.plist"; sourceTree = "<group>"; }};')
    L.append(f'\t\t{assets_ref} /* Assets.xcassets */ = {{isa = PBXFileReference; lastKnownFileType = folder.assetcatalog; path = "App/Assets.xcassets"; sourceTree = "<group>"; }};')
    L.append(f'\t\t{product_ref} /* BromureRemote.app */ = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = BromureRemote.app; sourceTree = BUILT_PRODUCTS_DIR; }};')
    L.append("/* End PBXFileReference section */")

    # PBXFrameworksBuildPhase
    L.append("\n/* Begin PBXFrameworksBuildPhase section */")
    L.append(f"\t\t{frameworks_phase} = {{")
    L.append("\t\t\tisa = PBXFrameworksBuildPhase;")
    L.append("\t\t\tbuildActionMask = 2147483647;")
    L.append("\t\t\tfiles = (")
    for prod, _ in PRODUCTS:
        L.append(f"\t\t\t\t{prod_build[prod]} /* {prod} */,")
    L.append("\t\t\t);")
    L.append("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
    L.append("\t\t};")
    L.append("/* End PBXFrameworksBuildPhase section */")

    # PBXGroup
    L.append("\n/* Begin PBXGroup section */")
    # main group
    L.append(f"\t\t{main_group} = {{")
    L.append("\t\t\tisa = PBXGroup;")
    L.append("\t\t\tchildren = (")
    L.append(f"\t\t\t\t{src_group} /* Sources */,")
    L.append(f"\t\t\t\t{app_group} /* App */,")
    L.append(f"\t\t\t\t{products_group} /* Products */,")
    L.append("\t\t\t);")
    L.append("\t\t\tsourceTree = \"<group>\";")
    L.append("\t\t};")
    # products
    L.append(f"\t\t{products_group} /* Products */ = {{")
    L.append("\t\t\tisa = PBXGroup;")
    L.append(f"\t\t\tchildren = (\n\t\t\t\t{product_ref} /* BromureRemote.app */,\n\t\t\t);")
    L.append("\t\t\tname = Products;")
    L.append("\t\t\tsourceTree = \"<group>\";")
    L.append("\t\t};")
    # sources group (flat)
    L.append(f"\t\t{src_group} /* Sources */ = {{")
    L.append("\t\t\tisa = PBXGroup;")
    L.append("\t\t\tchildren = (")
    for rel in sources:
        base = os.path.basename(rel)
        L.append(f"\t\t\t\t{file_refs[rel]} /* {base} */,")
    L.append("\t\t\t);")
    L.append("\t\t\tname = Sources;")
    L.append("\t\t\tsourceTree = \"<group>\";")
    L.append("\t\t};")
    # app group (Info.plist)
    L.append(f"\t\t{app_group} /* App */ = {{")
    L.append("\t\t\tisa = PBXGroup;")
    L.append(f"\t\t\tchildren = (\n\t\t\t\t{info_ref} /* Info.plist */,\n\t\t\t\t{assets_ref} /* Assets.xcassets */,\n\t\t\t);")
    L.append("\t\t\tname = App;")
    L.append("\t\t\tsourceTree = \"<group>\";")
    L.append("\t\t};")
    L.append("/* End PBXGroup section */")

    # PBXNativeTarget
    L.append("\n/* Begin PBXNativeTarget section */")
    L.append(f"\t\t{target_id} /* BromureRemote */ = {{")
    L.append("\t\t\tisa = PBXNativeTarget;")
    L.append(f"\t\t\tbuildConfigurationList = {cfg_list_tgt} /* Build configuration list for PBXNativeTarget */;")
    L.append("\t\t\tbuildPhases = (")
    L.append(f"\t\t\t\t{sources_phase} /* Sources */,")
    L.append(f"\t\t\t\t{frameworks_phase} /* Frameworks */,")
    L.append(f"\t\t\t\t{resources_phase} /* Resources */,")
    L.append("\t\t\t);")
    L.append("\t\t\tbuildRules = ();")
    L.append("\t\t\tdependencies = ();")
    L.append("\t\t\tname = BromureRemote;")
    L.append("\t\t\tpackageProductDependencies = (")
    for prod, _ in PRODUCTS:
        L.append(f"\t\t\t\t{prod_dep[prod]} /* {prod} */,")
    L.append("\t\t\t);")
    L.append("\t\t\tproductName = BromureRemote;")
    L.append(f"\t\t\tproductReference = {product_ref} /* BromureRemote.app */;")
    L.append("\t\t\tproductType = \"com.apple.product-type.application\";")
    L.append("\t\t};")
    L.append("/* End PBXNativeTarget section */")

    # PBXProject
    L.append("\n/* Begin PBXProject section */")
    L.append(f"\t\t{proj_id} /* Project object */ = {{")
    L.append("\t\t\tisa = PBXProject;")
    L.append("\t\t\tattributes = { LastSwiftUpdateCheck = 1600; LastUpgradeCheck = 1600; };")
    L.append(f"\t\t\tbuildConfigurationList = {cfg_list_proj} /* Build configuration list for PBXProject */;")
    L.append("\t\t\tcompatibilityVersion = \"Xcode 14.0\";")
    L.append("\t\t\tdevelopmentRegion = en;")
    L.append("\t\t\thasScannedForEncodings = 0;")
    L.append("\t\t\tknownRegions = ( en, Base );")
    L.append(f"\t\t\tmainGroup = {main_group};")
    L.append("\t\t\tpackageReferences = (")
    for name, *_ in PACKAGES:
        L.append(f"\t\t\t\t{pkg_ref[name]} /* {name} */,")
    L.append("\t\t\t);")
    L.append(f"\t\t\tproductRefGroup = {products_group} /* Products */;")
    L.append("\t\t\tprojectDirPath = \"\";")
    L.append("\t\t\tprojectRoot = \"\";")
    L.append(f"\t\t\ttargets = ( {target_id} /* BromureRemote */ );")
    L.append("\t\t};")
    L.append("/* End PBXProject section */")

    # PBXResourcesBuildPhase
    L.append("\n/* Begin PBXResourcesBuildPhase section */")
    L.append(f"\t\t{resources_phase} = {{")
    L.append("\t\t\tisa = PBXResourcesBuildPhase;")
    L.append("\t\t\tbuildActionMask = 2147483647;")
    L.append("\t\t\tfiles = (")
    L.append(f"\t\t\t\t{assets_build} /* Assets.xcassets in Resources */,")
    L.append("\t\t\t);")
    L.append("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
    L.append("\t\t};")
    L.append("/* End PBXResourcesBuildPhase section */")

    # PBXSourcesBuildPhase
    L.append("\n/* Begin PBXSourcesBuildPhase section */")
    L.append(f"\t\t{sources_phase} = {{")
    L.append("\t\t\tisa = PBXSourcesBuildPhase;")
    L.append("\t\t\tbuildActionMask = 2147483647;")
    L.append("\t\t\tfiles = (")
    for rel in sources:
        base = os.path.basename(rel)
        L.append(f"\t\t\t\t{build_files[rel]} /* {base} in Sources */,")
    L.append("\t\t\t);")
    L.append("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
    L.append("\t\t};")
    L.append("/* End PBXSourcesBuildPhase section */")

    # XCBuildConfiguration
    common = [
        "CLANG_ENABLE_MODULES = YES;",
        "SWIFT_VERSION = 5.9;",
        f"IPHONEOS_DEPLOYMENT_TARGET = {DEPLOYMENT_TARGET};",
        "SDKROOT = iphoneos;",
        "TARGETED_DEVICE_FAMILY = \"1,2\";",
        "ENABLE_PREVIEWS = YES;",
    ]
    proj_debug = common + ["ONLY_ACTIVE_ARCH = YES;", "SWIFT_OPTIMIZATION_LEVEL = \"-Onone\";", "GCC_OPTIMIZATION_LEVEL = 0;", "DEBUG_INFORMATION_FORMAT = dwarf;", "SWIFT_ACTIVE_COMPILATION_CONDITIONS = \"DEBUG BROMURE_APP\";"]
    proj_release = common + ["SWIFT_OPTIMIZATION_LEVEL = \"-O\";", "SWIFT_COMPILATION_MODE = wholemodule;", "DEBUG_INFORMATION_FORMAT = \"dwarf-with-dsym\";", "SWIFT_ACTIVE_COMPILATION_CONDITIONS = BROMURE_APP;"]
    tgt_common = [
        "PRODUCT_NAME = \"$(TARGET_NAME)\";",
        f"PRODUCT_BUNDLE_IDENTIFIER = {BUNDLE_ID};",
        "INFOPLIST_FILE = App/Info.plist;",
        "CODE_SIGN_STYLE = Automatic;",
        "DEVELOPMENT_TEAM = W3RD8G85BC;",
        "GENERATE_INFOPLIST_FILE = NO;",
        "CURRENT_PROJECT_VERSION = 1;",
        "MARKETING_VERSION = 1.0;",
        "SWIFT_EMIT_LOC_STRINGS = YES;",
        "ENABLE_USER_SCRIPT_SANDBOXING = YES;",
        "CODE_SIGN_ENTITLEMENTS = App/BromureRemote.entitlements;",
        "ASSETCATALOG_COMPILER_GENERATE_ASSET_SYMBOLS = NO;",
        "ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;",
    ]

    def cfg(cid, name, settings):
        out = [f"\t\t{cid} /* {name} */ = {{"]
        out.append("\t\t\tisa = XCBuildConfiguration;")
        out.append("\t\t\tbuildSettings = {")
        for s in settings:
            out.append(f"\t\t\t\t{s}")
        out.append("\t\t\t};")
        out.append(f"\t\t\tname = {name};")
        out.append("\t\t};")
        return out

    L.append("\n/* Begin XCBuildConfiguration section */")
    L += cfg(cfg_proj_debug, "Debug", proj_debug)
    L += cfg(cfg_proj_release, "Release", proj_release)
    L += cfg(cfg_tgt_debug, "Debug", tgt_common)
    L += cfg(cfg_tgt_release, "Release", tgt_common)
    L.append("/* End XCBuildConfiguration section */")

    # XCConfigurationList
    L.append("\n/* Begin XCConfigurationList section */")
    for cid, name, a, b in [
        (cfg_list_proj, "PBXProject", cfg_proj_debug, cfg_proj_release),
        (cfg_list_tgt, "PBXNativeTarget", cfg_tgt_debug, cfg_tgt_release),
    ]:
        L.append(f"\t\t{cid} /* Build configuration list for {name} */ = {{")
        L.append("\t\t\tisa = XCConfigurationList;")
        L.append(f"\t\t\tbuildConfigurations = (\n\t\t\t\t{a} /* Debug */,\n\t\t\t\t{b} /* Release */,\n\t\t\t);")
        L.append("\t\t\tdefaultConfigurationIsVisible = 0;")
        L.append("\t\t\tdefaultConfigurationName = Release;")
        L.append("\t\t};")
    L.append("/* End XCConfigurationList section */")

    # XCRemoteSwiftPackageReference
    L.append("\n/* Begin XCRemoteSwiftPackageReference section */")
    for name, url, kind, value in PACKAGES:
        L.append(f'\t\t{pkg_ref[name]} /* {name} */ = {{')
        L.append("\t\t\tisa = XCRemoteSwiftPackageReference;")
        L.append(f'\t\t\trepositoryURL = "{url}";')
        L.append("\t\t\trequirement = {")
        L.append(f"\t\t\t\tkind = {kind};")
        L.append(f'\t\t\t\tminimumVersion = {value};')
        L.append("\t\t\t};")
        L.append("\t\t};")
    L.append("/* End XCRemoteSwiftPackageReference section */")

    # XCSwiftPackageProductDependency
    L.append("\n/* Begin XCSwiftPackageProductDependency section */")
    for prod, pkgname in PRODUCTS:
        L.append(f"\t\t{prod_dep[prod]} /* {prod} */ = {{")
        L.append("\t\t\tisa = XCSwiftPackageProductDependency;")
        L.append(f"\t\t\tpackage = {pkg_ref[pkgname]} /* {pkgname} */;")
        L.append(f"\t\t\tproductName = {prod};")
        L.append("\t\t};")
    L.append("/* End XCSwiftPackageProductDependency section */")

    L.append("\t};")
    L.append(f"\trootObject = {proj_id} /* Project object */;")
    L.append("}")

    os.makedirs(PROJ, exist_ok=True)
    with open(os.path.join(PROJ, "project.pbxproj"), "w") as f:
        f.write("\n".join(L) + "\n")
    print(f"wrote {os.path.relpath(PROJ, REPO)} ({len(sources)} sources, {len(PRODUCTS)} linked products)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
