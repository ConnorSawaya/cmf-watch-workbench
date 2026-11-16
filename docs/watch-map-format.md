# Native watch map format

All integers are little endian. WP2MAP1 version 1 has a 64-byte header:

| Offset | Field |
| --- | --- |
| 0 | `WP2MAP1\0` magic, 8 bytes |
| 8, 12 | version and complete file size, u32 |
| 16, 20 | minimum cell x/y, i32 |
| 24, 26 | grid width/height, u16 |
| 28, 32, 36 | name table offset, name count, page data offset, u32 |
| 40 | source trail segment count, u32; overlaps are possible |
| 44, 48, 52 | projected grid spacing, 8192-metre cell size, codec, u32 |
| 56 | reserved, zero |
| 60 | CRC32 of bytes 0–59 |

Coordinates use south-positive Web Mercator. The cell index follows the
header, row by row: absolute page-data offset and byte length, two u32s.
An empty cell has both zero. Names follow the index: up to 65,535 ASCII,
zero-padded 32-byte entries. Entry zero is empty.

Codec 1 pages have an 8-byte header: compressed size u16, raw size u16 and
raw CRC32 u32. Codec 2 adds six u16s: cell-local left/top/right/bottom in
quantized grid units, then inclusive minimum/maximum metres per pixel.
The zlib stream follows. A raw page is at most 16,384 bytes. Codec 2 pages
can be skipped using their spatial bounds and scale before reading the stream.

Each raw record starts with a u16 body length. Its body contains kind u8,
flags u8, name ID u16, original source-segment length u32, closed u8,
then unsigned LEB128 part count. Each part has an unsigned LEB128 vertex
count and zigzag LEB128 x/y deltas, reset to zero at each part. Coordinates
are relative to the cell origin. At most 2,048 vertices are accepted per
record. Kinds are trail, road, waterway, park/woodland and water, numbered
0–4. Separate parts are never joined into invented segments.

Readers validate complete files, contiguous cell spans, page checksums,
record sizes and geometry bounds before transfer. The loader validates
pages again during rendering. RAM caches contain decoded pages and feature
bounding boxes; these are rebuilt and invalidated when a replacement commits.

Loader v5 adds optional map-service operation 7: a 436-byte response with
label count at byte zero, four header bytes, then up to twelve 36-byte
records (screen x/y i16 and name[32]). Older loaders reject the operation;
the SDK returns `None`. Operation 6 retains its existing 80-byte request
and response layout. No stock OTA or firmware ROM addresses change.
