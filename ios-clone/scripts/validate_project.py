#!/usr/bin/env python3
"""Validate the OnBudget clone project graph without building anything.

Parses ios-clone/OnBudget.xcodeproj/project.pbxproj with plutil (macOS)
and checks the invariants the scaffold must hold:
- every 24-hex object reference resolves
- exactly the two expected targets exist (OnBudget, OnBudgetTests)
- project configs disable code signing, name no development team,
  and pin the iOS 18.0 deployment target
- exactly one local Swift package reference, pointing at OnBudgetKit
- no remote package references, no shell-script build phases,
  no code-sign entitlements anywhere
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
    assert set(targets) == {"OnBudget", "OnBudgetTests"}, (
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
        o.get("isa") in ("XCRemoteSwiftPackageReference", "PBXShellScriptBuildPhase")
        for o in objects.values()
    ), "Remote packages and shell-script phases are not allowed"

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
            settings = objects[
                objects[target["buildConfigurationList"]][
                    "buildConfigurations"
                ][0]
            ]["buildSettings"]
            assert settings["GENERATE_INFOPLIST_FILE"] == "YES", (
                "App target uses a generated Info.plist"
            )
            assert settings["ASSETCATALOG_COMPILER_APPICON_NAME"] == "AppIcon", (
                "App target must name the AppIcon asset"
            )

    print("validate_project.py: project graph OK "
          "(OnBudget + OnBudgetTests, OnBudgetKit local package, no signing)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
