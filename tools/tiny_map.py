"""Random access to the compact offline map; only matching chunks are expanded."""
from functools import lru_cache
import base64
import heapq
import json
import math
from pathlib import Path
import unicodedata
import zlib

import numpy as np
import shapely
from shapely.geometry import box, mapping, shape

from tiny_codec import CELL, HEADER, KINDS, Reader, decode_geometry, decode_records, read_index
from offline_route import ALLOWED

SEARCH_TYPES=('city','town','place','trail','road','park','water','building','waterway','wood','sand')
SEARCH_SCALES=(120,70,35,8,12,75,120,4,75,90,50)


def normalize_search(text):
    text=unicodedata.normalize('NFKD',text).casefold()
    return ' '.join(''.join(c if c.isalnum() else ' ' for c in text
                             if not unicodedata.combining(c)).split())


class TinyMap:
    def __init__(self, path):
        self.path = Path(path)
        self.index,offset,length=read_index(self.path)
        self.summary = dict(self.index['summary'],file_bytes=self.path.stat().st_size,
                            index_bytes=length,backend='compact')
        if not self.summary.get('complete') or self.summary.get('sample'):
            raise ValueError('compact map is not a complete statewide pack')
        self.grid = self.summary['grid_metres']
        self.cell = self.summary.get('cell_metres',CELL)
        self.chunks = self.index['chunks']
        numbers = np.asarray(self.chunks, dtype=np.float64)
        self.zooms, self.bounds = numbers[:,4], numbers[:,5:9]
        for item in self.chunks:
            if item[0]<HEADER.size or item[1]<1 or item[0]+item[1]>offset:
                raise ValueError('invalid compact chunk offset')
        self.search_groups = {}
        self.search_keys = {}
        self.places = []
        encoded=self.index.get('search_v1')
        if encoded:
            reader=Reader(zlib.decompress(base64.b64decode(encoded,validate=True)))
            name_id=x=y=0
            while reader.pos<len(reader.data):
                name_id+=reader.uint();kind=reader.uint();x+=reader.integer();y+=reader.integer()
                if name_id>=len(self.index['names']) or kind>=len(SEARCH_TYPES):
                    raise ValueError('invalid search index entry')
                record=(kind,x*self.grid,y*self.grid)
                self.search_groups.setdefault(name_id,[]).append(record)
                if kind in (0,1):
                    self.places.append((name_id,*record))
            self.search_keys={key:normalize_search(self.index['names'][key]) for key in self.search_groups}
            self.place_points=np.asarray([(entry[2],entry[3]) for entry in self.places],dtype=float)
            self.summary['search_locations']=sum(len(group) for group in self.search_groups.values())

    def search(self, query, x, y, limit=300):
        if not self.search_groups:
            raise ValueError('Search is not available in this map pack')
        parts=query.split(',',1)
        term=normalize_search(parts[0])
        if len(term)<2:
            return []
        center=(x,y)
        if len(parts)>1 and normalize_search(parts[1]) not in ('',):
            location=normalize_search(parts[1].split(',')[0])
            matches=[item for item in self.places if self.search_keys[item[0]]==location]
            if not matches:
                return []
            match=min(matches,key=lambda item:item[1])
            center=(match[2],match[3])
        restricted=center!=(x,y)
        names=self.index['names']
        terms=[word[:-1] if len(word)>3 and word.endswith('s') and not word.endswith('ss') else word
               for word in term.split()]
        variants=[{word}|{word[:i]+word[i+1:] for i in range(len(word)-1) if word[i]==word[i+1]}
                  for word in terms]
        has_repeated_letter=any(len(options)>1 for options in variants)

        def rank_name(key):
            if key==term:return 0
            if key.startswith(term):return 1
            if term in key:return 2
            if len(terms)>1 and all(word in key for word in terms):return 3
            if has_repeated_letter and all(any(word in key for word in options) for options in variants):return 4
            return None

        def priority(kind,rank):
            if len(terms)>1:
                return rank*10+(0,0,1,1,3,1,1,4,2,2,2)[kind]
            if rank==0:
                return (0,0,1,1,3,1,1,4,2,2,2)[kind]
            if rank==1:
                return (1,1,2,2,4,2,3,5,3,3,3)[kind]
            return 6+rank

        def candidates():
            for name_id,key in self.search_keys.items():
                rank=rank_name(key)
                if rank is None:
                    continue
                for kind,px,py in self.search_groups[name_id]:
                    distance=math.hypot(px-center[0],py-center[1])
                    if restricted and distance>100000:
                        continue
                    yield ((priority(kind,rank),rank,distance),
                           dict(name=names[name_id],type=SEARCH_TYPES[kind],x=px,y=py,scale=SEARCH_SCALES[kind]))
            if not restricted:
                for state in self.index['states']['states']:
                    rank=rank_name(normalize_search(state['name']))
                    if normalize_search(state['abbr'])==term:
                        rank=0
                    if rank is None:
                        continue
                    points=[point for polygon in state['polygons'] for ring in polygon for point in ring]
                    width=max(p[0] for p in points)-min(p[0] for p in points)
                    height=max(p[1] for p in points)-min(p[1] for p in points)
                    px,py=state['center']
                    yield ((rank,rank,math.hypot(px-center[0],py-center[1])),
                           dict(name=state['name'],type='state',x=px,y=py,scale=math.hypot(width,height)/410))
        ordered=heapq.nsmallest(limit*12,candidates(),key=lambda entry:entry[0])
        result=[];seen=set()
        for _,item in ordered:
            key=(item['name'],item['type'],item['x'],item['y'])
            if key in seen:continue
            seen.add(key)
            if item['type'] not in ('state','city','town','place') and len(self.place_points):
                distances=np.hypot(self.place_points[:,0]-item['x'],self.place_points[:,1]-item['y'])
                nearest=int(np.argmin(distances))
                if distances[nearest]<50000:
                    item['near']=names[self.places[nearest][0]]
            result.append(item)
            if len(result)>=limit:
                break
        return result

    @lru_cache(maxsize=96)
    def read_chunk(self, number):
        chunk = self.chunks[number]
        with self.path.open('rb') as stream:
            stream.seek(chunk[0]); compressed = stream.read(chunk[1])
        data = zlib.decompress(compressed)
        if len(data)>64*1024*1024:
            raise ValueError('compact chunk exceeds the decode limit')
        return data

    def trail_segment(self, name, x, y):
        bounds=(x-self.grid,y-self.grid,x+self.grid,y+self.grid)
        b=self.bounds
        matching=np.flatnonzero((b[:,0]<=bounds[2]) & (b[:,2]>=bounds[0]) &
            (b[:,1]<=bounds[3]) & (b[:,3]>=bounds[1]))
        for number in matching:
            chunk=self.chunks[number]
            origin=(round(chunk[2]*self.cell/self.grid),round(chunk[3]*self.cell/self.grid))
            for feature,_ in decode_records(self.read_chunk(int(number)),origin,self.grid,
                    self.index['names'],self.index['subtypes'],bounds):
                if feature['k']!='road' or feature['n']!=name:continue
                geom=feature['g'];parts=[geom['coordinates']] if geom['type']=='LineString' else geom['coordinates'] if geom['type']=='MultiLineString' else []
                if parts and parts[0] and abs(parts[0][0][0]-x)<self.grid/2 and abs(parts[0][0][1]-y)<self.grid/2:
                    return feature
        return None

    def route_features(self, bounds):
        b = self.bounds
        matching = np.flatnonzero((self.zooms<=20) & (b[:,0]<=bounds[2]) &
            (b[:,2]>=bounds[0]) & (b[:,1]<=bounds[3]) & (b[:,3]>=bounds[1]))
        for number in matching:
            chunk=self.chunks[number]
            origin=(round(chunk[2]*self.cell/self.grid),round(chunk[3]*self.cell/self.grid))
            reader=Reader(self.read_chunk(int(number)))
            while reader.pos<len(reader.data):
                header=reader.take(1)[0]
                kind,flags=KINDS[header&7],header>>3
                subtype_id=reader.uint();reader.uint();reader.uint();length=reader.uint()
                if reader.pos+length>len(reader.data) or subtype_id>=len(self.index['subtypes']):
                    raise ValueError('invalid compact route record')
                subtype=self.index['subtypes'][subtype_id]
                if kind!='road' or subtype not in ALLOWED or flags&9:
                    reader.pos+=length;continue
                geometry_reader=Reader(reader.take(length))
                extent=[math.inf,math.inf,-math.inf,-math.inf]
                geometry=decode_geometry(geometry_reader,origin,self.grid,extent)
                if geometry_reader.pos!=length:
                    raise ValueError('invalid compact route geometry')
                if extent[0]<=bounds[2] and extent[2]>=bounds[0] and extent[1]<=bounds[3] and extent[3]>=bounds[1]:
                    yield {'k':kind,'t':subtype,'f':flags,'g':geometry}

    def query(self, bounds, scale):
        zoom = math.log2(156543.03392804097/scale)
        if zoom < 5:
            return dict(features=[],zoom=round(zoom,2),truncated=False)
        b = self.bounds
        matching = np.flatnonzero((self.zooms<=math.floor(zoom+.15)) &
            (b[:,0]<=bounds[2]) & (b[:,2]>=bounds[0]) &
            (b[:,1]<=bounds[3]) & (b[:,3]>=bounds[1]))
        candidates = []
        for number in matching:
            chunk = self.chunks[number]
            origin = (round(chunk[2]*self.cell/self.grid),round(chunk[3]*self.cell/self.grid))
            for feature,size in decode_records(self.read_chunk(int(number)),origin,self.grid,
                    self.index['names'],self.index['subtypes'],bounds,scale,zoom):
                candidates.append((feature,chunk[4],size))
        candidates.sort(key=lambda item:(item[0]['k']!='place',item[1],-item[2]))
        limit = 160000 if scale>=800 else 80000 if zoom<12 else 40000
        clipped = box(*bounds)
        records = []
        for feature,_,_ in candidates[:limit]:
            try:
                geometry = shape(feature['g'])
                extent = geometry.bounds
                if extent[0]<bounds[0] or extent[1]<bounds[1] or extent[2]>bounds[2] or extent[3]>bounds[3]:
                    geometry = geometry.intersection(clipped)
                geometry = geometry.simplify(max(.35,scale*.35),preserve_topology=True)
                if not geometry.is_empty:
                    feature['g'] = mapping(geometry); records.append(feature)
            except shapely.errors.GEOSException:
                continue
        return dict(features=records,zoom=round(zoom,2),truncated=len(candidates)>limit,
                    chunks_read=len(matching),backend='compact')
