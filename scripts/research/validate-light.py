#!/usr/bin/env python3
"""Probe a supplied LAN light; --apply briefly tests channels, then restores static state."""
import argparse
import json
from pathlib import Path
import socket
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('host')
parser.add_argument('--apply', action='store_true', help='Briefly change light settings and restore them in finally')
parser.add_argument('--output', type=Path, default=Path('.analysis/hardware/control-validation.json'))
args = parser.parse_args()
keys = ['power', 'bright', 'ct', 'rgb', 'color_mode', 'flowing', 'bg_power', 'bg_bright', 'bg_rgb', 'bg_ct', 'bg_lmode', 'bg_flowing', 'model', 'fw_ver']
s = socket.create_connection((args.host, 55443), 3)
s.settimeout(3)
stream = s.makefile('rb')
request_id = 0
last_send = 0.0

def request(method, params):
    global request_id, last_send
    time.sleep(max(0, 1.05 - (time.monotonic() - last_send)))
    request_id += 1
    s.sendall((json.dumps({'id': request_id, 'method': method, 'params': params}, separators=(',', ':')) + '\r\n').encode())
    last_send = time.monotonic()
    while True:
        response = json.loads(stream.readline())
        if response.get('id') != request_id:
            continue
        if 'error' in response:
            raise RuntimeError(str(response['error']))
        return response.get('result')

def properties():
    return dict(zip(keys, request('get_prop', keys)))

baseline = properties()
report = {'host': args.host, 'baseline': baseline, 'checks': []}
print('Read baseline:', baseline, flush=True)
if args.apply:
    if baseline.get('model') != 'lamp15':
        raise RuntimeError('This validation is scoped to lamp15 only.')
    if baseline.get('flowing') == '1' or baseline.get('bg_flowing') == '1':
        raise RuntimeError('Stop dynamic flows before this static-state restoration test.')
    try:
        request('bg_set_scene', ['color', 0x3366ff, 30])
        state = properties()
        assert state['bg_rgb'] == str(0x3366ff) and state['bg_bright'] == '30', state
        assert all(state[x] == baseline[x] for x in ['power', 'bright', 'ct']), state
        report['checks'].append('RGB backlight scene acknowledged and verified; task light unchanged')
        request('bg_set_bright', [45, 'smooth', 300])
        assert properties()['bg_bright'] == '45'
        report['checks'].append('Backlight brightness acknowledged and verified')
        request('set_bright', [2 if baseline['bright'] != '2' else 3, 'smooth', 300])
        assert properties()['bright'] in ['2', '3']
        request('set_bright', [int(baseline['bright']), 'smooth', 300])
        report['checks'].append('Task-light brightness acknowledged, verified, restored')
        request('set_ct_abx', [3900 if baseline['ct'] != '3900' else 4000, 'smooth', 300])
        assert properties()['ct'] in ['3900', '4000']
        report['checks'].append('Task-light temperature acknowledged and verified')
    finally:
        request('set_ct_abx', [int(baseline['ct']), 'smooth', 300])
        request('set_bright', [int(baseline['bright']), 'smooth', 300])
        request('set_power', [baseline['power'], 'smooth', 300])
        request('bg_set_scene', ['color', int(baseline['bg_rgb']), int(baseline['bg_bright'])])
        request('bg_set_power', [baseline['bg_power'], 'smooth', 300])
        restored = properties()
        compare = ['power', 'bright', 'ct', 'bg_power', 'bg_bright', 'bg_rgb']
        report['restored'] = restored
        report['restoration_matches'] = all(restored[x] == baseline[x] for x in compare)
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(report, indent=2) + '\n')
        print('Restored static state:', report['restoration_matches'], flush=True)
        assert report['restoration_matches'], report
else:
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + '\n')
s.close()
print('Checks:', report['checks'], flush=True)
