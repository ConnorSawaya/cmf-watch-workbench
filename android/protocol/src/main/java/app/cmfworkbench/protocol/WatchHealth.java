package app.cmfworkbench.protocol;

import static app.cmfworkbench.protocol.Bytes.*;

import java.util.*;

public final class WatchHealth {
  public record Activity(long timestamp, long steps, long meters, long milliCalories) {}

  public record Point(long timestamp, int metric, long value) {}

  public record Sleep(long start, long end, int deep, int light, int rem, int awake) {}

  public final NavigableMap<Long, Activity> activity = new TreeMap<>();
  public final Map<String, Point> points = new LinkedHashMap<>();
  public final NavigableMap<Long, Sleep> sleep = new TreeMap<>();
  public volatile long syncedAt;

  public void merge(WatchHealth other) {
    if (other == this) return;
    List<Activity> a;
    List<Point> p;
    List<Sleep> s;
    synchronized (other) {
      a = new ArrayList<>(other.activity.values());
      p = new ArrayList<>(other.points.values());
      s = new ArrayList<>(other.sleep.values());
    }
    synchronized (this) {
      for (Activity v : a) activity.put(v.timestamp(), v);
      for (Point v : p) points.put(v.metric() + ":" + v.timestamp(), v);
      for (Sleep v : s) sleep.put(v.start(), v);
      syncedAt = other.syncedAt;
      while (activity.size() > 15000) activity.pollFirstEntry();
      while (sleep.size() > 100) sleep.pollFirstEntry();
      while (points.size() > 30000) points.remove(points.keySet().iterator().next());
    }
  }

  private static boolean plausible(long t) {
    return t >= 1577836800L && t <= 4102444800L;
  }

  public synchronized void ingest(int ability, int command, byte[] b) {
    if (command != 1) return;
    if (ability == 0x56 && b.length % 32 == 0) {
      for (int i = 0; i < b.length; i += 32) {
        long t = le(b, i, 4);
        if (plausible(t))
          activity.put(t, new Activity(t, le(b, i + 4, 4), le(b, i + 8, 4), le(b, i + 12, 4)));
      }
    } else if (ability == 0x53
        || ability == 0x55
        || ability == 0x9d
        || ability == 0xda
        || ability == 0xe0) {
      int stride = ability == 0xda ? 5 : 8;
      if (b.length % stride != 0) return;
      for (int i = 0; i < b.length; i += stride) {
        long t = le(b, i, 4), value = le(b, i + 4, stride - 4);
        long max = ability == 0x55 ? 100 : ability == 0x9d ? 99 : 250;
        if (plausible(t) && value >= 1 && value <= max)
          points.put(ability + ":" + t, new Point(t, ability, value));
      }
    } else if (ability == 0x58 && b.length >= 18 && (b.length - 18) % 8 == 0) {
      long a = le(b, 0, 4), z = le(b, 4, 4);
      if (plausible(a) && z > a && z - a <= 172800)
        sleep.put(
            a,
            new Sleep(
                a,
                z,
                (int) le(b, 8, 2),
                (int) le(b, 10, 2),
                (int) le(b, 12, 2),
                (int) le(b, 14, 2)));
    }
    while (activity.size() > 15000) activity.pollFirstEntry();
    while (sleep.size() > 100) sleep.pollFirstEntry();
    while (points.size() > 30000) points.remove(points.keySet().iterator().next());
  }
}
