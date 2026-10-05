"""Build bundled map from vuski/admdongkor (requires shapely).
Usage: python scripts/build_summary_map.py /path/to/HangJeongDong.geojson
Source: SGIS / vuski/admdongkor, CC BY 4.0 and KOGL Type 1.
"""
import json
import sys
from collections import defaultdict
from pathlib import Path
from shapely.geometry import shape, mapping
from shapely.ops import unary_union

source = json.loads(Path(sys.argv[1]).read_text())
groups = defaultdict(list)
names = {}
parents = {}
provinces = defaultdict(list)
province_names = {}
for f in source['features']:
    p = f['properties']
    geom = shape(f['geometry'])
    if not geom.is_valid:
        geom = geom.buffer(0)
    province = p['sido']
    # Sejong has no si/gun/gu: show its eup/myeon/dong directly.
    code = p['adm_cd2'] if province == '36' else p['sgg']
    groups[code].append(geom)
    names[code] = p['adm_nm'].split()[-1] if province == '36' else p['sggnm']
    parents[code] = province
    provinces[province].append(geom)
    province_names[province] = p['sidonm']

def feature(code, name, parent, geometries):
    geom = unary_union(geometries).simplify(0.0005, preserve_topology=True)
    # Use a point inside the largest mainland polygon for labels.
    largest = max(geom.geoms, key=lambda x: x.area) if geom.geom_type == 'MultiPolygon' else geom
    anchor = largest.representative_point()
    return {'id': code, 'name': name, 'parent': parent,
            'anchor': [anchor.x, anchor.y], 'geometry': mapping(geom)}

out = {'version': '2026-07-01', 'regions':
       [feature(k, province_names[k], None, v) for k, v in sorted(provinces.items())] +
       [feature(k, names[k], parents[k], v) for k, v in sorted(groups.items())]}
# Round coordinates to ~1m; retain holes and all islands.
def rounded(x):
    if isinstance(x, float): return round(x, 5)
    if isinstance(x, (list, tuple)): return [rounded(v) for v in x]
    if isinstance(x, dict): return {k: rounded(v) for k, v in x.items()}
    return x
path = Path(__file__).resolve().parents[1] / 'Prontend/assets/maps/korea.json'
path.write_text(json.dumps(rounded(out), ensure_ascii=False, separators=(',', ':')))
print(f'{len(provinces)} provinces, {len(groups)} subdivisions; {path.stat().st_size:,} bytes')
