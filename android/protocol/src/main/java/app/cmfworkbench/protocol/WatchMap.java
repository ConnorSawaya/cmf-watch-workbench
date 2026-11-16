package app.cmfworkbench.protocol;

import static app.cmfworkbench.protocol.Bytes.*;

import java.io.*;
import java.util.*;
import java.util.zip.Inflater;

/** Spatially indexed WP2MAP1 vectors; imports validate every page before use. */
public final class WatchMap {
  public record Feature(
      int kind, int flags, int name, long length, boolean closed, List<int[]> parts) {}

  public record Place(String name, double x, double y) {}

  public final byte[] data;
  public final long crc, trailSegments;
  public final int grid, minX, minY, width, height;
  public final String[] names;
  public final double centerX, centerY, left, top, right, bottom;
  private double boundLeft = Double.POSITIVE_INFINITY,
      boundTop = Double.POSITIVE_INFINITY,
      boundRight = Double.NEGATIVE_INFINITY,
      boundBottom = Double.NEGATIVE_INFINITY;
  private final int[] offsets, lengths;
  private final double[] placeX, placeY;
  private final boolean[] known;
  private final Map<Integer, List<Feature>> cache =
      new LinkedHashMap<>(32, .75f, true) {
        protected boolean removeEldestEntry(Map.Entry<Integer, List<Feature>> e) {
          return size() > 24;
        }
      };

  public WatchMap(byte[] input) throws Exception {
    byte[] b = input.clone();
    require(
        b.length >= 64 && b.length <= 9_200_000 && text(b, 0, 8).equals("WP2MAP1"),
        "Select a WP2MAP1 map under 9.2 MB");
    require(
        le(b, 8, 4) == 1 && le(b, 12, 4) == b.length && crc(Arrays.copyOf(b, 60)) == le(b, 60, 4),
        "Invalid map header checksum or size");
    grid = (int) le(b, 44, 4);
    require(
        (grid == 4 || grid == 8 || grid == 16) && le(b, 48, 4) == 8192 && le(b, 52, 4) == 1,
        "Unsupported map format");
    minX = (int) le(b, 16, 4);
    minY = (int) le(b, 20, 4);
    width = (int) le(b, 24, 2);
    height = (int) le(b, 26, 2);
    int n = (int) le(b, 32, 4), start = (int) le(b, 36, 4), labels = (int) le(b, 28, 4);
    require(
        width > 0
            && height > 0
            && n > 0
            && n <= 65535
            && labels == 64L + (long) width * height * 8
            && start == labels + (long) n * 32
            && start < b.length,
        "Invalid map directory");
    require(
        minX >= -2565
            && minY >= -2565
            && (long) minX + width <= 2565
            && (long) minY + height <= 2565,
        "Map exceeds Mercator coordinate limits");
    data = b;
    crc = crc(b);
    trailSegments = le(b, 40, 4);
    names = new String[n];
    placeX = new double[n];
    placeY = new double[n];
    known = new boolean[n];
    for (int i = 0; i < n; i++) {
      for (int j = 0; j < 32; j++)
        require(
            b[labels + i * 32 + j] == 0
                || (b[labels + i * 32 + j] >= 32 && b[labels + i * 32 + j] <= 126),
            "Invalid map name");
      names[i] = text(b, labels + i * 32, 32);
    }
    offsets = new int[width * height];
    lengths = new int[offsets.length];
    List<int[]> spans = new ArrayList<>();
    for (int i = 0; i < offsets.length; i++) {
      int p = 64 + i * 8, off = (int) le(b, p, 4), len = (int) le(b, p + 4, 4);
      require(
          (len == 0 && off == 0)
              || (off >= start && len > 0 && off < b.length && len <= b.length - off),
          "Invalid map cell span");
      offsets[i] = off;
      lengths[i] = len;
      if (len > 0) {
        spans.add(new int[] {off, off + len});
        decodeCell(i, true);
      }
    }
    spans.sort(Comparator.comparingInt(a -> a[0]));
    require(
        !spans.isEmpty() && spans.get(0)[0] == start && spans.get(spans.size() - 1)[1] == b.length,
        "Missing map cells");
    for (int i = 1; i < spans.size(); i++)
      require(spans.get(i - 1)[1] == spans.get(i)[0], "Overlapping or missing map page");
    require(Double.isFinite(boundLeft), "Map contains no geometry");
    left = boundLeft;
    top = boundTop;
    right = boundRight;
    bottom = boundBottom;
    centerX = (left + right) / 2;
    centerY = (top + bottom) / 2;
  }

  private List<Feature> decodeCell(int tile, boolean index) throws Exception {
    List<Feature> out = new ArrayList<>();
    int p = offsets[tile],
        end = p + lengths[tile],
        originX = (minX + tile % width) * 8192,
        originY = (minY + tile / width) * 8192;
    while (p < end) {
      require(end - p >= 8, "Truncated page header");
      int packed = (int) le(data, p, 2), raw = (int) le(data, p + 2, 2);
      long sum = le(data, p + 4, 4);
      p += 8;
      require(
          packed > 0 && packed <= 16512 && raw > 0 && raw <= 16384 && packed <= end - p,
          "Invalid compressed page");
      Inflater z = new Inflater();
      byte[] body = new byte[raw];
      try {
        z.setInput(data, p, packed);
        int got = 0;
        while (got < raw && !z.finished()) {
          int n = z.inflate(body, got, raw - got);
          require(n > 0, "Truncated compressed page");
          got += n;
        }
        require(
            got == raw && z.finished() && z.getRemaining() == 0 && crc(body) == sum,
            "Map page checksum mismatch");
      } finally {
        z.end();
      }
      p += packed;
      Reader r = new Reader(body);
      while (r.position < body.length) {
        int length = r.half();
        require(length >= 10 && length <= body.length - r.position, "Truncated geometry record");
        int limit = r.position + length,
            kind = r.byteValue(),
            flags = r.byteValue(),
            name = r.half();
        long meters = r.word();
        int closed = r.byteValue();
        require(kind <= 4 && name < names.length && closed <= 1, "Invalid feature metadata");
        int count = r.uint();
        require(count <= 2048, "Too many geometry parts");
        int points = 0;
        List<int[]> parts = new ArrayList<>();
        for (int j = 0; j < count; j++) {
          int n = r.uint();
          points += n;
          require(points <= 2048, "Geometry exceeds bounds");
          int[] xy = new int[n * 2];
          int x = 0, y = 0;
          for (int k = 0; k < n; k++) {
            x += r.signed();
            y += r.signed();
            require(
                x >= 0 && y >= 0 && x <= 8192 / grid && y <= 8192 / grid, "Geometry outside cell");
            xy[k * 2] = originX + x * grid;
            xy[k * 2 + 1] = originY + y * grid;
          }
          if (index)
            for (int k = 0; k < xy.length; k += 2) {
              boundLeft = Math.min(boundLeft, xy[k]);
              boundRight = Math.max(boundRight, xy[k]);
              boundTop = Math.min(boundTop, xy[k + 1]);
              boundBottom = Math.max(boundBottom, xy[k + 1]);
            }
          parts.add(xy);
          if (index && name > 0 && !known[name] && n > 0) {
            known[name] = true;
            placeX[name] = xy[0];
            placeY[name] = xy[1];
          }
        }
        require(r.position == limit, "Invalid geometry record length");
        if (!index) out.add(new Feature(kind, flags, name, meters, closed == 1, parts));
      }
    }
    return out;
  }

  public synchronized List<Feature> visible(double left, double top, double right, double bottom)
      throws Exception {
    int x0 = Math.max(minX, (int) Math.floor(left / 8192)),
        x1 = Math.min(minX + width - 1, (int) Math.floor(right / 8192));
    int y0 = Math.max(minY, (int) Math.floor(top / 8192)),
        y1 = Math.min(minY + height - 1, (int) Math.floor(bottom / 8192));
    List<Feature> out = new ArrayList<>();
    if (x1 < x0 || y1 < y0) return out;
    require((long) (x1 - x0 + 1) * (y1 - y0 + 1) <= 100000, "Zoom in to view map detail");
    for (int y = y0; y <= y1; y++)
      for (int x = x0; x <= x1; x++) {
        int tile = (y - minY) * width + x - minX;
        if (lengths[tile] == 0) continue;
        List<Feature> cell = cache.get(tile);
        if (cell == null) {
          cell = decodeCell(tile, false);
          cache.put(tile, cell);
        }
        out.addAll(cell);
        if (out.size() > 60000) return out;
      }
    return out;
  }

  public List<Place> search(String query, double x, double y) {
    String q = query.trim().toLowerCase(Locale.ROOT);
    if (q.length() < 2) return new ArrayList<>();
    List<Place> out = new ArrayList<>();
    for (int i = 1; i < names.length; i++)
      if (known[i] && names[i].toLowerCase(Locale.ROOT).contains(q))
        out.add(new Place(names[i], placeX[i], placeY[i]));
    out.sort(Comparator.comparingDouble(p -> Math.hypot(p.x() - x, p.y() - y)));
    return new ArrayList<>(out.subList(0, Math.min(300, out.size())));
  }

  private static final class Reader {
    final byte[] bytes;
    int position;

    Reader(byte[] b) {
      bytes = b;
    }

    int byteValue() {
      require(position < bytes.length, "Truncated geometry");
      return bytes[position++] & 255;
    }

    int half() {
      int v = (int) le(bytes, position, 2);
      position += 2;
      return v;
    }

    long word() {
      long v = le(bytes, position, 4);
      position += 4;
      return v;
    }

    int uint() {
      long v = 0;
      for (int shift = 0; shift <= 28; shift += 7) {
        int b = byteValue();
        require(shift < 28 || b <= 7, "Geometry integer exceeds limit");
        v |= (long) (b & 127) << shift;
        if (b < 128) return (int) v;
      }
      throw new IllegalArgumentException("Malformed varint");
    }

    int signed() {
      int n = uint();
      return (n >>> 1) ^ -(n & 1);
    }
  }
}
