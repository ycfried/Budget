#!/usr/bin/env python3
"""Validate the OnBudget clone project graph without building anything.

Parses ios-clone/OnBudget.xcodeproj/project.pbxproj with plutil (macOS)
and checks the invariants the scaffold must hold:
- every 24-hex object reference resolves
- every Swift source file on disk under OnBudget/, OnBudgetTests/
  and OnBudgetUITests/ is a file reference in the project (a new
  file committed without a pbxproj entry fails only at compile)
- exactly the three expected targets exist
  (OnBudget, OnBudgetTests, OnBudgetUITests)
- project configs disable code signing, name no development team,
  and pin the iOS 18.0 deployment target
- exactly one local Swift package reference, pointing at OnBudgetKit
- exactly one remote Swift package reference: Plaid's
  plaid-link-ios-spm (LinkKit), Up to Next Major Version from 7.0.0,
  linked to the OnBudget app target only — no other remote packages
- no shell-script build phases, no code-sign entitlements anywhere
- the UI test target is a ui-testing bundle whose TEST_TARGET_NAME
  is the app, so `test-without-building` launches the real app
No network, no Xcode build, no signing.
"""
import json
import pathlib
import plistlib
import re
import subprocess
import sys

CLONE = pathlib.Path(__file__).resolve().parents[1]
PROJECT = CLONE / "OnBudget.xcodeproj" / "project.pbxproj"


def load_project():
    raw = subprocess.check_output(
        ["plutil", "-convert", "json", "-o", "-", str(PROJECT)]
    )
    return json.loads(raw)


def main():
    data = load_project()
    objects = data["objects"]

    def references(value):
        if isinstance(value, dict):
            for nested in value.values():
                references(nested)
        elif isinstance(value, list):
            for nested in value:
                references(nested)
        elif isinstance(value, str) and re.fullmatch(r"[A-F0-9]{24}", value):
            assert value in objects, f"Missing PBX reference: {value}"

    references(data)

    # Every Swift source on disk must be a file reference in the
    # project (Nov 12, 2026: FundsRulesView.swift was committed without
    # a pbxproj entry and the run failed only at compile, ~25 minutes
    # in). Matched by filename — the project has no two sources sharing
    # a basename, so a filename match is exact.
    referenced = {
        o["path"] for o in objects.values()
        if o.get("isa") == "PBXFileReference"
        and str(o.get("path", "")).endswith(".swift")
    }
    for subdir in ("OnBudget", "OnBudgetTests", "OnBudgetUITests"):
        for path in sorted((CLONE / subdir).rglob("*.swift")):
            assert path.name in referenced, (
                f"{path.name} is on disk under {subdir}/ but has no "
                "entry in project.pbxproj — add it to its target "
                "(Xcode: File > Add Files) or the build cannot see it"
            )

    targets = {
        o["name"]: o
        for o in objects.values()
        if o.get("isa") == "PBXNativeTarget"
    }
    assert set(targets) == {"OnBudget", "OnBudgetTests", "OnBudgetUITests"}, (
        f"Unexpected targets: {sorted(targets)}"
    )

    root = objects[data["rootObject"]]
    project_configs = objects[root["buildConfigurationList"]][
        "buildConfigurations"
    ]
    for config in project_configs:
        settings = objects[config]["buildSettings"]
        assert settings.get("CODE_SIGNING_ALLOWED") == "NO", (
            "Project config must disable code signing"
        )
        assert not settings.get("DEVELOPMENT_TEAM"), (
            "No development team may be baked into the project"
        )
        assert settings.get("IPHONEOS_DEPLOYMENT_TARGET") == "18.0", (
            "Project deployment target must be 18.0"
        )

    assert not any(
        o.get("isa") == "PBXShellScriptBuildPhase" for o in objects.values()
    ), "Shell-script phases are not allowed"

    remote_packages = [
        o
        for o in objects.values()
        if o.get("isa") == "XCRemoteSwiftPackageReference"
    ]
    assert len(remote_packages) == 1, (
        f"Expected exactly one remote package (Plaid LinkKit), found {len(remote_packages)}"
    )
    remote = remote_packages[0]
    assert remote["repositoryURL"] == "https://github.com/plaid/plaid-link-ios-spm.git", (
        f"Remote package must be plaid-link-ios-spm, got {remote.get('repositoryURL')}"
    )
    requirement = remote.get("requirement", {})
    assert requirement.get("kind") == "upToNextMajorVersion", (
        f"Plaid requirement must be upToNextMajorVersion, got {requirement}"
    )
    assert requirement.get("minimumVersion") == "7.0.0", (
        f"Plaid minimumVersion must be 7.0.0, got {requirement}"
    )
    linkkit_deps = [
        (ref, o)
        for ref, o in objects.items()
        if o.get("isa") == "XCSwiftPackageProductDependency"
        and o.get("productName") == "LinkKit"
    ]
    assert len(linkkit_deps) == 1, (
        f"Expected exactly one LinkKit product dependency, found {len(linkkit_deps)}"
    )
    linkkit_ref, linkkit_dep = linkkit_deps[0]
    remote_ref = next(
        ref for ref, o in objects.items() if o is remote
    )
    assert linkkit_dep["package"] == remote_ref, (
        "LinkKit must come from the plaid-link-ios-spm package"
    )
    app_target = targets["OnBudget"]
    assert linkkit_ref in app_target.get("packageProductDependencies", []), (
        "LinkKit must be a dependency of the OnBudget app target"
    )
    tests_target = targets["OnBudgetTests"]
    assert linkkit_ref not in tests_target.get("packageProductDependencies", []), (
        "LinkKit must NOT be linked into the OnBudgetTests target"
    )

    packages = [
        o
        for o in objects.values()
        if o.get("isa") == "XCLocalSwiftPackageReference"
    ]
    assert len(packages) == 1, (
        f"Expected exactly one local package, found {len(packages)}"
    )
    assert packages[0]["relativePath"] == "OnBudgetKit", (
        f"Local package must be OnBudgetKit, got {packages[0]['relativePath']}"
    )

    for name, target in targets.items():
        for config in objects[target["buildConfigurationList"]][
            "buildConfigurations"
        ]:
            settings = objects[config]["buildSettings"]
            assert not settings.get("CODE_SIGN_ENTITLEMENTS"), (
                f"{name}: no unapproved entitlements"
            )
        if name == "OnBudget":
            app_configs = [
                objects[c]["buildSettings"]
                for c in objects[target["buildConfigurationList"]][
                    "buildConfigurations"
                ]
            ]
            settings = app_configs[0]
            # The app target uses a REAL Info.plist, not a generated
            # one: INFOPLIST_KEY_CFBundleURLTypes silently drops the
            # array-of-dictionaries value from the generated plist
            # (CI run 42730528742 — the built plist had no
            # CFBundleURLTypes key at all), so the onbudget scheme
            # must live in the file. Every app config must point at
            # it, and no INFOPLIST_KEY_* leftovers may sit alongside.
            for app_settings in app_configs:
                assert app_settings.get("GENERATE_INFOPLIST_FILE") == "NO", (
                    "App target must use a real Info.plist "
                    "(GENERATE_INFOPLIST_FILE = NO)"
                )
                assert app_settings.get("INFOPLIST_FILE") == "OnBudget/Info.plist", (
                    "App target must point at OnBudget/Info.plist "
                    "in every config"
                )
                assert not any(
                    k.startswith("INFOPLIST_KEY_") for k in app_settings
                ), (
                    "App target must not carry INFOPLIST_KEY_* settings "
                    "alongside the real Info.plist"
                )
            assert settings["ASSETCATALOG_COMPILER_APPICON_NAME"] == "AppIcon", (
                "App target must name the AppIcon asset"
            )
            # The onbudget URL scheme (gmail-callback + reset-password
            # deep links) must be registered in the app's Info.plist.
            # The file is shared by Debug and Release, so one check
            # covers both configs.
            assert "onbudget" in url_schemes_from_info_plist(), (
                "OnBudget/Info.plist must register the onbudget URL "
                "scheme under CFBundleURLTypes"
            )
        if name == "OnBudgetUITests":
            assert target["productType"] == (
                "com.apple.product-type.bundle.ui-testing"
            ), "UITests must be a ui-testing bundle"
            settings = objects[
                objects[target["buildConfigurationList"]][
                    "buildConfigurations"
                ][0]
            ]["buildSettings"]
            assert settings.get("TEST_TARGET_NAME") == "OnBudget", (
                "UITests must test the OnBudget app target"
            )

    print("validate_project.py: project graph OK "
          "(OnBudget + OnBudgetTests + OnBudgetUITests, OnBudgetKit local package, "
          "LinkKit remote package on app target only, no signing)")
    return 0


def url_schemes_from_info_plist():
    """All CFBundleURLSchemes from the app target's real Info.plist
    (ios-clone/OnBudget/Info.plist)."""
    info_path = CLONE / "OnBudget" / "Info.plist"
    assert info_path.is_file(), f"App Info.plist missing: {info_path}"
    with open(info_path, "rb") as f:
        info = plistlib.load(f)
    schemes = []
    for url_type in info.get("CFBundleURLTypes", []):
        if isinstance(url_type, dict):
            schemes.extend(url_type.get("CFBundleURLSchemes", []))
    return schemes


if __name__ == "__main__":
    sys.exit(main())
