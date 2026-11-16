package app.cmfworkbench.protocol;

import static app.cmfworkbench.protocol.Bytes.*;

import java.io.*;
import java.nio.charset.StandardCharsets;
import java.util.*;

/** WFDL codec for bounded Watch Pro 2 images and independently generated live-clock faces. */
public final class WatchFace {
  public static final int MAX_BYTES = 1_500_000;

  public record Image(int width, int height, int format, byte[] pixels) {
    public Image {
      require(
          width > 0 && height > 0 && width <= 466 && height <= 466,
          "Face images must fit 466 × 466");
      require(pixels.length == pixelBytes(width, height, format), "Invalid face pixels");
      pixels = pixels.clone();
    }
  }

  private final byte[] data;
  public final String name;
  public final List<Image> images;
  public final int decodedBytes;
  public final Image preview;

  public byte[] bytes() {
    return data.clone();
  }

  public static int rawCRC(byte[] b) {
    int c = 0;
    for (byte v : b) {
      c ^= v & 255;
      for (int j = 0; j < 8; j++) c = c >>> 1 ^ ((c & 1) != 0 ? 0xedb88320 : 0);
    }
    return c;
  }

  private static int pixelBytes(int w, int h, int f) {
    return switch (f) {
      case 4 -> w * h * 2;
      case 5 -> w * h * 3;
      case 13 -> (w * h + 1) / 2;
      case 14 -> w * h;
      default -> throw new IllegalArgumentException("Unsupported watch-face image format");
    };
  }

  public WatchFace(byte[] input) {
    byte[] b = input.clone();
    require(b.length >= 78 && b.length <= MAX_BYTES, "Face exceeds the supported file budget");
    require(
        le(b, 4, 4) == 1
            && (b[36] & 255) == 0x20
            && Arrays.equals(Arrays.copyOf(b, 36), Arrays.copyOfRange(b, b.length - 36, b.length)),
        "Invalid WFDL header");
    int start = 39 + (int) le(b, 37, 2), end = b.length - 36;
    require(
        start <= end && le(b, 24, 4) == end && le(b, 28, 4) == end - start,
        "Invalid WFDL sections");
    require(
        (rawCRC(Arrays.copyOfRange(b, 4, start)) & 0xffffffffL) == le(b, 0, 4)
            && (rawCRC(Arrays.copyOfRange(b, start, end)) & 0xffffffffL) == le(b, 32, 4),
        "Watch-face checksum mismatch");
    int n = 8;
    while (n < 23 && b[n] != 0) n++;
    name = new String(b, 8, n - 8, StandardCharsets.UTF_8);
    require(!name.isBlank(), "Missing face name");
    List<Image> found = new ArrayList<>();
    Map<Integer, Integer> spans = new HashMap<>();
    Map<Integer, Integer> indices = new HashMap<>();
    int p = start, total = 0;
    while (p < end) {
      require(end - p >= 8 && found.size() < 256, "Too many face images");
      long header = le(b, p, 4), packed = le(b, p + 4, 4);
      int w = (int) (header >> 10 & 2047), h = (int) (header >> 21 & 2047), f = (int) header & 31;
      require(w > 0 && h > 0 && w <= 466 && h <= 466, "Face images must fit 466 × 466");
      int size = pixelBytes(w, h, f);
      total += size;
      require(
          total <= 2097152 && packed > 0 && packed <= end - p - 8,
          "Face exceeds its image-memory budget");
      indices.put(p, found.size());
      found.add(
          new Image(w, h, f, unpack(Arrays.copyOfRange(b, p + 8, p + 8 + (int) packed), size)));
      spans.put(p, (int) packed + 8);
      p += 8 + (int) packed;
    }
    require(p == end && !found.isEmpty(), "Missing face images");
    Tree tree = new Tree(b, spans);
    tree.read(39, start, 0);
    preview = tree.previewOffset == null ? null : found.get(indices.get(tree.previewOffset));
    data = b;
    images = List.copyOf(found);
    decodedBytes = total;
  }

  private static final class Tree {
    final byte[] b;
    final Map<Integer, Integer> spans;
    int count;
    boolean main;
    Integer previewOffset;

    Tree(byte[] b, Map<Integer, Integer> s) {
      this.b = b;
      spans = s;
    }

    void refs(int p, int end) {
      require(end - p >= 7, "Invalid image references");
      int k = b[p] & 255, n = (int) le(b, p + 1, 2);
      require(n > 0 && n <= 256, "Invalid image count");
      if (k == 1) {
        require(end - p == 3 + 4 * n, "Invalid image references");
        for (int i = 0; i < n; i++)
          require(
              spans.containsKey((int) le(b, p + 3 + i * 4, 4)),
              "Image offset is outside the resource table");
      } else if (k == 0x61 || k == 0x71) {
        require(end - p == 7 + 2 * n, "Invalid image references");
        int at = (int) le(b, p + 3, 4);
        for (int i = 0; i < n; i++) {
          int size = (int) le(b, p + 7 + i * 2, 2);
          require(Objects.equals(spans.get(at), size), "Invalid consecutive image blocks");
          at += size;
        }
      } else throw new IllegalArgumentException("Unsupported image reference");
    }

    void read(int p, int end, int depth) {
      require(depth < 16, "Face tree is too deep");
      while (p < end) {
        require(end - p >= 3, "Invalid face tree");
        int tag = b[p] & 255, n = (int) le(b, p + 1, 2);
        p += 3;
        int stop = p + n;
        require(stop <= end && ++count <= 1024, "Invalid face tree");
        if (depth == 0) {
          require(tag == 0x21 || tag == 0x22 || tag == 0x86, "Invalid face screen");
          if (tag == 0x21) {
            require(!main, "Duplicate main screen");
            main = true;
          }
        }
        if (Set.of(0x21, 0x22, 0x28, 0x30, 0x60).contains(tag)) read(p, stop, depth + 1);
        else if (tag == 1) {
          require(n >= 25, "Invalid widget");
          int x = (short) le(b, p, 2), y = (short) le(b, p + 2, 2);
          require(
              Math.abs(x) <= 1024 && Math.abs(y) <= 1024,
              "Widget is outside the supported screen bounds");
          long w = le(b, p + 4, 2), h = le(b, p + 6, 2);
          require(
              w > 0 && w <= 466 && h > 0 && h <= 466 && (b[p + 13] & 255) < 142,
              "Unsupported widget data");
          refs(p + 18, stop);
        } else if (tag == 8) {
          require(n >= 12, "Invalid preview");
          refs(p + 5, stop);
          if (previewOffset == null) previewOffset = (int) le(b, p + 8, 4);
        } else if (tag == 0x40) {
          require(n == 1 && (b[p] & 127) > 0 && (b[p] & 127) <= 8, "Unsupported digit format");
        } else if (tag == 0x86) {
          require(depth == 0 && n == 64, "Invalid face title");
        } else throw new IllegalArgumentException("Unsupported face widget");
        p = stop;
      }
      if (depth == 0) require(main, "Missing main screen");
    }
  }

  private static void extension(ByteArrayOutputStream out, int n) {
    while (n >= 255) {
      out.write(255);
      n -= 255;
    }
    out.write(n);
  }

  public static byte[] pack(byte[] b) {
    int[] table = new int[65536];
    Arrays.fill(table, -1);
    ByteArrayOutputStream out = new ByteArrayOutputStream();
    int p = 0, anchor = 0, n = b.length;
    while (p + 12 <= n) {
      int
          value =
              (b[p] & 255)
                  | (b[p + 1] & 255) << 8
                  | (b[p + 2] & 255) << 16
                  | (b[p + 3] & 255) << 24,
          h = (value * 0x9e3779b1) >>> 16,
          q = table[h];
      table[h] = p;
      if (q < 0
          || p - q > 65535
          || b[q] != b[p]
          || b[q + 1] != b[p + 1]
          || b[q + 2] != b[p + 2]
          || b[q + 3] != b[p + 3]) {
        p++;
        continue;
      }
      int end = p + 4;
      while (end < n - 5 && b[q + end - p] == b[end]) end++;
      int literals = p - anchor, match = end - p - 4;
      out.write(Math.min(15, literals) << 4 | Math.min(15, match));
      if (literals >= 15) extension(out, literals - 15);
      out.write(b, anchor, literals);
      int distance = p - q;
      out.write(distance & 255);
      out.write(distance >>> 8);
      if (match >= 15) extension(out, match - 15);
      p = end;
      anchor = p;
    }
    int tail = n - anchor;
    out.write(Math.min(15, tail) << 4);
    if (tail >= 15) extension(out, tail - 15);
    out.write(b, anchor, tail);
    return out.toByteArray();
  }

  public static byte[] unpack(byte[] b, int size) {
    require(size > 0 && size <= 2097152, "Invalid decoded image size");
    byte[] out = new byte[size];
    int p = 0, o = 0;
    while (p < b.length) {
      int token = b[p++] & 255, literals = token >>> 4;
      if (literals == 15) {
        int v;
        do {
          require(p < b.length, "Truncated LZ4 length");
          v = b[p++] & 255;
          literals += v;
          require(literals <= size, "Oversized LZ4 literal");
        } while (v == 255);
      }
      require(literals <= b.length - p && literals <= size - o, "Truncated LZ4 literal");
      System.arraycopy(b, p, out, o, literals);
      p += literals;
      o += literals;
      if (p == b.length) {
        require(o == size, "Incomplete LZ4 image");
        return out;
      }
      require(b.length - p >= 2, "Truncated LZ4 match");
      int distance = (b[p] & 255) | (b[p + 1] & 255) << 8;
      p += 2;
      int match = token & 15;
      if (match == 15) {
        int v;
        do {
          require(p < b.length, "Truncated LZ4 length");
          v = b[p++] & 255;
          match += v;
          require(match <= size, "Oversized LZ4 match");
        } while (v == 255);
      }
      match += 4;
      require(distance > 0 && distance <= o && match <= size - o, "Invalid LZ4 match");
      for (int i = 0; i < match; i++) {
        out[o] = out[o - distance];
        o++;
      }
    }
    throw new IllegalArgumentException("Incomplete LZ4 block");
  }

  private static byte[] node(int tag, byte[] b) {
    return join(new byte[] {(byte) tag}, le(b.length, 2), b);
  }

  public static WatchFace digital(
      String title,
      Image background,
      List<Image> digits,
      List<Image> small,
      List<Image> aod,
      Image colon,
      Image separator,
      Image aodColon,
      Image preview) {
    String name = title.strip().replaceAll("[^ -~]", "");
    if (name.length() > 14) name = name.substring(0, 14);
    require(
        !name.isEmpty() && digits.size() == 10 && small.size() == 10 && aod.size() == 10,
        "Invalid face design");
    require(background.width() == 466 && background.height() == 466, "Invalid face background");
    List<Image> images = new ArrayList<>();
    images.add(background);
    images.addAll(digits);
    images.add(colon);
    images.addAll(small);
    images.add(separator);
    images.addAll(aod);
    images.add(aodColon);
    images.add(preview);
    List<byte[]> blocks = new ArrayList<>();
    for (Image im : images) {
      byte[] packed = pack(im.pixels());
      blocks.add(
          join(
              le(im.format() | im.width() << 10 | im.height() << 21, 4),
              le(packed.length, 4),
              packed));
    }
    Builder tree = new Builder(images, name);
    byte[] first = tree.tree(new int[images.size()]);
    int[] offsets = new int[images.size()];
    int at = 36 + first.length;
    for (int i = 0; i < blocks.size(); i++) {
      offsets[i] = at;
      at += blocks.get(i).length;
    }
    byte[] nodes = tree.tree(offsets),
        resources = join(blocks.toArray(byte[][]::new)),
        header = new byte[36];
    System.arraycopy(le(1, 4), 0, header, 4, 4);
    System.arraycopy(name.getBytes(StandardCharsets.US_ASCII), 0, header, 8, name.length());
    System.arraycopy(le(at, 4), 0, header, 24, 4);
    System.arraycopy(le(resources.length, 4), 0, header, 28, 4);
    System.arraycopy(le(rawCRC(resources), 4), 0, header, 32, 4);
    System.arraycopy(
        le(rawCRC(join(Arrays.copyOfRange(header, 4, 36), nodes)), 4), 0, header, 0, 4);
    return new WatchFace(join(header, nodes, resources, header));
  }

  private static final class Builder {
    final List<Image> images;
    final String name;
    int[] offsets;

    Builder(List<Image> im, String n) {
      images = im;
      name = n;
    }

    byte[] refs(int[] ids) {
      ByteArrayOutputStream out = new ByteArrayOutputStream();
      out.write(1);
      out.writeBytes(le(ids.length, 2));
      for (int i : ids) out.writeBytes(le(offsets[i], 4));
      return out.toByteArray();
    }

    byte[] widget(int tag, int x, int y, int source, int[] ids, int digits) {
      Image im = images.get(ids[0]);
      byte[] meta = new byte[14];
      System.arraycopy(le(im.width(), 2), 0, meta, 0, 2);
      System.arraycopy(le(im.height(), 2), 0, meta, 2, 2);
      meta[4] = 1;
      meta[9] = (byte) source;
      int max =
          switch (source) {
            case 1 -> 24;
            case 11 -> 60;
            case 22 -> 12;
            case 23 -> 31;
            case 36 -> 100;
            default -> 0;
          };
      System.arraycopy(le(max, 3), 0, meta, 11, 3);
      byte[] st = node(1, join(le(x, 2), le(y, 2), meta, refs(ids)));
      return node(tag, digits > 0 ? join(st, node(0x40, new byte[] {(byte) (128 | digits)})) : st);
    }

    int[] bank(int start) {
      int[] b = new int[10];
      for (int i = 0; i < 10; i++) b[i] = start + i;
      return b;
    }

    byte[] clock(int y, int start, int colon) {
      int w = images.get(start).width(), c = images.get(colon).width(), x = (466 - 4 * w - c) / 2;
      return join(
          widget(0x60, x, y, 1, bank(start), 2),
          widget(0x30, x + 2 * w, y, 0, new int[] {colon}, 0),
          widget(0x60, x + 2 * w + c, y, 11, bank(start), 2));
    }

    byte[] tree(int[] o) {
      offsets = o;
      int w = images.get(12).width(), c = images.get(22).width(), x = (466 - 4 * w - c) / 2;
      byte[] date =
          join(
              widget(0x60, x, 290, 0x16, bank(12), 2),
              widget(0x30, x + 2 * w, 290, 0, new int[] {22}, 0),
              widget(0x60, x + 2 * w + c, 290, 0x17, bank(12), 2));
      byte[] pv = node(0x28, node(8, join(new byte[5], refs(new int[] {images.size() - 1}))));
      byte[] main =
          node(
              0x21,
              join(
                  widget(0x30, 0, 0, 0, new int[] {0}, 0),
                  clock(160, 1, 11),
                  date,
                  widget(0x60, (466 - 3 * w) / 2, 355, 0x24, bank(12), 3),
                  pv));
      byte[] label = new byte[64];
      System.arraycopy(name.getBytes(StandardCharsets.US_ASCII), 0, label, 0, name.length());
      return node(0x20, join(main, node(0x22, clock(205, 23, 33)), node(0x86, label)));
    }
  }
}
