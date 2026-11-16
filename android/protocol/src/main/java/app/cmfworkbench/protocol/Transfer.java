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
}
