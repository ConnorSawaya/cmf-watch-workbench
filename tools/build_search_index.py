#!/usr/bin/env python3
"""Add an offline name-to-location index to an existing compact map pack."""
import argparse
import base64
from collections import Counter
import json
import math
from pathlib import Path
import shutil
import time
import zlib

import numpy as np
import shapely
from shapely.geometry import shape

from tiny_codec import CELL, HEADER, KINDS, MAGIC, Reader, put_int, put_uint, read_index

ROOT = Path(__file__).resolve().parents[1]
TYPES = ('city','town','place','trail','road','park','water','building','waterway','wood','sand')


def first_coordinate(data, origin):
    """Read a point lying on a feature without expanding its entire geometry."""
    reader = Reader(data)
    while True:
        kind = reader.take(1)[0]
        if kind == 3:
            if not reader.uint():
                raise ValueError('empty polygon')
        elif kind in (4,5,6,7):
            if not reader.uint():
                raise ValueError('empty geometry collection')
            continue
        elif kind not in (1,2):
            raise ValueError('unknown geometry type')
        if not reader.uint():
            raise ValueError('empty geometry sequence')
        return origin[0]+reader.integer(),origin[1]+reader.integer()


def category(kind,subtype,flags):
    if kind == 'place':
        return 0 if subtype == 'city' else 1 if subtype in ('town','village') else 2
    if kind == 'road':
        trail = subtype in ('path','bridleway','via_ferrata') or (subtype in ('footway','cycleway') and flags&2)
        return 3 if trail else 4
    return {'park':5,'water':6,'building':7,'waterway':8,'wood':9,'sand':10}[kind]


def build(source,output,budget=200000000):
    if output.exists():
        raise SystemExit(f'Refusing to overwrite {output}')
    index,index_offset,_ = read_index(source)
    if not index['summary']['complete'] or index['summary'].get('sample'):
        raise ValueError('search requires a complete map pack')
    grid=index['summary']['grid_metres'];cell=index['summary'].get('cell_metres',CELL)
    groups={}
    started=time.monotonic();last_report=started
    with source.open('rb') as stream:
        for number,chunk in enumerate(index['chunks']):
            stream.seek(chunk[0]);reader=Reader(zlib.decompress(stream.read(chunk[1])))
            origin=(round(chunk[2]*cell/grid),round(chunk[3]*cell/grid))
            while reader.pos<len(reader.data):
                header=reader.take(1)[0]
                subtype_id=reader.uint();name_id=reader.uint();size=reader.uint()
                length=reader.uint()
                if reader.pos+length>len(reader.data):
                    raise ValueError('truncated map geometry')
                if name_id:
                    kind=KINDS[header&7];subtype=index['subtypes'][subtype_id]
                    place_type=category(kind,subtype,header>>3)
                    x,y=first_coordinate(reader.data[reader.pos:reader.pos+length],origin)
                    # Search results point to an actual feature; split widespread names
                    # into regional results while keeping nearby segments together.
                    key=(name_id,place_type,math.floor(x*grid/cell),math.floor(y*grid/cell))
                    previous=groups.get(key)
                    if previous is None or size>previous[0]:
                        groups[key]=(size,x,y)
                reader.pos+=length
            if time.monotonic()-last_report>=15:
                print(f'Indexed {number+1:,} of {len(index["chunks"]):,} map chunks; {len(groups):,} candidate locations',flush=True)
                last_report=time.monotonic()
    kept=[(key[0],key[1],value[1],value[2]) for key,value in groups.items()]
    del groups
    kept.sort()
    raw=bytearray();previous_name=previous_x=previous_y=0
    counts=Counter()
    for name_id,kind,x,y in kept:
        put_uint(raw,name_id-previous_name);put_uint(raw,kind)
        put_int(raw,x-previous_x);put_int(raw,y-previous_y)
        previous_name,previous_x,previous_y=name_id,x,y
        counts[TYPES[kind]]+=1
    payload=zlib.compress(raw,9)
    index['search_v1']=base64.b64encode(payload).decode('ascii')
    index['search_summary']=dict(complete=True,locations=len(kept),types=dict(counts),
                                 encoding='delta-varints+zlib+base64',coordinate_grid_metres=grid)
    encoded_index=zlib.compress(json.dumps(index,separators=(',',':'),ensure_ascii=False).encode(),9)
    size=index_offset+len(encoded_index)
    if size>=budget:
        raise ValueError(f'Searchable map would be {size:,} bytes, above the {budget:,}-byte budget')
    pending=output.with_suffix('.building')
    if pending.exists():
        raise SystemExit(f'Refusing to overwrite {pending}')
    with source.open('rb') as original,pending.open('wb') as target:
        original.seek(HEADER.size);target.write(HEADER.pack(MAGIC,index_offset,len(encoded_index)))
        remaining=index_offset-HEADER.size
        while remaining:
            part=original.read(min(8*1024*1024,remaining))
            if not part:
                raise ValueError('truncated source map')
            target.write(part);remaining-=len(part)
        target.write(encoded_index)
    pending.replace(output)
    result=dict(index['search_summary'],file_bytes=output.stat().st_size,
                search_bytes=len(payload),elapsed_seconds=round(time.monotonic()-started,1))
    output.with_suffix('.search.json').write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps(result,indent=2),flush=True)


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source',type=Path,required=True)
    parser.add_argument('--output',type=Path,required=True)
    parser.add_argument('--budget',type=int,default=200000000)
    args=parser.parse_args()
    build(args.source,args.output,args.budget)
