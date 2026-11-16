#!/usr/bin/env python3
"""Build a local spatial database from an OSM extract. No tile downloads."""
import argparse
from collections import Counter
import json
import math
from pathlib import Path
import sqlite3
import time

import numpy as np
import osmium
import shapely
from shapely.geometry import mapping

ROOT = Path(__file__).resolve().parents[1]
ROAD_ZOOM = dict(motorway=5, motorway_link=7, trunk=5, trunk_link=7, primary=6,
                 primary_link=8, secondary=8, secondary_link=10, tertiary=10,
                 tertiary_link=11, residential=12, unclassified=11, living_street=13,
                 service=14, track=12, pedestrian=13, footway=14, path=14,
                 cycleway=14, steps=15, bridleway=14, via_ferrata=14)


def mercator(coords):
    result = coords.copy()
    result[:, 0] = np.radians(coords[:, 0])*6378137.0
    result[:, 1] = -6378137.0*np.log(np.tan(np.pi/4+np.radians(coords[:, 1])/2))
    return result


def area_kind(tags):
    if tags.get('natural') == 'water' or tags.get('waterway') == 'riverbank' or tags.get('leisure') == 'swimming_pool':
        return 'water'
    if tags.get('building') and tags.get('building') != 'no':
        return 'building'
    if tags.get('natural') in {'wood', 'scrub'} or tags.get('landuse') == 'forest':
        return 'wood'
    if tags.get('leisure') in {'park', 'garden', 'nature_reserve', 'pitch', 'golf_course'} or tags.get('landuse') in {'grass', 'meadow', 'cemetery', 'recreation_ground'} or tags.get('boundary') in {'national_park', 'protected_area'}:
        return 'park'
    if tags.get('natural') in {'beach', 'sand'}:
        return 'sand'
    return None


def build(source, output):
    if output.exists():
        raise SystemExit(f'Refusing to overwrite an existing map database: {output}')
    db = sqlite3.connect(output)
    db.executescript('''PRAGMA journal_mode=WAL;
PRAGMA synchronous=NORMAL;
PRAGMA cache_size=-65536;
CREATE TABLE features(id INTEGER PRIMARY KEY, kind TEXT, subtype TEXT, name TEXT,
                      min_zoom INTEGER, size REAL, flags INTEGER, geometry BLOB);
CREATE VIRTUAL TABLE bounds USING rtree(id,min_x,max_x,min_y,max_y);
CREATE TABLE metadata(key TEXT PRIMARY KEY,value TEXT);
''')
    factory = osmium.geom.WKBFactory()
    counts = Counter()
    skipped = 0
    started = time.monotonic()
    last_report = started
    feature_id = 0
    feature_batch, bounds_batch = [], []

    def flush():
        if feature_batch:
            db.executemany('INSERT INTO features VALUES(?,?,?,?,?,?,?,?)', feature_batch)
            db.executemany('INSERT INTO bounds VALUES(?,?,?,?,?)', bounds_batch)
            db.commit()
            feature_batch.clear()
            bounds_batch.clear()

    area_filter = osmium.filter.KeyFilter('building', 'natural', 'landuse', 'leisure', 'waterway', 'boundary')
    processor = (osmium.FileProcessor(source).with_locations()
                 .with_areas(area_filter)
                 .with_filter(osmium.filter.KeyFilter('highway', 'building', 'natural', 'landuse',
                                                     'leisure', 'waterway', 'place', 'boundary')))
    print('Reading statewide OSM nodes, ways and assembled polygons...', flush=True)
    for obj in processor:
        kind, subtype, zoom, size, flags = None, '', None, 0.0, 0
        tags = obj.tags
        try:
            if obj.is_node():
                subtype = tags.get('place', '')
                if subtype not in {'city', 'town', 'village', 'suburb', 'quarter', 'neighbourhood'} or not tags.get('name'):
                    continue
                kind = 'place'
                zoom = {'city': 5, 'town': 8, 'village': 10}.get(subtype, 13)
                geom = shapely.from_wkb(factory.create_point(obj.location))
            elif obj.is_way():
                highway = tags.get('highway', '')
                if highway in ROAD_ZOOM and tags.get('area') != 'yes':
                    kind, subtype, zoom = 'road', highway, ROAD_ZOOM[highway]
                    if tags.get('access') in {'no', 'private', 'discouraged'}:
                        flags |= 1
                    if tags.get('informal') == 'yes' or tags.get('surface') in {'unpaved', 'dirt', 'ground'}:
                        flags |= 2
                    if tags.get('tunnel') == 'yes':
                        flags |= 4
                    geom = shapely.from_wkb(factory.create_linestring(obj))
                elif tags.get('waterway') in {'river', 'stream', 'canal'}:
                    kind, subtype, zoom = 'waterway', tags['waterway'], 10
                    geom = shapely.from_wkb(factory.create_linestring(obj))
                else:
                    continue
            elif obj.is_area():
                kind = area_kind(tags)
                if not kind:
                    continue
                geom = shapely.from_wkb(factory.create_multipolygon(obj))
                zoom = 16 if kind == 'building' else 8
            else:
                continue
            geom = shapely.transform(geom, mercator)
            if not geom.is_valid:
                geom = shapely.make_valid(geom)
            geom = geom.simplify(.6, preserve_topology=True)
            if geom.is_empty:
                continue
            min_x, min_y, max_x, max_y = geom.bounds
            if max(abs(min_x),abs(max_x),abs(min_y),abs(max_y)) > 21_000_000:
                skipped += 1
                continue
            if kind not in {'road', 'waterway', 'place'}:
                size = geom.area
                if size < 1:
                    continue
                if kind != 'building':
                    zoom = 6 if size > 1e9 else 8 if size > 1e8 else 10 if size > 1e6 else 12 if size > 1e4 else 14
            elif kind in {'road', 'waterway'}:
                size = geom.length
                if size < .1:
                    continue
            feature_id += 1
            feature_batch.append((feature_id, kind, subtype, tags.get('name', ''), zoom, size,
                                  flags, sqlite3.Binary(shapely.to_wkb(geom))))
            bounds_batch.append((feature_id, min_x, max_x, min_y, max_y))
            counts[kind] += 1
            if len(feature_batch) >= 2000:
                flush()
            now = time.monotonic()
            if now-last_report >= 10:
                print(f'{feature_id:,} features indexed in {now-started:.0f}s: {dict(counts)}', flush=True)
                last_report = now
        except (osmium.InvalidLocationError, RuntimeError, ValueError, shapely.errors.GEOSException):
            skipped += 1  # Missing/invalid geometry is omitted, never joined across a gap.
    flush()
    metadata = dict(complete=True, features=feature_id, counts=dict(counts), skipped=skipped,
                    source=str(source.name), source_url='https://www.openstreetmap.org/copyright',
                    attribution='(c) OpenStreetMap contributors', license='ODbL-1.0',
                    elapsed_seconds=round(time.monotonic()-started, 1))
    db.execute('INSERT INTO metadata VALUES(?,?)', ('summary', json.dumps(metadata)))
    db.execute('CREATE INDEX feature_zoom ON features(min_zoom)')
    db.commit()
    db.execute('PRAGMA wal_checkpoint(TRUNCATE)')
    db.close()
    output.with_suffix('.json').write_text(json.dumps(metadata, indent=2)+'\n')
    print(json.dumps(metadata, indent=2), flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    build(args.source, args.output)
