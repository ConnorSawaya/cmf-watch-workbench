#!/usr/bin/env python3
"""Build a bounded, spatially indexed watch-native regional map.

Source geometry comes from imported OpenStreetMap and optional supplemental data. Sixteen-metre projected quantization/simplification
is lossy. Trails, walking paths, roads, parks and water are retained as separate
parts; names and source segment lengths are preserved. No routing is implied.
"""
import argparse,hashlib,json,math,sqlite3,struct,time,unicodedata,zlib
from collections import Counter,defaultdict
from pathlib import Path
import shapely
import numpy as np
from shapely.geometry import box

ROOT=Path(__file__).resolve().parents[1]
CELL=8192;GRID=16;PAGE=16384;MAGIC=b'WP2MAP1\0';HEADER=64
TRAILS={'path','footway','bridleway','steps','pedestrian','cycleway','track','via_ferrata'}
MAJOR={'motorway','trunk','primary','secondary','tertiary','motorway_link','trunk_link','primary_link','secondary_link','tertiary_link'}
def uint(b,n):
 while n>127:b.append((n&127)|128);n>>=7
 b.append(n)
def integer(b,n):uint(b,2*n if n>=0 else -2*n-1)
def parts(g):
 if g.geom_type=='LineString':return [list(g.coords)],False
 if g.geom_type=='Polygon':return [list(g.exterior.coords)]+[list(r.coords) for r in g.interiors],True
 result=[];closed=False
 if hasattr(g,'geoms'):
  for child in g.geoms:
   p,c=parts(child);result+=p;closed|=c
 return result,closed
def load_region(path):
 """Read a WGS84 GeoJSON mask in the map's south-positive Mercator system."""
 source=json.loads(path.read_text())
 features=source['features'] if source.get('type')=='FeatureCollection' else [source]
 shapes=[shapely.geometry.shape(f['geometry'] if f.get('type')=='Feature' else f) for f in features]
 region=shapely.union_all(shapes)
 if region.is_empty or not region.is_valid or region.geom_type not in ('Polygon','MultiPolygon'):
  raise ValueError('Region must contain valid polygon geometry')
 if not (-180<=region.bounds[0]<=region.bounds[2]<=180 and -85<=region.bounds[1]<=region.bounds[3]<=85):
  raise ValueError('Region must use WGS84 longitude/latitude')
 def project(c):
  return np.column_stack((np.radians(c[:,0])*6378137,-6378137*np.log(np.tan(np.pi/4+np.radians(c[:,1])/2))))
 region=shapely.set_precision(shapely.transform(region,project),GRID,mode='valid_output')
 shapely.prepare(region)
 return region
def build(output,budget,region_path=None,coverage=None,source=None,trail_source=None,profile="hiking"):
 if output.exists():raise SystemExit(f'Refusing to replace {output}')
 stage=output.with_suffix('.stage.sqlite')
 if stage.exists():raise SystemExit(f'Refusing to replace {stage}')
 db=sqlite3.connect(stage);db.execute('PRAGMA journal_mode=OFF');db.execute('PRAGMA synchronous=OFF');db.execute('CREATE TABLE r(x INT,y INT,k INT,b BLOB)')
 names=[''];ids={'':0};counts=Counter();batch=[];started=time.monotonic()
 region=load_region(region_path) if region_path else None
 def name_id(s):
  s=' '.join(unicodedata.normalize('NFKD',s).encode('ascii','ignore').decode().split())[:31]
  if s not in ids:ids[s]=len(names);names.append(s)
  if len(names)>65535:raise ValueError('Too many trail names')
  return ids[s]
 trail_where="(kind='road' AND (subtype IN ('path','bridleway','cycleway','via_ferrata') OR (subtype IN ('footway','steps','pedestrian','track') AND (name<>'' OR (flags&2)<>0)))) OR (kind IN ('park','water') AND size>=100000)"
 if profile=='all-roads':trail_where="kind='road' OR (kind IN ('park','water') AND size>=100000)"
 source_notices=[]
 sources=[(source,trail_where,False)]
 if trail_source:sources.append((trail_source,"kind='road' AND (flags&8)<>0",True))
 for source,where,usgs in sources:
  src=sqlite3.connect(f'file:{source}?mode=ro',uri=True)
  meta=src.execute("SELECT value FROM metadata WHERE key='summary'").fetchone()
  if not meta:raise ValueError('Source database needs attribution metadata')
  notice=json.loads(meta[0])
  if not notice.get('attribution') or not notice.get('license'):raise ValueError('Source attribution and license are required')
  source_notices.append(dict(attribution=notice['attribution'],license=notice['license']))
  query='SELECT kind,subtype,name,flags,size,geometry FROM features WHERE ('+where+')'
  params=()
  if region is not None and not usgs:
   left,top,right,bottom=region.bounds
   query+=' AND id IN (SELECT id FROM bounds WHERE max_x>=? AND min_x<=? AND max_y>=? AND min_y<=?) ORDER BY id'
   params=(left,right,top,bottom)
  cursor=src.execute(query,params)
  while rows:=cursor.fetchmany(4096):
   geoms=shapely.from_wkb([r[5] for r in rows]);geoms=shapely.simplify(geoms,GRID,preserve_topology=True)
   geoms=shapely.set_precision(geoms,GRID,mode='valid_output')
   if region is not None:
    keep=shapely.intersects(region,geoms)
    rows=[row for row,selected in zip(rows,keep) if selected];geoms=geoms[keep]
   for (kind,subtype,name,flags,size,_),g in zip(rows,geoms):
    if g.is_empty:counts['collapsed']+=1;continue
    source_y=g.centroid.y
    if region is not None and not region.covers(g):
     g=shapely.intersection(g,region,grid_size=GRID)
     if g.is_empty:continue
    k=0 if kind=='road' and subtype in TRAILS else 1 if kind=='road' else {'waterway':2,'park':3,'wood':3,'water':4}[kind]
    counts['usgs_source_segments' if usgs else 'osm_source_features']+=1
    if k==0:counts['trail_source_segments']+=1
    # Metadata length is the original source segment, not a whole named trail.
    length=min(0xffffffff,round(size/max(1,math.cosh(source_y/6378137)))) if k<3 else 0
    nid=name_id(name if k==0 or profile=='all-roads' else '');left,top,right,bottom=g.bounds
    for cy in range(math.floor(top/CELL),math.floor(bottom/CELL)+1):
     for cx in range(math.floor(left/CELL),math.floor(right/CELL)+1):
      tile=box(cx*CELL,cy*CELL,(cx+1)*CELL,(cy+1)*CELL)
      clipped=g if tile.covers(g) else shapely.intersection(g,tile)
      ps,closed=parts(clipped)
      if not ps:continue
      # Huge polygon outlines are uncommon; each record is independently
      # bounded. Splitting a polygon would invent closing edges, so refuse it.
      if closed and sum(map(len,ps))>2000:counts['oversized_polygon_parts']+=1;continue
      groups=[ps] if closed else [[p[start:start+180]] for p in ps for start in range(0,max(0,len(p)-1),179)]
      for group in groups:
       body=bytearray([k,flags&15]);body+=struct.pack('<HI',nid,length);body.append(int(closed));uint(body,len(group));points=0
       for part in group:
        coords=[]
        for x,y in part:
         p=(round(x/GRID)-cx*(CELL//GRID),round(y/GRID)-cy*(CELL//GRID))
         if not coords or coords[-1]!=p:coords.append(p)
        uint(body,len(coords));px=py=0
        for x,y in coords:integer(body,x-px);integer(body,y-py);px,py=x,y
        points+=len(coords)
       if points<2:continue
       if len(body)+2>PAGE:raise ValueError('Feature exceeds page')
       record=struct.pack('<H',len(body))+body
       batch.append((cx,cy,k,record));counts['records']+=1;counts['vertices']+=points
   if batch:db.executemany('INSERT INTO r VALUES(?,?,?,?)',batch);batch=[];db.commit()
   if counts['osm_source_features']%50000<4096:print(dict(counts),f'{time.monotonic()-started:.0f}s',flush=True)
  src.close()
 minx,miny,maxx,maxy=db.execute('SELECT min(x),min(y),max(x),max(y) FROM r').fetchone()
 if minx is None:raise ValueError('No source geometry intersects this region')
 w=maxx-minx+1;h=maxy-miny+1
 names_offset=HEADER+w*h*8;data_offset=names_offset+len(names)*32
 pending=output.with_suffix('.building');entries=[(0,0)]*(w*h);pages=0;raw_total=0
 with pending.open('wb') as f:
  f.write(bytes(data_offset))
  current=None;cell_start=0;raw=bytearray()
  def page():
   nonlocal raw,pages,raw_total
   if not raw:return
   packed=zlib.compress(bytes(raw),9)
   f.write(struct.pack('<HHI',len(packed),len(raw),zlib.crc32(raw)));f.write(packed);raw_total+=len(raw);pages+=1;raw=bytearray()
  def finish():
   if current is None:return
   page();x,y=current;entries[(y-miny)*w+x-minx]=(cell_start,f.tell()-cell_start)
  for x,y,k,record in db.execute('SELECT x,y,k,b FROM r ORDER BY y,x,(k=3) DESC,k DESC'):
   if current!=(x,y):finish();current=(x,y);cell_start=f.tell()
   if len(raw)+len(record)>PAGE:page()
   raw.extend(record)
  finish();size=f.tell()
  f.seek(HEADER)
  for offset,length in entries:f.write(struct.pack('<II',offset,length))
  for name in names:f.write(name.encode().ljust(32,b'\0'))
  header=bytearray(MAGIC+struct.pack('<IIiiHHIIII',1,size,minx,miny,w,h,names_offset,len(names),data_offset,counts['trail_source_segments']))
  header+=struct.pack('<III',GRID,CELL,1)
  header+=bytes(60-len(header));header+=struct.pack('<I',zlib.crc32(header));f.seek(0);f.write(header)
 if size>budget:raise ValueError(f'Watch map needs {size:,} bytes; budget is {budget:,}. Candidate kept for inspection.')
 pending.replace(output);db.close()
 report=dict(format='WP2MAP1',bytes=size,budget=budget,coverage=coverage or 'Selected region: '+profile+' profile',grid_metres=GRID,cell_metres=CELL,**counts,names=len(names),pages=pages,raw_bytes=raw_total,elapsed=round(time.monotonic()-started,1),profile=profile,sha256=hashlib.sha256(output.read_bytes()).hexdigest(),sources=source_notices,overlap='Source segments may overlap; not unique named trails',lossy=True)
 if region_path:report['region']=dict(geojson=str(region_path),sha256=hashlib.sha256(region_path.read_bytes()).hexdigest(),clipping='Selected polygon union snapped to the 16 m projected grid')
 output.with_suffix('.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report,indent=2),flush=True)
if __name__=='__main__':
 p=argparse.ArgumentParser(description=__doc__)
 p.add_argument('--source',type=Path,required=True,help='Database from import_map.py')
 p.add_argument('--trail-source',type=Path,help='Optional compatible supplemental trail database')
 p.add_argument('--output',type=Path,required=True)
 p.add_argument('--budget',type=int,default=9_200_000)
 p.add_argument('--region',type=Path,help='Optional WGS84 GeoJSON polygon mask')
 p.add_argument('--coverage',help='Coverage label')
 p.add_argument('--profile',choices=['hiking','all-roads'],default='hiking')
 a=p.parse_args()
 a.output.parent.mkdir(parents=True,exist_ok=True)
 build(a.output,a.budget,a.region,a.coverage,a.source,a.trail_source,a.profile)
