#!/usr/bin/env python3
"""Extract a user-supplied Station NSIS installer without executing Windows code."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('installer', type=Path)
parser.add_argument('--output', type=Path, default=Path('.analysis'))
parser.add_argument('--rea', type=Path, help='Optional REA CLI wrapper for PE Evidence')
args = parser.parse_args()
installer = args.installer.resolve(strict=True)
if not installer.is_file():
    parser.error('installer must be a regular file')
extractor = shutil.which('7zz') or shutil.which('7z')
if extractor is None:
    parser.error('7zz is required (brew install sevenzip)')
output = args.output.resolve()
if output.exists() and any(output.iterdir()):
    parser.error('output must be absent or empty to prevent mixing installer versions')
output.mkdir(parents=True, exist_ok=True)
subprocess.run([extractor, 'x', '-y', str(installer), '-o' + str(output / 'installer')], check=True)
archive = output / 'installer/app.7z'
if not archive.is_file():
    parser.error('this installer has no app.7z payload; inspect its format before proceeding')
subprocess.run([extractor, 'x', '-y', str(archive), '-o' + str(output / 'windows-app')], check=True)
files = {}
for file in sorted(output.rglob('*')):
    if file.is_file():
        files[str(file.relative_to(output))] = {'bytes': file.stat().st_size, 'sha256': hashlib.file_digest(file.open('rb'), 'sha256').hexdigest()}
manifest = {'installer': installer.name, 'installer_sha256': hashlib.file_digest(installer.open('rb'), 'sha256').hexdigest(), 'files': files}
(output / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
if args.rea:
    for name in ['YeelightStation.exe', 'YeeDaemonLib.dll', 'YeeDesktopCapturer.exe']:
        evidence = subprocess.run([str(args.rea.resolve()), 'inspect-artifact', str(output / 'windows-app' / name), '--format', 'json'], check=True, capture_output=True)
        (output / ('rea-' + name + '.json')).write_bytes(evidence.stdout)
print(f'Extracted {len(files)} files. Evidence and binaries remain local under {output}.')
