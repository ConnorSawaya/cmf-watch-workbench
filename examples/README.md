# Example map

Run `./tools/build_demo.sh` from the repository root. It downloads the pinned
OpenStreetMap extract recorded in [source.json](source.json), converts it in
`build/demo/`, and copies generated map assets into both companion builds.
The source extract and generated files are not part of the source checkout.

The historical Monaco extract comes from a GraphHopper test fixture. It is a
rendering and protocol example; use a current OSM extract for navigation.
See [building a region](../docs/maps.md) to choose any supported area.

Map data: © [OpenStreetMap contributors](https://www.openstreetmap.org/copyright).
Data license: [ODbL 1.0](https://opendatacommons.org/licenses/odbl/1-0/).
The companions draw imported data offline and do not fetch map tiles.
