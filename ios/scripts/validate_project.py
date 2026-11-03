#!/usr/bin/env python3
"""Validate the real generated PBX graph using Apple's plist parser/Foundation.
No network, Xcode build, signing, or third-party Python dependencies.
"""
import argparse
import json
import pathlib
import plistlib
import re
import shutil
import subprocess
import xml.etree.ElementTree as ET

IOS = pathlib.Path(__file__).resolve().parents[1]

def validate(swift=None):
    project = IOS / 'OnBudget.xcodeproj/project.pbxproj'
    if shutil.which('plutil'):
        raw = subprocess.check_output(['plutil', '-convert', 'json', '-o', '-', str(project)])
    else:
        compiler = swift or shutil.which('swift')
        assert compiler, 'Need plutil (macOS) or --swift /path/to/swift for plist parsing.'
        program = 'import Foundation; let d = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])); let p = try PropertyListSerialization.propertyList(from:d, format:nil); print(String(data:try JSONSerialization.data(withJSONObject:p),encoding:.utf8)!)'
        raw = subprocess.check_output([compiler, '-e', program, str(project)])
    data = json.loads(raw)
    objects = data['objects']
    def references(value):
        if isinstance(value, dict):
            for nested in value.values(): references(nested)
        elif isinstance(value, list):
            for nested in value: references(nested)
        elif isinstance(value, str) and re.fullmatch('[A-F0-9]{24}', value):
            assert value in objects, f'Missing PBX reference: {value}'
    references(data)
    targets = {o['name']: o for o in objects.values() if o.get('isa') == 'PBXNativeTarget'}
    assert set(targets) == {'OnBudget', 'OnBudgetWidget', 'OnBudgetUITests'}
    root = objects[data['rootObject']]
    configs = objects[root['buildConfigurationList']]['buildConfigurations']
    for config in configs:
        settings = objects[config]['buildSettings']
        assert settings['CODE_SIGNING_ALLOWED'] == 'NO'
        assert not settings['DEVELOPMENT_TEAM']
        assert settings['IPHONEOS_DEPLOYMENT_TARGET'] == '17.0'
    assert not any(o.get('isa') in ('XCRemoteSwiftPackageReference', 'PBXShellScriptBuildPhase') for o in objects.values())
    packages = [o for o in objects.values() if o.get('isa') == 'XCLocalSwiftPackageReference']
    assert len(packages) == 1 and packages[0]['relativePath'] == '.'
    for name, target in targets.items():
        for config in objects[target['buildConfigurationList']]['buildConfigurations']:
            settings = objects[config]['buildSettings']
            assert not settings.get('CODE_SIGN_ENTITLEMENTS'), 'No unapproved entitlements'
            if name == 'OnBudgetUITests':
                assert settings['GENERATE_INFOPLIST_FILE'] == 'YES'
                assert settings['TEST_TARGET_NAME'] == 'OnBudget'
            else:
                path = IOS / settings['INFOPLIST_FILE']
                with path.open('rb') as stream: info = plistlib.load(stream)
                assert info['CFBundleShortVersionString'] == '$(MARKETING_VERSION)'
                assert info['CFBundleVersion'] == '$(CURRENT_PROJECT_VERSION)'
                assert info['OnBudgetAppGroup'] == ''
                if name == 'OnBudgetWidget':
                    assert settings['APPLICATION_EXTENSION_API_ONLY'] == 'YES'
                    assert info['NSExtension']['NSExtensionPointIdentifier'] == 'com.apple.widgetkit-extension'
        sources = [objects[p] for p in target['buildPhases'] if objects[p]['isa'] == 'PBXSourcesBuildPhase']
        files = {objects[objects[f]['fileRef']]['path'] for p in sources for f in p['files']}
        folder = {'OnBudget': 'App', 'OnBudgetWidget': 'Widget', 'OnBudgetUITests': 'UITests'}[name]
        assert files == {p.name for p in (IOS / folder).glob('*.swift')}, f'Source membership mismatch for {name}'
        if name != 'OnBudgetUITests':
            resource_phases = [objects[p] for p in target['buildPhases'] if objects[p]['isa'] == 'PBXResourcesBuildPhase']
            resources = {objects[objects[f]['fileRef']]['path'] for p in resource_phases for f in p['files']}
            assert 'PrivacyInfo.xcprivacy' in resources
    embed = [objects[p] for p in targets['OnBudget']['buildPhases'] if objects[p]['isa'] == 'PBXCopyFilesBuildPhase']
    assert any(str(p['dstSubfolderSpec']) == '13' and any(objects[objects[f]['fileRef']].get('path') == 'OnBudgetWidget.appex' for f in p['files']) for p in embed)
    scheme = ET.parse(IOS / 'OnBudget.xcodeproj/xcshareddata/xcschemes/OnBudget.xcscheme')
    assert scheme.find('.//TestableReference/BuildableReference').attrib['BlueprintName'] == 'OnBudgetUITests'
    assert scheme.find('.//TestableReference').attrib['skipped'] == 'NO'
    print('PASS: real PBX graph, source membership, local package, plist/version metadata, unsigned targets, widget embedding/privacy and shared test scheme.')
    print('Not an Xcode compilation or simulator test.')

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--swift')
    validate(parser.parse_args().swift)
