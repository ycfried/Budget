#!/usr/bin/env python3
"""Read-only branch/path/credential guard. No network, writes, or deployment."""
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]

def git(*args):
    return subprocess.check_output(['git', '-C', str(ROOT), *args])

def main():
    branch = git('branch', '--show-current').decode().strip()
    if branch != 'ios-native-rebuild':
        sys.exit('FAIL: expected ios-native-rebuild; never run push from another branch.')
    # Include committed branch changes, unstaged/staged changes, and new files.
    base = git('merge-base', 'HEAD', 'origin/main').decode().strip()
    names = set()
    for args in [('diff', '--name-only', '-z', base), ('ls-files', '--others', '--exclude-standard', '-z')]:
        names.update(p.decode() for p in git(*args).split(b'\0') if p)
    outside = sorted(n for n in names if not n.startswith('ios/'))
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
    print(f'PASS: branch {branch}; {len(names)} changed files confined to ios/; credential-pattern scan clean.')
    print('Pattern scanning is not a guarantee: also review git diff --cached before every push.')

if __name__ == '__main__':
    main()
