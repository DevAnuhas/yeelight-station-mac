#!/usr/bin/env python3
"""Run discovery inside the packaged GUI app's identity and fail if a supplied LAN light is absent."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('host', help='IPv4 address of the powered-on light with LAN Control enabled')
parser.add_argument('--app', type=Path, default=Path('dist/Yeelight Station.app'))
parser.add_argument('--output', type=Path)
args = parser.parse_args()
app = args.app.resolve(strict=True)
output = args.output.resolve() if args.output else Path(tempfile.mkdtemp(prefix='station-discovery-')) / 'report.json'
output.parent.mkdir(parents=True, exist_ok=True)
if output.exists():
    parser.error('output already exists; choose a new path to avoid reading stale evidence')
stdout = output.with_suffix('.stdout.log')
stderr = output.with_suffix('.stderr.log')
subprocess.run(['/usr/bin/open', '-n', '-a', str(app), '--stdout', str(stdout), '--stderr', str(stderr), '--env', 'STATION_DISCOVERY_DEBUG=1', '--args', '--diagnose-network', '--diagnose-host', args.host, '--diagnose-output', str(output)], check=True)
deadline = time.monotonic() + 25
while not output.exists() and time.monotonic() < deadline:
    time.sleep(0.1)
if not output.exists():
    raise SystemExit(f'FAIL: app produced no diagnostic within 25 seconds. Logs: {stdout}, {stderr}')
report = json.loads(output.read_text())
pid = report.get('pid')
if not isinstance(pid, int) or pid <= 1:
    raise SystemExit('FAIL: app report has no valid process identifier')
def running():
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
end = time.monotonic() + 5
while running() and time.monotonic() < end:
    time.sleep(0.1)
if running():
    raise SystemExit(f'FAIL: diagnostic PID {pid} did not exit after writing its report')
print('PASS: diagnostic app exited cleanly.')
print(json.dumps(report, indent=2))
# The report retains separate multicast and direct-probe observations.
def devices(value):
    if isinstance(value, dict):
        if 'host' in value and ('model' in value or 'id' in value):
            yield value
        for child in value.values():
            yield from devices(child)
    elif isinstance(value, list):
        for child in value:
            yield from devices(child)
found = [item for item in devices(report) if item.get('host') == args.host]
if not found:
    raise SystemExit(f'FAIL: packaged app did not discover {args.host}. Report: {output}')
print(f'PASS: packaged app discovered {args.host}. Report: {output}')
