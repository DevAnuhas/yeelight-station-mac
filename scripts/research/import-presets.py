#!/usr/bin/env python3
"""Import numeric scene, palette and layout configuration from an extracted Station app."""
import argparse
import json
from pathlib import Path
import xml.etree.ElementTree as ET

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('configs', type=Path, help='Extracted Resources/Configs directory')
parser.add_argument('--output', type=Path, default=Path('Sources/StationCore/Resources/station-presets.json'))
args = parser.parse_args()
scenes = []
for i, x in enumerate(ET.parse(args.configs / 'scenemodels.yee').iter('YeeSceneModel')):
    a = x.attrib
    scenes.append(dict(id=f'station-{i}', name=a['name'], powerMode=int(a['powerMode']), brightness=int(a['bright']), temperature=int(a['ct']), rgb=int(a['rgb'][1:], 16) if a['rgb'].startswith('#') else int(a['rgb']), flow=a['cf']))
palettes = []
for group in ET.parse(args.configs / 'audiocapturermodels.yee').getroot():
    for x in group:
        palettes.append(dict(id=group.attrib['name'] + '-' + x.attrib['name'], name=x.attrib['en'], group=group.attrib['en'], colors=[int(c.attrib['rgb'][1:], 16) for c in x]))
layout_names = ['Four edges', 'Six zones', 'Whole screen', 'Left / right', 'Three columns', 'Top / bottom', 'Four columns', 'Five zones']
layouts = []
for i, x in enumerate(ET.parse(args.configs / 'appsettings.yee').iter('DesktopRectTemplate')):
    layouts.append(dict(id=x.attrib['name'], name=layout_names[i], zones=[{k: int(v) / 100 for k, v in c.attrib.items()} for c in x]))
args.output.parent.mkdir(parents=True, exist_ok=True)
args.output.write_text(json.dumps(dict(scenes=scenes, palettes=palettes, layouts=layouts), indent=2) + '\n')
print(f'Imported {len(scenes)} scenes, {len(palettes)} palettes, {len(layouts)} layouts to {args.output}')
