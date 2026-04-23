#!/usr/bin/env python3
"""Inject GitHub Codespace Secrets / env vars into config.template.yaml -> config.yaml"""
import os
import sys
import re

def resolve(value):
    if not isinstance(value, str):
        return value
    # Support ${ENV_VAR} and ${ENV_VAR:-default}
    def replacer(m):
        key = m.group(1)
        if ':-' in key:
            k, default = key.split(':-', 1)
            return os.getenv(k, default)
        return os.getenv(key, '')
    return re.sub(r'\\$\{([^}]+)\}', replacer, value)

def process_file(src, dst):
    with open(src, 'r', encoding='utf-8') as f:
        content = f.read()
    # Process line by line to preserve YAML structure
    lines = []
    for line in content.splitlines():
        lines.append(resolve(line))
    with open(dst, 'w', encoding='utf-8') as f:
        f.write('\n'.join(lines) + '\n')
    print(f"Config generated: {dst}")

if __name__ == '__main__':
    if len(sys.argv) < 3:
        print("Usage: inject-config.py <template> <output>")
        sys.exit(1)
    process_file(sys.argv[1], sys.argv[2])
