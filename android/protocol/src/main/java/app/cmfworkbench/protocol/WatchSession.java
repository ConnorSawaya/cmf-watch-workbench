package app.cmfworkbench.protocol;

import static app.cmfworkbench.protocol.Bytes.*;

import java.io.*;
import java.nio.charset.StandardCharsets;
import java.security.*;
import java.util.*;
import java.util.concurrent.*;
import java.util.function.*;

/** One serialized command owner; GATT callbacks only parse and enqueue data. */
public final class WatchSession implements Transfer.Channel, AutoCloseable {
  public static final String CMD = "0000fff2-0000-1000-8000-00805f9b34fb",
      NOTIFY = "0000fff1-0000-1000-8000-00805f9b34fb",
      SHELL = "77d4ff01-2fe2-2334-0d35-9ccd078f529c",
      SHELL_NOTIFY = "77d4ff02-2fe2-2334-0d35-9ccd078f529c",
      OTA = "02f00000-0000-0000-0000-00000000ff01",
      OTA_NOTIFY = "02f00000-0000-0000-0000-00000000ff02",
      BULK_NOTIFY = "02f00000-0000-0000-0000-00000000ffe2";

  public interface Link {
    void write(String uuid, byte[] data) throws Exception;

    void listen(BiConsumer<String, byte[]> listener);
  }

  private final Link link;
  private final Map<String, Frames.Parser> parsers = new ConcurrentHashMap<>();
  private final BlockingDeque<Frames.Frame> replies = new LinkedBlockingDeque<>(128),
      features = new LinkedBlockingDeque<>(128);
  private final BlockingDeque<byte[]> events = new LinkedBlockingDeque<>(128),
      shell = new LinkedBlockingDeque<>(64);
  private final Frames.Chunks chunks = new Frames.Chunks();
  private volatile byte[] customKey, stockKey;
  public final WatchHealth health = new WatchHealth();

  public WatchSession(Link link) {
    this.link = link;
    link.listen(this::feed);
  }

  private static <T> void queue(BlockingDeque<T> q, T v) {
    if (!q.offer(v)) {
      q.poll();
      q.offer(v);
    }
  }

  private void feed(String uuid, byte[] data) {
    uuid = uuid.toLowerCase(Locale.ROOT);
    if (uuid.equals(SHELL_NOTIFY)) {
      queue(shell, data.clone());
      return;
    }
    if (!uuid.equals(NOTIFY) && !uuid.equals(OTA_NOTIFY) && !uuid.equals(BULK_NOTIFY)) return;
    for (Frames.Frame f : parsers.computeIfAbsent(uuid, u -> new Frames.Parser()).feed(data)) {
      if (f.ability() == 0xffff) {
        if (f.command() == 0xb0a6) queue(events, f.body());
        else queue(replies, f);
      } else {
        byte[] key = stockKey;
        if (key == null) continue;
        byte[] plain = f.body().length == 0 ? new byte[0] : Frames.open(key, f.body());
        if (plain == null) continue;
        byte[] full = chunks.append(f, plain);
        if (full != null) {
          health.ingest(f.ability(), f.command(), full);
          queue(features, new Frames.Frame(f.ability(), f.command(), 1, 1, full));
        }
      }
    }
  }

  public String at(String field) throws Exception {
    require(field.equals("GETVERSION") || field.equals("GETSECRET"), "Read-only AT query required");
    shell.clear();
    link.write(SHELL, ("AT " + field + "\r\n").getBytes(StandardCharsets.UTF_8));
    StringBuilder out = new StringBuilder();
    long end = System.nanoTime() + 7_000_000_000L;
    while (System.nanoTime() < end) {
      byte[] b =
          shell.poll(Math.max(1, (end - System.nanoTime()) / 1000000), TimeUnit.MILLISECONDS);
      if (b == null) break;
      out.append(new String(b, StandardCharsets.UTF_8));
      require(out.length() <= 512, "Invalid watch response");
      String s = out.toString().trim();
      if (s.endsWith(",OK")) {
        require(s.startsWith(field + ":"), "Invalid watch response");
        return s.substring(field.length() + 1, s.length() - 3);
      }
    }
    throw new IOException("Watch shell did not answer");
  }

  private byte[] waitReply(int command, byte[] key, long timeout) throws Exception {
    long end = System.nanoTime() + timeout * 1000000;
    while (System.nanoTime() < end) {
      Frames.Frame f =
          replies.poll(Math.max(1, (end - System.nanoTime()) / 1000000), TimeUnit.MILLISECONDS);
      if (f == null) break;
      if (f.command() == 0xa061) throw new IOException("Pairing challenge rejected");
      if (f.command() != command) continue;
      if (key == null) return f.body();
      byte[] opened = Frames.open(key, f.body());
      if (opened != null) return opened;
    }
    throw new IOException("Watch command timed out");
  }

  private byte[] exchange(int command, byte[] data, int reply, byte[] key, long timeout)
      throws Exception {
    replies.clear();
    link.write(CMD, Frames.packet(command, data, key));
    return waitReply(reply, key, timeout);
  }

  public void openCustom() throws Exception {
    String secret = at("GETSECRET");
    require(secret.length() == 32, "Unsupported app channel key");
    customKey = unhex(secret);
    ping();
  }

  public int[] ping() throws Exception {
    byte[] b = call(0x90a7, new byte[] {0});
    require(b.length == 3 && b[0] == 0, "App loader did not answer");
    return new int[] {b[1] & 255, b[2] & 255};
  }

  @Override
  public byte[] call(int command, byte[] data) throws Exception {
    require(customKey != null, "Connect to the app loader first");
    return exchange(command, data, command | 0xa000, customKey, 6000);
  }

  @Override
  public void send(byte[] data) throws Exception {
    long until = System.nanoTime() + 10_000_000_000L;
    long delay = 20;
    while (true) {
      byte[] r = call(0x90a5, join(new byte[] {(byte) 255}, data));
      int status = r.length > 0 ? r[0] & 255 : 255;
      if (status == 0) return;
      if (status == 7) throw new IOException("Open the destination app on the watch");
      if ((status == 8 || status == 9) && System.nanoTime() < until) {
        Thread.sleep(delay);
        delay = Math.min(500, delay * 2);
        continue;
      }
      throw new IOException("App channel refused message (" + status + ")");
    }
  }

  @Override
  public byte[] receive(long timeout) throws Exception {
    long until = System.nanoTime() + timeout * 1000000;
    while (System.nanoTime() < until) {
      byte[] b =
          events.poll(Math.max(1, (until - System.nanoTime()) / 1000000), TimeUnit.MILLISECONDS);
      if (b == null) break;
      byte[] plain = Frames.open(customKey, b);
      if (plain != null && plain.length >= 3) return Arrays.copyOfRange(plain, 2, plain.length);
    }
    throw new IOException("Watch app message timed out");
  }

  public byte[] pair() throws Exception {
    byte[] secret = unhex(at("GETSECRET"));
    require(secret.length == 16, "Invalid pairing challenge");
    byte[] random = new byte[16];
    new SecureRandom().nextBytes(random);
    byte[] challenge = exchange(0x8047, join(random, sha(join(random, secret))), 0x48, null, 7000);
    require(challenge.length == 48, "Invalid pairing response");
    byte[] other = Arrays.copyOf(challenge, 16);
    require(
        MessageDigest.isEqual(Arrays.copyOfRange(challenge, 16, 48), sha(join(other, secret))),
        "Pairing challenge could not be verified");
    byte[] auth = Arrays.copyOf(sha(join(random, other, secret)), 16);
    link.write(
        CMD,
        Frames.packet(
            0x8049,
            join(new byte[] {(byte) 0xa5}, "CMF Watch Pro 2".getBytes(StandardCharsets.UTF_8)),
            auth));
    resume(auth);
    return auth;
  }

  public void resume(byte[] auth) throws Exception {
    require(auth.length == 16, "Invalid pairing key");
    exchange(
        0x8049,
        join(new byte[] {(byte) 0xa5}, "CMF Watch Pro 2".getBytes(StandardCharsets.UTF_8)),
        0x49,
        auth,
        7000);
    byte[] nonce = exchange(0x804b, new byte[] {(byte) 0xa5}, 0x4c, auth, 7000);
    require(nonce.length >= 16, "Invalid session nonce");
    byte[] key = Arrays.copyOf(sha(join(Arrays.copyOf(nonce, 16), auth)), 16);
    exchange(0x804d, new byte[] {(byte) 0xa5}, 0x4, key, 7000);
    stockKey = key;
  }

  public boolean hasStandardSession() {
    return stockKey != null;
  }

  public byte[] feature(int ability, int command, byte[] data, int expected) throws Exception {
    require(stockKey != null, "Pair standard controls first");
    features.clear();
    int count = Math.max(1, (data.length + 127) / 128);
    for (int i = 0; i < count; i++)
      link.write(
          CMD,
          Frames.packet(
              ability,
              command,
              count,
              i + 1,
              Arrays.copyOfRange(data, i * 128, Math.min(data.length, (i + 1) * 128)),
              stockKey));
    long end = System.nanoTime() + 6_000_000_000L;
    while (System.nanoTime() < end) {
      Frames.Frame f =
          features.poll(Math.max(1, (end - System.nanoTime()) / 1000000), TimeUnit.MILLISECONDS);
      if (f == null) break;
      if (f.ability() == ability && f.command() == expected) return f.body();
    }
    throw new IOException("Watch did not acknowledge this setting");
  }

  public byte[] read(int ability) throws Exception {
    return feature(ability, 2, new byte[] {(byte) 0xa5}, 1);
  }

  public void write(int ability, byte[] data) throws Exception {
    feature(ability, 1, data, 3);
  }

  public Settings.Battery battery() throws Exception {
    return Settings.Battery.decode(feature(0x5c, 1, new byte[] {(byte) 0xa5}, 1));
  }

  public void clock(long epoch, int offsetMillis, long previousLocal, long elapsedSeconds)
      throws Exception {
    require(stockKey != null, "Pair standard controls first");
    long local = epoch + offsetMillis / 1000L;
    require(
        previousLocal == 0 || local >= previousLocal + Math.max(0, elapsedSeconds) - 90,
        "Clock moved backward; sync was stopped");
    link.write(CMD, Frames.packet(0x8004, join(be(epoch, 4), be(offsetMillis, 4)), stockKey));
  }

  public void units(boolean imperial, boolean fahrenheit) throws Exception {
    for (int command : new int[] {0x9067, 0x9068}) {
      byte[] value = new byte[] {1, (byte) ((command == 0x9067 ? imperial : fahrenheit) ? 1 : 0)};
      byte[] ack = exchange(command, value, command | 0xa000, stockKey, 7000);
      require(ack.length == 0 || ack[0] == 0 || ack[0] == 1, "Setting was rejected");
      require(
          Arrays.equals(exchange(command, new byte[] {0}, command | 0xa000, stockKey, 7000), value),
          "Unit setting readback did not match");
    }
  }

  public void syncHealth() throws Exception {
    byte[] ready = exchange(0x8005, new byte[] {(byte) 0xa5}, 0x5, stockKey, 7000);
    require(ready.length > 0 && ready[0] == 1, "Health sync not ready");
    exchange(0x9057, new byte[] {(byte) 0xa5}, 0xa057, stockKey, 15000);
    long end = System.nanoTime() + 240_000_000_000L;
    while (System.nanoTime() < end) {
      Frames.Frame f = replies.poll(20, TimeUnit.SECONDS);
      if (f == null) continue;
      byte[] plain = Frames.open(stockKey, f.body());
      if (f.command() == 5 && plain != null && plain.length > 0 && plain[0] == 2) {
        health.syncedAt = System.currentTimeMillis();
        return;
      }
    }
    throw new IOException("Health sync did not finish");
  }

  @Override
  public void close() {
    link.listen((u, b) -> {});
    stockKey = null;
    customKey = null;
    replies.clear();
    events.clear();
    features.clear();
    shell.clear();
  }
}
