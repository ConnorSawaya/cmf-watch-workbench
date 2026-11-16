#!/usr/bin/env python3
"""Convert the source database to a compact chunk pack without per-feature indexes."""
import argparse
from collections import Counter
import json
import math
from pathlib import Path
import sqlite3
import time
import zlib

import numpy as np
import shapely

from tiny_codec import CELL, HEADER, MAGIC, encode_record

ROOT = Path(__file__).resolve().parents[1]


def build(source, output, grid=4.0, tolerance=4.0, sample=False, cell=8192, budget=200000000, usgs=False, states=None):
    if output.exists():
        raise SystemExit(f'Refusing to overwrite {output}')
    pending=output.with_suffix('.building')
    if pending.exists():
        raise SystemExit(f'Refusing to overwrite {pending}')
    temporary = output.with_suffix('.staging.sqlite')
    if temporary.exists():
        raise SystemExit(f'Refusing to overwrite {temporary}')
    started = time.monotonic()
    names, subtypes = [''], ['']
    name_ids, subtype_ids = {'':0}, {'':0}
    counts, dropped = Counter(), Counter()
    stage = sqlite3.connect(temporary)
    stage.executescript('''PRAGMA journal_mode=OFF; PRAGMA synchronous=OFF;
PRAGMA cache_size=-131072; PRAGMA temp_store=FILE;
CREATE TABLE records(x INTEGER,y INTEGER,z INTEGER,l REAL,t REAL,r REAL,b REAL,record BLOB);''')
    db = sqlite3.connect(f'file:{source.resolve()}?mode=ro', uri=True)
    query = 'SELECT kind,subtype,name,flags,min_zoom,size,geometry FROM features'
    if sample:
        # Equal windows along source IDs sample its nodes, ways and area imports.
        last = db.execute('SELECT MAX(id) FROM features').fetchone()[0]
        clauses = [f'id BETWEEN {1+i*last//64} AND {1+i*last//64+1023}' for i in range(64)]
        query += ' WHERE '+' OR '.join(clauses)
    cursor = db.execute(query)
    processed = 0
    last_report = started
    while rows := cursor.fetchmany(4096):
        geoms = shapely.from_wkb([row[6] for row in rows])
        geoms = shapely.simplify(geoms, tolerance=tolerance, preserve_topology=True)
        geoms = shapely.set_precision(geoms, grid, mode='valid_output')
        bounds = shapely.bounds(geoms)
        sizes = np.where(np.isin([row[0] for row in rows], ['road','waterway']),
                         shapely.length(geoms), shapely.area(geoms))
        wkbs = shapely.to_wkb(geoms)
        batch = []
        for row, geom, bbox, size, wkb in zip(rows, geoms, bounds, sizes, wkbs):
            kind, subtype, name, flags, zoom = row[:5]
            if geom.is_empty:
                dropped[kind] += 1
                continue
            name_id = name_ids.get(name)
            if name_id is None:
                name_id = len(names); names.append(name); name_ids[name] = name_id
            subtype_id = subtype_ids.get(subtype)
            if subtype_id is None:
                subtype_id = len(subtypes); subtypes.append(subtype); subtype_ids[subtype] = subtype_id
            x, y = math.floor((bbox[0]+bbox[2])/2/cell), math.floor((bbox[1]+bbox[3])/2/cell)
            origin = (round(x*cell/grid), round(y*cell/grid))
            try:
                record = encode_record(kind,subtype_id,name_id,flags,size,bbox,wkb,origin,grid)
            except ValueError:
                dropped[kind] += 1
                continue
            batch.append((x,y,zoom,*bbox,record))
            counts[kind] += 1
        stage.executemany('INSERT INTO records VALUES(?,?,?,?,?,?,?,?)', batch)
        stage.commit()
        processed += len(rows)
        if time.monotonic()-last_report>=15:
            print(f'Encoded {processed:,} source features in {time.monotonic()-started:.0f}s',flush=True)
            last_report = time.monotonic()
    source_metadata=json.loads(db.execute("SELECT value FROM metadata WHERE key='summary'").fetchone()[0])
    db.close()
    print('Grouping nearby features and compressing independent chunks...',flush=True)
    chunks = []
    compressed_bytes = raw_bytes = 0
    with pending.open('wb') as pack:
        pack.write(HEADER.pack(MAGIC,0,0))
        key, buffer, bbox, count = None, bytearray(), None, 0

        def flush():
            nonlocal buffer, bbox, count, compressed_bytes, raw_bytes
            if not buffer:
                return
            payload = zlib.compress(buffer,9)
            offset = pack.tell(); pack.write(payload)
            chunks.append([offset,len(payload),*key,*bbox,count])
            compressed_bytes += len(payload); raw_bytes += len(buffer)
            buffer, bbox, count = bytearray(), None, 0

        for x,y,z,left,top,right,bottom,record in stage.execute('SELECT * FROM records ORDER BY x,y,z,CAST(l/512 AS INTEGER),CAST(t/512 AS INTEGER),l,t'):
            next_key = (x,y,z)
            if key != next_key or count>=2048 or len(buffer)>131072:
                flush(); key = next_key
            buffer.extend(record); count += 1
            bbox = [left,top,right,bottom] if bbox is None else [min(bbox[0],left),min(bbox[1],top),max(bbox[2],right),max(bbox[3],bottom)]
        flush()
        summary = dict(complete=True,format='CMFMAP1',counts=dict(counts),dropped_collapsed=dict(dropped),
                       source_features=processed,features=sum(counts.values()),grid_metres=grid,
                       simplification_metres=tolerance,cell_metres=cell,chunks=len(chunks),raw_record_bytes=raw_bytes,
                       compressed_chunk_bytes=compressed_bytes,source=source_metadata['source'],
                       attribution=source_metadata['attribution'],license=source_metadata['license'],
                       sample=sample)
        if usgs:
            summary['additional_trail_source']='USGS National Digital Trails'
            summary['usgs_overlap']='USGS segments may overlap OpenStreetMap trails; not deduplicated'
            summary['trail_only_profile']=True
        index = dict(summary=summary,names=names,subtypes=subtypes,chunks=chunks,
                     states=json.loads(states.read_text()) if states else {'states':[]},
                     sources=[{'name':'OpenStreetMap contributors','url':'https://www.openstreetmap.org/copyright','license':'ODbL-1.0'}])
        encoded_index = zlib.compress(json.dumps(index,separators=(',',':'),ensure_ascii=False).encode(),9)
        index_offset = pack.tell(); pack.write(encoded_index)
        pack.seek(0); pack.write(HEADER.pack(MAGIC,index_offset,len(encoded_index)))
    if pending.stat().st_size>=budget:
        raise SystemExit(f'Candidate is {pending.stat().st_size:,} bytes, exceeding the strict {budget:,}-byte budget. It was not published.')
    pending.replace(output)
    stage.close(); temporary.unlink()
    summary.update(file_bytes=output.stat().st_size,index_bytes=len(encoded_index),
                   elapsed_seconds=round(time.monotonic()-started,1))
    output.with_suffix('.json').write_text(json.dumps(summary,indent=2)+'\n')
    print(json.dumps(summary,indent=2),flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source',type=Path,required=True)
    parser.add_argument('--output',type=Path,required=True)
    parser.add_argument('--grid',type=float,default=4.0)
    parser.add_argument('--tolerance',type=float,default=4.0)
    parser.add_argument('--cell',type=int,default=8192)
    parser.add_argument('--budget',type=int,default=200000000)
    parser.add_argument('--sample',action='store_true')
    parser.add_argument('--usgs',action='store_true',help='Mark this experimental source as including USGS trail segments')
    parser.add_argument('--states',type=Path,help='Optional projected state outline JSON')
    args = parser.parse_args()
    if not .25<=args.grid<=20 or not 0<=args.tolerance<=100 or not 512<=args.cell<=32768 or args.budget<1:
        parser.error('invalid precision or tolerance')
    build(args.source,args.output,args.grid,args.tolerance,args.sample,args.cell,args.budget,args.usgs,args.states)
