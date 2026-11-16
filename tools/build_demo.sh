#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
mkdir -p build/demo ios/TrailCompanion/Resources android/app/src/main/assets/generated
uv run python - <<'PY'
import gzip,json,urllib.request
from pathlib import Path
source=json.loads(Path('examples/source.json').read_text())
out=Path('build/demo/monaco.osm')
if not out.exists():
    with urllib.request.urlopen(source['url'],timeout=45) as response:
        out.write_bytes(gzip.decompress(response.read()))
PY
if [ ! -f build/demo/map.sqlite ]; then uv run python tools/import_map.py --source build/demo/monaco.osm --output build/demo/map.sqlite; fi
if [ ! -f build/demo/base.cmfmap ]; then uv run python tools/build_tiny_map.py --source build/demo/map.sqlite --output build/demo/base.cmfmap; fi
if [ ! -f build/demo/demo-map.cmfmap ]; then uv run python tools/build_search_index.py --source build/demo/base.cmfmap --output build/demo/demo-map.cmfmap; fi
if [ ! -f build/demo/demo-map.wp2map ]; then uv run python tools/build_watch_map.py --source build/demo/map.sqlite --output build/demo/demo-map.wp2map --profile all-roads --coverage 'Monaco example: historical OpenStreetMap extract'; fi
uv run python tools/check_watch_map.py build/demo/demo-map.wp2map
cp build/demo/demo-map.cmfmap ios/TrailCompanion/Resources/demo-map.cmfmap
cp build/demo/demo-map.wp2map ios/TrailCompanion/Resources/demo-map.wp2map
cp build/demo/demo-map.wp2map android/app/src/main/assets/generated/demo-map.wp2map
