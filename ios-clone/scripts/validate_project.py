#!/usr/bin/env python3
"""Validate the OnBudget clone project graph without building anything.

Parses ios-clone/OnBudget.xcodeproj/project.pbxproj with plutil (macOS)
and checks the invariants the scaffold must hold:
- every 24-hex object reference resolves
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
            assert settings["GENERATE_INFOPLIST_FILE"] == "YES", (
                "App target uses a generated Info.plist"
            )
            assert settings["ASSETCATALOG_COMPILER_APPICON_NAME"] == "AppIcon", (
                "App target must name the AppIcon asset"
            )
            # The onbudget URL scheme (gmail-callback + reset-password
            # deep links) must be registered in EVERY app config —
            # a Debug-only registration would silently break the
            # Release deep links.
            for app_settings in app_configs:
                assert "onbudget" in url_schemes(app_settings), (
                    "App target must register the onbudget URL scheme "
                    "in every config (INFOPLIST_KEY_CFBundleURLTypes)"
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


def url_schemes(settings):
    """All CFBundleURLSchemes from the INFOPLIST_KEY_CFBundleURLTypes
    build setting (a list of {CFBundleURLSchemes: [...]} dicts)."""
    schemes = []
    for url_type in settings.get("INFOPLIST_KEY_CFBundleURLTypes", []):
        if isinstance(url_type, dict):
            schemes.extend(url_type.get("CFBundleURLSchemes", []))
    return schemes


if __name__ == "__main__":
    sys.exit(main())
