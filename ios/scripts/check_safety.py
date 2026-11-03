#!/usr/bin/env python3
"""Read-only branch/path/credential guard. No network, writes, or deployment."""
import argparse
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]

def git(*args):
    return subprocess.check_output(['git', '-C', str(ROOT), *args])

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--approved-cloud-workflow', action='store_true', help='After owner approval ONLY: permit the exact reviewed workflow candidate.')
    approved = parser.parse_args().approved_cloud_workflow
    branch = git('branch', '--show-current').decode().strip()
    if branch != 'ios-native-rebuild':
        sys.exit('FAIL: expected ios-native-rebuild; never run push from another branch.')
    # Include committed branch changes, unstaged/staged changes, and new files.
    base = git('merge-base', 'HEAD', 'origin/main').decode().strip()
    names = set()
    for args in [('diff', '--name-only', '-z', base), ('ls-files', '--others', '--exclude-standard', '-z')]:
        names.update(p.decode() for p in git(*args).split(b'\0') if p)
    allowed_workflow = '.github/workflows/onbudget-ios-sample.yml'
    if approved:
        # This does not create/activate a workflow or grant approval. It validates
        # an exact candidate only after the separate owner approval step.
        candidate = (ROOT / 'ios/docs/CLOUD_BUILD_DRAFT.md').read_text().split('```yaml\n', 1)[1].split('```', 1)[0]
        path = ROOT / allowed_workflow
        if not path.is_file() or path.read_text() != candidate:
            sys.exit('FAIL: workflow differs from reviewed documentation.')
    outside = sorted(n for n in names if not n.startswith('ios/') and not (approved and n == allowed_workflow))
    if outside:
        sys.exit('FAIL: changes outside ios/: ' + ', '.join(outside))
    patterns = [
        ('PEM private key', re.compile(r'-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----')),
        ('GitHub token', re.compile(r'\b(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{40,})\b')),
        ('JWT', re.compile(r'\beyJ[A-Za-z0-9_-]{12,}\.[A-Za-z0-9_-]{12,}\.[A-Za-z0-9_-]{12,}\b')),
        ('AWS access key', re.compile(r'\b(?:AKIA|ASIA)[A-Z0-9]{16}\b')),
        ('production endpoint', re.compile(r'https?://[a-z0-9-]+\.supabase\.(?:co|com)\b')),
    ]
    failures = []
    for name in sorted(names):
        path = ROOT / name
        if not path.is_file():
            continue
        if path.is_symlink():
            failures.append((name, 'symlink forbidden'))
            continue
        if path.suffix.lower() in {'.p12', '.p8', '.mobileprovision', '.key', '.ipa'}:
            failures.append((name, 'credential/signing artifact forbidden'))
        if path.suffix.lower() in {'.jpg', '.png'}:
            continue
        text = path.read_text(encoding='utf-8', errors='replace')
        for label, pattern in patterns:
            if pattern.search(text):
                failures.append((name, label))
    if failures:
        for name, label in failures:
            print(f'FAIL: {name}: {label} (value redacted)')
        sys.exit(1)
    print(f'PASS: branch {branch}; {len(names)} changed files within approved scope; credential-pattern scan clean.')
    print('Pattern scanning is not a guarantee: also review git diff --cached before every push.')

if __name__ == '__main__':
    main()
