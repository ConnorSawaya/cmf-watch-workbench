"""Compact, independently compressed map chunks; no external runtime packages."""
import math
import json
from pathlib import Path
import struct
import zlib

MAGIC = b'CMFMAP1\0'
HEADER = struct.Struct('<8sQQ')
KINDS = ('road', 'building', 'waterway', 'park', 'water', 'wood', 'sand', 'place')
CELL = 2048


def read_index(path):
    path=Path(path)
    with path.open('rb') as stream:
        header=stream.read(HEADER.size)
        if len(header)!=HEADER.size:
            raise ValueError('truncated compact map header')
        magic,offset,length=HEADER.unpack(header)
        if magic!=MAGIC or offset<HEADER.size or offset+length!=path.stat().st_size:
            raise ValueError('invalid compact map header')
        stream.seek(offset)
        return json.loads(zlib.decompress(stream.read(length))),offset,length


def put_uint(out, value):
    if value < 0:
        raise ValueError('negative unsigned integer')
    while value > 127:
        out.append((value & 127) | 128)
        value >>= 7
    out.append(value)


def put_int(out, value):
    put_uint(out, value*2 if value >= 0 else -value*2-1)


class Reader:
    def __init__(self, data):
        self.data, self.pos = data, 0

    def uint(self):
        value = shift = 0
        while shift <= 63:
            if self.pos >= len(self.data):
                raise ValueError('truncated map integer')
            byte = self.data[self.pos]
            self.pos += 1
            value |= (byte & 127) << shift
            if byte < 128:
                return value
            shift += 7
        raise ValueError('oversized map integer')

    def integer(self):
        value = self.uint()
        return -(value//2)-1 if value & 1 else value//2

    def take(self, count):
        if count < 0 or self.pos+count > len(self.data):
            raise ValueError('truncated map record')
        result = self.data[self.pos:self.pos+count]
        self.pos += count
        return result


def encode_wkb(wkb, origin, grid):
    """2D WKB to explicit rings/parts and delta-coded grid coordinates."""
    offset = 0
    out = bytearray()

    def uint(endian):
        nonlocal offset
        value = struct.unpack_from(endian+'I', wkb, offset)[0]
        offset += 4
        return value

    def sequence(endian, count, ring=False):
        nonlocal offset
        coords = struct.unpack_from(endian+str(count*2)+'d', wkb, offset)
        offset += count*16
        points = []
        for i in range(0, len(coords), 2):
            point = (round(coords[i]/grid), round(coords[i+1]/grid))
            if not points or point != points[-1]:
                points.append(point)
        if ring and len(points)>1 and points[-1] == points[0]:
            points.pop()
        if len(points) < (3 if ring else 2 if count>1 else 1):
            raise ValueError('geometry collapsed on the coordinate grid')
        put_uint(out, len(points))
        previous = origin
        for x, y in points:
            put_int(out, x-previous[0]); put_int(out, y-previous[1])
            previous = (x, y)

    def geometry():
        nonlocal offset
        endian = '<' if wkb[offset] == 1 else '>'
        offset += 1
        kind = uint(endian)
        if not 1 <= kind <= 7:
            raise ValueError('only two-dimensional WKB is supported')
        out.append(kind)
        if kind == 1:
            sequence(endian, 1)
        elif kind == 2:
            sequence(endian, uint(endian))
        elif kind == 3:
            count = uint(endian); put_uint(out, count)
            for _ in range(count):
                sequence(endian, uint(endian), ring=True)
        else:
            count = uint(endian); put_uint(out, count)
            for _ in range(count):
                geometry()

    geometry()
    if offset != len(wkb):
        raise ValueError('extra WKB data')
    return bytes(out)


def decode_geometry(reader, origin, grid, extent=None):
    kind = reader.take(1)[0]

    def sequence(ring=False):
        count = reader.uint()
        if not 0 < count <= len(reader.data)//2:
            raise ValueError('invalid coordinate count')
        x, y = origin
        points = []
        for _ in range(count):
            x += reader.integer(); y += reader.integer()
            px,py=x*grid,y*grid
            points.append([px,py])
            if extent is not None:
                extent[0]=min(extent[0],px);extent[1]=min(extent[1],py)
                extent[2]=max(extent[2],px);extent[3]=max(extent[3],py)
        if ring:
            points.append(points[0].copy())
        return points

    if kind == 1:
        points = sequence()
        if len(points) != 1:
            raise ValueError('invalid point geometry')
        return {'type': 'Point', 'coordinates': points[0]}
    if kind == 2:
        return {'type': 'LineString', 'coordinates': sequence()}
    if kind == 3:
        return {'type': 'Polygon', 'coordinates': [sequence(True) for _ in range(reader.uint())]}
    if kind not in (4, 5, 6, 7):
        raise ValueError('unknown geometry type')
    count = reader.uint()
    if count > len(reader.data):
        raise ValueError('invalid geometry part count')
    children = [decode_geometry(reader, origin, grid, extent) for _ in range(count)]
    if kind == 7:
        return {'type': 'GeometryCollection', 'geometries': children}
    expected = {4: 'Point', 5: 'LineString', 6: 'Polygon'}[kind]
    if any(part['type'] != expected for part in children):
        raise ValueError('invalid geometry part type')
    return {'type': 'Multi'+expected, 'coordinates': [part['coordinates'] for part in children]}


def encode_record(kind, subtype, name, flags, size, bounds, wkb, origin, grid):
    out = bytearray([KINDS.index(kind) | (flags << 3)])
    put_uint(out, subtype); put_uint(out, name); put_uint(out, max(0, round(size)))
    geometry = encode_wkb(wkb, origin, grid)
    put_uint(out, len(geometry)); out.extend(geometry)
    return out


def decode_records(data, origin, grid, names, subtypes, bounds=None, scale=0, zoom=20):
    reader = Reader(data)
    while reader.pos < len(data):
        header = reader.take(1)[0]
        kind, flags = KINDS[header & 7], header >> 3
        subtype_id, name_id, size = reader.uint(), reader.uint(), reader.uint()
        if subtype_id >= len(subtypes) or name_id >= len(names):
            raise ValueError('invalid map string reference')
        subtype = subtypes[subtype_id]
        length = reader.uint()
        if reader.pos+length > len(data):
            raise ValueError('truncated map geometry')
        skip = kind not in ('road','waterway','place') and size<scale*scale*2
        skip |= kind=='waterway' and subtype=='stream' and zoom<13
        if skip:
            reader.pos += length
            continue
        geometry_reader = Reader(reader.take(length))
        extent = [math.inf,math.inf,-math.inf,-math.inf]
        geometry = decode_geometry(geometry_reader, origin, grid, extent)
        if geometry_reader.pos != length:
            raise ValueError('extra map geometry data')
        if bounds is not None and (extent[0]>bounds[2] or extent[2]<bounds[0] or extent[1]>bounds[3] or extent[3]<bounds[1]):
            continue
        yield {'k':kind, 't':subtype, 'n':names[name_id], 'f':flags, 'g':geometry}, size
