# Build offline regions

Map coverage is supplied by the person building/importing a region. The tools
accept OSM XML or PBF extracts rather than a fixed download region.

```sh
mkdir -p build
uv run python tools/import_map.py --source area.osm.pbf --output build/area.sqlite

# Watch: trails, named streets, parks, woodland and water.
uv run python tools/build_watch_map.py --source build/area.sqlite \
  --output build/area.wp2map --profile outdoors --coverage "Selected region"
uv run python tools/check_watch_map.py build/area.wp2map

# iOS phone map: richer geometry and an offline name index.
uv run python tools/build_tiny_map.py --source build/area.sqlite \
  --output build/area-base.cmfmap
uv run python tools/build_search_index.py --source build/area-base.cmfmap \
  --output build/area.cmfmap
```

`--region boundary.geojson` clips the watch pack to an optional WGS84 Polygon
or MultiPolygon. `--profile all-roads` keeps ordinary road geometry as well;
it costs more storage. The default `outdoors` profile keeps named streets,
trails, unpaved ways, named waterways and parks/water/woodland of at least
10,000 square metres. Buildings and most unnamed urban sidewalks are omitted.
The smaller `hiking` profile omits ordinary streets. The default 4 metre
projected grid is lossy; `--grid 8` or `--grid 16` trades precision for space.
Names use an ASCII subset on the watch.

The input database can be supplemented with a compatible trail database using
`--trail-source`. Source segment counts may overlap and are not a count of
unique named trails. Access restrictions, closures and routing topology need
separate verification. The native watch pack does not implement route finding
or elevation gain. iOS's experimental richer-map routing/elevation code is
separate; elevation requires a compatible imported/generated dataset.

The projection covers latitudes within ±85° and longitudes within ±180°.
Antimeridian-spanning extracts are not currently supported. Very large regions
can exceed the watch budget even when their source download is small; the
builder refuses to publish an oversized pack. Make a smaller region or use the
hiking profile. The whole detailed planet or US cannot fit in this watch's
ordinary writable map storage.

## Import and transfer

- iOS: import `.cmfmap` in map Settings, and `.wp2map` under Watch apps.
- Android: import `.wp2map`; the phone draws and searches that same regional
  vector data. It does not yet render the richer `.cmfmap` format.
- Open Trail Map on the watch and choose Download in the companion.

Both receivers check the complete file before use. The phone sends a small
acknowledged batch at a time. A retry begins at the watch-confirmed staged file
offset. Completion means the file was committed and its size, checksum and
version were read back. A paused transfer is not shown as a completed map.

The previous active map remains while a replacement arrives. After successful
commit, the old active file is removed. Named places are stored separately;
eight recent phone-rendered views have their own bounded cache.

## Saved points and Organic Maps

Search results are capped at 300 and can all be shown on the phone map. Point
bookmarks import from GPX or GeoJSON and export to GPX. Track lines are not
turned into invented point-to-point trails. The 32 most recent saved points can
sync to the watch and stay there independently of the recent-image cache.

Organic Maps owns its MWM renderer and offline downloads. Its public location
URL API can open a selected point; it does not export rendered tiles to this
companion. Use bookmark exchange, or build the supported formats from OSM.

## Attribution

Map data © [OpenStreetMap contributors](https://www.openstreetmap.org/copyright),
ODbL 1.0. Retain attribution and the applicable data license when distributing
your derived maps. `examples/source.json` pins the separate Monaco demo source.

## Spatial pages and redraws

New packs use WP2MAP1 codec 2 and require loader v5 with Trail Map v11.
Codec 1 packs remain supported. Each independent page carries cell-local
bounds and a scale range; offscreen pages are skipped before decompression.
The watch caches 32 decoded pages and their feature bounds in RAM. Labels
come from the pack, with collision checks and a bounded name cache. Turning
the crown combines queued input and defers image-cache writes until idle.

`--subcell 1024`, `2048`, `4096` or `8192` controls spatial partitioning.
Smaller partitions reduce cold-view work but increase storage. A pack has
a maximum of 65,535 fixed-width names, including the empty name. Trail
names receive priority; after the name table fills, remaining geometry is
retained without a label and `omitted_name_labels` is reported.
