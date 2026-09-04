#!/usr/bin/env python3
"""Build geometry-only Pocket inventory overrides from the tested local assets.

No textures, collection bindings, actions, grid counts or animation timings are
copied. Pixel lengths double; percentages keep the layout responsive at 720x480.
The resulting files are shipped, so the device does not need this build tool.
"""
import argparse
import json
from pathlib import Path
import re


def read_jsonc(path):
    text = path.read_text(encoding="utf-8-sig")
    text = re.sub(r'"(?:\\.|[^"\\])*"|/\*[\s\S]*?\*/|//[^\n]*',
                  lambda m: m[0] if m[0].startswith('"') else '', text)
    return json.loads(re.sub(r',\s*([}\]])', r'\1', text))


def double_pixels(value):
    if isinstance(value, list):
        return [double_pixels(v) for v in value]
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        return value * 2
    if isinstance(value, str):
        return re.sub(r'(-?\d+(?:\.\d+)?)px',
                      lambda m: f'{float(m[1]) * 2:g}px', value)
    return value


def geometry_property(key):
    if key in {"size", "min_size", "max_size", "offset", "clip_offset"}:
        return True
    # Variables used for actual layout dimensions, not atlas/UV dimensions.
    bare = key.partition('|')[0]
    return key.startswith('$') and (bare.endswith(('_size', '_offset')) or bare in {
        '$top_tab_anim_start', '$top_tab_anim_end', '$offset'})


def overrides(doc, selected=None):
    result = {"namespace": doc["namespace"]}

    def visit(path, control):
        edit = {}
        for key, value in control.items():
            if geometry_property(key):
                scaled = double_pixels(value)
                if scaled != value:
                    edit[key] = scaled
        if control.get('type') == 'label':
            edit['font_scale_factor'] = 2
        if edit:
            result[path] = edit
        for child in control.get('controls', []):
            for name, body in child.items():
                if isinstance(body, dict):
                    visit(path + '/' + name.split('@')[0], body)

    for name, body in doc.items():
        name = name.split('@')[0]
        if isinstance(body, dict) and (selected is None or name in selected):
            visit(name, body)
    return result


def build(vanilla, output):
    pocket = read_jsonc(vanilla / 'inventory_screen_pocket.json')
    crafting = read_jsonc(vanilla / 'inventory_screen.json')
    definitions = {k.split('@')[0]: (k,v) for k,v in crafting.items() if isinstance(v,dict)}
    # Follow the shared crafting prototypes actually referenced by Pocket UI.
    refs = set(re.findall(r'crafting\.([\w]+)', json.dumps(pocket)))
    pending = list(refs)
    while pending:
        name = pending.pop()
        if name not in definitions:
            raise ValueError(f'Missing crafting prototype: {name}')
        for dependency in re.findall(r'crafting\.([\w]+)', json.dumps(definitions[name])):
            if dependency not in refs:
                refs.add(dependency)
                pending.append(dependency)

    result = overrides(pocket)
    result['inventory_screen_pocket_base'] = {'$hh_inventory_scale': 2}
    # Close-button and native paper-doll bounds are inherited from other files.
    result['right_tab_navigation_panel_pocket/content/close/close_button'] = {'size': [30,30]}
    # Restore the 1.16 proportional category spacing, retaining 1.21 factories.
    for name in ['search_tab_panel','construction_tab_panel','equipment_tab_panel','items_tab_panel','nature_tab_panel']:
        result['left_tab_navigation_panel_pocket/content/' + name] = {'size': ['100%', '16%']}
    result['left_tab_navigation_panel_pocket/content/inventory_tab'] = {'size': ['100%', '16%']}
    shared = overrides(crafting, refs)
    output.mkdir(parents=True, exist_ok=True)
    for name, data in [('inventory_screen_pocket.json',result),('inventory_screen.json',shared)]:
        # newline='' keeps LF on a Windows build host; the device wants LF.
        with open(output/name,'w',encoding='utf-8',newline='') as stream:
            stream.write(json.dumps(data,indent=2)+'\n')
        print(f'{name}: {len(data)-1} geometry overrides')


if __name__ == '__main__':
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--vanilla',type=Path,required=True,help='Exact 1.21.51 vanilla/ui directory')
    p.add_argument('--output',type=Path,required=True)
    args=p.parse_args()
    build(args.vanilla,args.output)
