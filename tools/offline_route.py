"""Experimental local walking routes over the compact map's simplified lines."""
import heapq
import math

EARTH = 6371000
MERCATOR = 6378137
ALLOWED = {'primary','secondary','tertiary','residential','unclassified','living_street',
           'pedestrian','service','track','footway','path','cycleway','steps','bridleway',
           'primary_link','secondary_link','tertiary_link'}


def distance(a, b):
    lat1 = math.atan(math.sinh(-a[1]/MERCATOR))
    lat2 = math.atan(math.sinh(-b[1]/MERCATOR))
    dl = (b[0]-a[0])/MERCATOR
    h = math.sin((lat2-lat1)/2)**2 + math.cos(lat1)*math.cos(lat2)*math.sin(dl/2)**2
    return 2*EARTH*math.asin(min(1, math.sqrt(max(0, h))))


def closest(point, a, b):
    dx, dy = b[0]-a[0], b[1]-a[1]
    denom = dx*dx+dy*dy
    t = max(0, min(1, ((point[0]-a[0])*dx+(point[1]-a[1])*dy)/denom)) if denom else 0
    p = (a[0]+t*dx, a[1]+t*dy)
    return (point[0]-p[0])**2+(point[1]-p[1])**2, t, p


def route_lines(features, start, end, max_segments=350000):
    graph = {}
    nearest = [None, None]
    segments = 0
    def connect(a,b,w):
        graph.setdefault(a,[]).append((b,w))
        graph.setdefault(b,[]).append((a,w))
    for feature in features:
        if feature['k'] != 'road' or feature['t'] not in ALLOWED or feature['f'] & 9:
            continue
        geom=feature['g']
        parts = [geom['coordinates']] if geom['type']=='LineString' else geom['coordinates'] if geom['type']=='MultiLineString' else []
        for part in parts:
            for left,right in zip(part,part[1:]):
                a,b=tuple(left),tuple(right)
                if a==b: continue
                segments+=1
                if segments>max_segments:
                    return {'status':'too_large','message':'This area is too detailed to calculate a route.'}
                w=distance(a,b)
                connect(a,b,w)
                for i,point in enumerate((start,end)):
                    d,t,p=closest(point,a,b)
                    if nearest[i] is None or d<nearest[i][0]:
                        nearest[i]=(d,t,p,a,b,w)
    if any(item is None for item in nearest):
        return {'status':'no_route','message':'No walking paths found nearby.'}
    offsets=[distance(point,item[2]) for point,item in zip((start,end),nearest)]
    if max(offsets)>100:
        return {'status':'no_route','message':'Start or destination is more than 100 m from a mapped path.'}
    # Separate virtual nodes let two positions snap to the same segment.
    virtual=[('start',),('end',)]
    for node,item in zip(virtual,nearest):
        _,t,p,a,b,w=item
        connect(node,a,w*t);connect(node,b,w*(1-t))
    a,b=nearest
    if (a[3]==b[3] and a[4]==b[4]) or (a[3]==b[4] and a[4]==b[3]):
        connect(virtual[0],virtual[1],distance(a[2],b[2]))
    queue=[(0,0,0,virtual[0])]; costs={virtual[0]:0}; previous={}; serial=0
    while queue:
        _, cost, _, node=heapq.heappop(queue)
        if cost!=costs.get(node):continue
        if node==virtual[1]:break
        for neighbor,weight in graph.get(node,()):
            new=cost+weight
            if new<costs.get(neighbor,math.inf):
                costs[neighbor]=new;previous[neighbor]=node;serial+=1
                pos=nearest[1][2] if neighbor==virtual[1] else neighbor
                heapq.heappush(queue,(new+distance(pos,nearest[1][2]),new,serial,neighbor))
    if virtual[1] not in costs:
        return {'status':'no_route','message':'No connected walking route found in this area.'}
    nodes=[]; node=virtual[1]
    while node!=virtual[0]:
        nodes.append(nearest[1][2] if node==virtual[1] else node);node=previous[node]
    nodes.append(nearest[0][2]);nodes.reverse()
    return {'status':'ok','coordinates':[list(start),*[list(p) for p in nodes],list(end)],
            'distance_m':round(costs[virtual[1]]+sum(offsets)),
            'straight_line_m':round(distance(start,end)),
            'start_offset_m':round(offsets[0]),'end_offset_m':round(offsets[1]),'approximate':True}


def find_route(compact,start,end):
    direct=distance(start,end)
    if direct>16000:
        return {'status':'too_far','message':'Walking routes are limited to 10 miles in this preview.'}
    # Web Mercator metres grow with latitude. Include room for local detours.
    lat=math.atan(math.sinh(-(start[1]+end[1])/2/MERCATOR))
    padding=max(1400,min(3500,direct*.35))/max(.3,math.cos(lat))
    bounds=(min(start[0],end[0])-padding,min(start[1],end[1])-padding,
            max(start[0],end[0])+padding,max(start[1],end[1])+padding)
    return route_lines(compact.route_features(bounds),start,end)
