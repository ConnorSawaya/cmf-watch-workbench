package app.cmfworkbench.protocol;

import static app.cmfworkbench.protocol.Bytes.*;

import java.util.*;

/** Read and write byte orders follow the .73 firmware's verified readback. */
public final class Settings {
  public record Battery(int percent, boolean charging) {
    public static Battery decode(byte[] b) {
      require(
          b.length == 2 && (b[0] & 255) <= 100 && (b[1] & 255) <= 1, "Unsupported battery reply");
      return new Battery(b[0] & 255, b[1] == 1);
    }
  }

  public record Alarm(int id, int seconds, boolean enabled, int weekdays, int flag, String label) {}

  public record Contact(String name, String number) {}

  public record Reminder(boolean enabled, int minutes, int quietStart, int quietEnd) {}

  private Settings() {}

  public static List<Alarm> alarms(byte[] b) {
    require(b.length % 40 == 0 && b.length <= 200, "Unsupported alarm reply");
    List<Alarm> out = new ArrayList<>();
    for (int p = 0; p < b.length; p += 40) {
      int seconds = (int) le(b, p, 4), id = b[p + 4] & 255;
      require(seconds < 86400 && id < 5, "Invalid alarm");
      out.add(
          new Alarm(
              id, seconds, b[p + 5] != 0, b[p + 6] & 255, b[p + 7] & 255, text(b, p + 8, 32)));
    }
    return out;
  }

  public static byte[] alarms(List<Alarm> alarms) {
    require(alarms.size() <= 5, "At most five alarms are supported");
    if (alarms.isEmpty()) return new byte[] {0};
    List<Alarm> sorted = new ArrayList<>(alarms);
    sorted.sort(Comparator.comparingInt(Alarm::id));
    byte[] out = new byte[0];
    Set<Integer> ids = new HashSet<>();
    for (int i = 0; i < sorted.size(); i++) {
      Alarm a = sorted.get(i);
      require(
          a.id() >= 0
              && a.id() < 5
              && ids.add(a.id())
              && a.seconds() >= 0
              && a.seconds() < 86400
              && a.weekdays() >= 0
              && a.weekdays() < 128,
          "Invalid alarm");
      out =
          join(
              out,
              be(a.seconds(), 4),
              new byte[] {
                (byte) i, (byte) (a.enabled() ? 1 : 0), (byte) a.weekdays(), (byte) a.flag()
              },
              fixed(a.label(), 32));
    }
    return out;
  }

  public static List<Contact> contacts(byte[] b) {
    require(b.length % 57 == 0 && b.length <= 1140, "Unsupported contact reply");
    List<Contact> out = new ArrayList<>();
    for (int p = 0; p < b.length; p += 57)
      out.add(new Contact(text(b, p, 32), text(b, p + 32, 25)));
    return out;
  }

  public static byte[] contacts(List<Contact> contacts) {
    require(contacts.size() <= 20, "At most twenty contacts are supported");
    if (contacts.isEmpty()) return new byte[] {0};
    byte[] out = new byte[0];
    for (Contact c : contacts) {
      require(
          !c.name().isEmpty()
              && !c.number().isEmpty()
              && c.name().getBytes(java.nio.charset.StandardCharsets.UTF_8).length <= 32
              && c.number().getBytes(java.nio.charset.StandardCharsets.UTF_8).length <= 25,
          "Contact exceeds watch limits");
      out = join(out, fixed(c.name(), 32), fixed(c.number(), 25));
    }
    return out;
  }

  public static Reminder reminder(byte[] b) {
    require(b.length == 11, "Unsupported reminder reply");
    int minutes = be16(b, 1), start = (int) be32(b, 3), end = (int) be32(b, 7);
    require(minutes <= 1440 && start < 86400 && end < 86400, "Invalid reminder");
    return new Reminder(b[0] != 0, minutes, start, end);
  }

  public static byte[] reminder(Reminder r) {
    require(
        r.minutes() >= 1
            && r.minutes() <= 1440
            && r.quietStart() >= 0
            && r.quietStart() < 86400
            && r.quietEnd() >= 0
            && r.quietEnd() < 86400,
        "Invalid reminder");
    return join(
        new byte[] {(byte) (r.enabled() ? 1 : 0)},
        be(r.minutes(), 2),
        be(r.quietStart(), 4),
        be(r.quietEnd(), 4));
  }

  private static long be32(byte[] b, int p) {
    return ((long) be16(b, p) << 16) | be16(b, p + 2);
  }
}
