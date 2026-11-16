package app.cmfworkbench.protocol;

import static app.cmfworkbench.protocol.Bytes.*;

import java.io.IOException;
import java.util.*;
import java.util.function.*;

public final class Transfer {
  public interface Channel {
    byte[] call(int command, byte[] data) throws Exception;

    void send(byte[] data) throws Exception;

    byte[] receive(long timeoutMillis) throws Exception;
  }

  public record MapInfo(
      long freeBytes, long bytes, long trailSegments, long stagedBytes, long crc, long version) {
    public static MapInfo parse(byte[] b) {
      if (b.length != 28 || !Arrays.equals(Arrays.copyOf(b, 4), new byte[] {84, 77, 1, 0x34}))
        return null;
      return new MapInfo(
          le(b, 4, 4), le(b, 8, 4), le(b, 12, 4), le(b, 16, 4), le(b, 20, 4), le(b, 24, 4));
    }
  }

  private Transfer() {}

  public static void preflight(String firmware, Integer battery, long batteryAgeMillis, int slot) {
    require("1.0.0.73".equals(firmware), "Only Watch Pro 2 / JX402 1.0.0.73 is supported");
    require(
        battery != null && battery >= 30 && batteryAgeMillis >= 0 && batteryAgeMillis < 120000,
        "Refresh watch battery; at least 30% is required");
    require(slot == 255, "Close Custom Apps and return the watch to its clock face");
  }

  private static byte[] checked(byte[] b) throws IOException {
    if (b.length == 0 || b[0] != 0)
      throw new IOException(
          b.length > 0 && b[0] == 5
              ? "Close Custom Apps on the watch"
              : "Watch rejected operation (" + (b.length == 0 ? -1 : b[0] & 255) + ")");
    return Arrays.copyOfRange(b, 1, b.length);
  }

  public static List<AppPackage.Header> list(Channel channel) throws Exception {
    List<AppPackage.Header> out = new ArrayList<>();
    for (int slot : new int[] {0, 1, 2, 3, 4, 5, 6, 7, 255}) {
      byte[] h = checked(channel.call(0x90a0, new byte[] {(byte) slot}));
      if (h.length >= 64) out.add(AppPackage.Header.parse(slot, h));
    }
    return out;
  }

  public static int install(Channel channel, AppPackage app, IntConsumer progress)
      throws Exception {
    int slot = 255;
    if (app.kind == 0) {
      List<AppPackage.Header> all = list(channel);
      slot = -1;
      for (var h : all) if (h.slot() < 8 && h.name().equals(app.name)) slot = h.slot();
      if (slot < 0) {
        for (int i = 0; i < 8; i++) {
          final int candidate = i;
          if (all.stream().noneMatch(h -> h.slot() == candidate)) {
            slot = i;
            break;
          }
        }
      }
      require(slot >= 0, "All eight app slots are occupied");
    }
    checked(
        channel.call(
            0x90a1, join(new byte[] {(byte) slot}, le(app.data.length, 4), le(crc(app.data), 4))));
    for (int offset = 0; offset < app.data.length; offset += 128) {
      int next = Math.min(offset + 128, app.data.length);
      byte[] ack =
          checked(
              channel.call(
                  0x90a2, join(le(offset, 4), Arrays.copyOfRange(app.data, offset, next))));
      require(ack.length == 4 && le(ack, 0, 4) == next, "Unexpected app transfer acknowledgement");
      progress.accept(next);
    }
    checked(channel.call(0x90a3, new byte[] {0}));
    final int installedSlot = slot;
    require(
        list(channel).stream()
            .anyMatch(
                h ->
                    h.slot() == installedSlot
                        && h.name().equals(app.name)
                        && h.version() == app.version
                        && h.kind() == app.kind),
        "Watch did not confirm installed app");
    return slot;
  }

  /** A real map camera, not a fabricated GPS position. Existing watch panning is preserved. */
  public static void mapCamera(
      Channel c, WatchMap map, String label, int id, Consumer<byte[]> other) throws Exception {
    int scale =
        (int)
            Math.max(
                1,
                Math.min(
                    60000,
                    Math.ceil(
                        Math.max((map.right - map.left) / 450, (map.bottom - map.top) / 257)
                            * 1.1)));
    byte[] title = fixed(label.replaceAll("[^\\x20-\\x7e]", ""), 32);
    title[31] = 0;
    byte[] body =
        join(
            new byte[] {84, 77, 48, 50},
            le(Math.round(map.centerX), 4),
            le(Math.round(map.centerY), 4),
            le(0, 2),
            le(scale, 2),
            title);
    c.send(join(new byte[] {84, 77, 1, 1}, le(id, 2), le(body.length, 2), le(crc(body), 4)));
    cameraAck(c, id, other);
    c.send(join(new byte[] {84, 77, 1, 2}, le(id, 2), le(0, 2), body));
    c.send(join(new byte[] {84, 77, 1, 3}, le(id, 2)));
    cameraAck(c, id, other);
  }

  private static void cameraAck(Channel c, int id, Consumer<byte[]> other) throws Exception {
    long until = System.nanoTime() + 8_000_000_000L;
    while (System.nanoTime() < until) {
      byte[] b = c.receive(Math.max(1, (until - System.nanoTime()) / 1000000));
      if (b.length == 7
          && b[0] == 84
          && b[1] == 77
          && b[2] == 1
          && (b[3] & 255) == 0x80
          && le(b, 4, 2) == id) {
        require(b[6] == 0, "Watch rejected map camera");
        return;
      }
      other.accept(b);
    }
    throw new IOException("Map camera was not acknowledged");
  }

  public static MapInfo queryMap(Channel c, Consumer<byte[]> other) throws Exception {
    c.send(new byte[] {84, 77, 1, 0x33});
    long end = System.nanoTime() + 12_000_000_000L;
    while (System.nanoTime() < end) {
      byte[] b = c.receive(Math.max(1, (end - System.nanoTime()) / 1000000));
      MapInfo i = MapInfo.parse(b);
      if (i != null) return i;
      other.accept(b);
    }
    throw new IOException("No map status from watch");
  }

  private static int ack(Channel c, int op, Consumer<byte[]> other) throws Exception {
    long end = System.nanoTime() + 30_000_000_000L;
    while (System.nanoTime() < end) {
      byte[] b = c.receive(Math.max(1, (end - System.nanoTime()) / 1000000));
      if (b.length == 8 && b[0] == 84 && b[1] == 77 && b[2] == 1 && (b[3] & 255) == op) {
        int n = (int) le(b, 4, 4);
        if (n < 0) throw new IOException("Map save refused (" + n + ")");
        return n;
      }
      other.accept(b);
    }
    throw new IOException("Map transfer acknowledgement timed out");
  }

  public static MapInfo map(Channel c, WatchMap map, IntConsumer progress, Consumer<byte[]> other)
      throws Exception {
    MapInfo old = queryMap(c, other);
    if (old.bytes() == map.data.length && old.crc() == map.crc && old.version() == 1) {
      progress.accept(map.data.length);
      return old;
    }
    c.send(join(new byte[] {84, 77, 1, 0x30}, le(map.data.length, 4), le(map.crc, 4), le(1, 4)));
    int offset = ack(c, 0xb0, other);
    require(offset <= map.data.length, "Invalid resume offset");
    progress.accept(offset);
    while (offset < map.data.length) {
      int end = Math.min(offset + 116 * 16, map.data.length);
      while (offset < end) {
        if (Thread.currentThread().isInterrupted()) throw new InterruptedException();
        int next = Math.min(offset + 116, end);
        c.send(
            join(
                new byte[] {84, 77, 1, 0x31},
                le(offset, 4),
                new byte[] {(byte) (next == end ? 1 : 0)},
                Arrays.copyOfRange(map.data, offset, next)));
        offset = next;
      }
      require(ack(c, 0xb1, other) == offset, "Invalid map acknowledgement offset");
      progress.accept(offset);
    }
    c.send(new byte[] {84, 77, 1, 0x32});
    require(ack(c, 0xb2, other) == 0, "Map was not saved");
    MapInfo saved = queryMap(c, other);
    require(
        saved.bytes() == map.data.length && saved.crc() == map.crc && saved.version() == 1,
        "Saved map did not match size, checksum and version");
    return saved;
  }
}
