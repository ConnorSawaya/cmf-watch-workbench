"""Coarse offline elevation sampling for experimental route ascent estimates."""
from functools import lru_cache
import json
import math
from pathlib import Path
import struct
import zipfile

R=6378137


class ElevationGrid:
    def __init__(self,path):
        self.path=Path(path)
        with zipfile.ZipFile(self.path) as archive:
            self.metadata=json.loads(archive.read('metadata.json'))
            self.files=set(archive.namelist())
        self.n=self.metadata['pixels_per_degree']
        if not 1<=self.n<=10000:raise ValueError('Invalid elevation grid')

    @lru_cache(maxsize=16)
    def tile(self,lat,lon):
        name=f'{lat}_{lon}.bin'
        if name not in self.files:return None
        with zipfile.ZipFile(self.path) as archive:data=archive.read(name)
        if len(data)!=self.n*self.n*2:raise ValueError('Invalid elevation tile')
        return data

    def pixel(self,x,y):
        lat=89-y//self.n;lon=x//self.n-180
        tile=self.tile(lat,lon)
        if tile is None:return None
        value=struct.unpack_from('<h',tile,2*((y%self.n)*self.n+x%self.n))[0]
        return None if value==-32768 else value

    def at(self,point):
        x,y=point;lon=math.degrees(x/R);lat=math.degrees(math.atan(math.sinh(-y/R)))
        if not -180<=lon<180 or not -90<lat<=90:return None
        gx=(lon+180)*self.n-.5;gy=(90-lat)*self.n-.5
        ix,iy=math.floor(gx),math.floor(gy);fx,fy=gx-ix,gy-iy
        pixels=[self.pixel(ix,iy),self.pixel(ix+1,iy),self.pixel(ix,iy+1),self.pixel(ix+1,iy+1)]
        if any(p is None for p in pixels):return None
        a,b,c,d=pixels
        return a*(1-fx)*(1-fy)+b*fx*(1-fy)+c*(1-fx)*fy+d*fx*fy

    def route_gain(self,points):
        if len(points)<2:return None
        heights=[]
        for a,b in zip(points,points[1:]):
            ground=math.hypot(b[0]-a[0],b[1]-a[1])*math.cos(math.atan(math.sinh(-(a[1]+b[1])/(2*R))))
            steps=max(1,math.ceil(ground/160))
            for i in range(steps):
                t=i/steps
                h=self.at((a[0]+(b[0]-a[0])*t,a[1]+(b[1]-a[1])*t))
                if h is None:return None
                heights.append(h)
        last=self.at(points[-1])
        if last is None:return None
        heights.append(last)
        # Five-metre hysteresis reduces elevation noise; a 370 m grid also
        # misses smaller climbs, so this must be labelled a rough estimate.
        low=high=heights[0];ascending=False;gain=0
        for value in heights[1:]:
            if ascending:
                high=max(high,value)
                if high-value>=5:
                    gain+=high-low;low=value;ascending=False
            else:
                low=min(low,value)
                if value-low>=5:high=value;ascending=True
        if ascending:gain+=high-low
        return round(gain)
