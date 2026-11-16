package app.cmfworkbench.protocol;

import static app.cmfworkbench.protocol.Bytes.*;
import static org.junit.Assert.*;

import java.io.*;
import java.util.*;
import java.util.concurrent.*;
import java.util.function.*;
import java.util.zip.DeflaterOutputStream;
import org.junit.Test;

public class ProtocolTest {
  @Test
  public void sharedSwiftCryptoVector() {
    byte[] key = unhex("07070707070707070707070707070707"), plain = unhex("68656c6c6f");
    assertEquals("73a9c7cf4bb078dd62ad68184de9c20f", hex(Frames.seal(key, plain)));
    assertArrayEquals(plain, Frames.open(key, Frames.seal(key, plain)));
    assertEquals(
        "f50010ffff0001000190a0a2097c071fb0dfb940c9a92c31d46b6f",
        hex(Frames.packet(0x90a0, new byte[] {(byte) 255}, key)));
  }

  @Test
  public void cryptoRejectsWrongKeysAndCorruption() {
    byte[] key = new byte[16], sealed = Frames.seal(key, new byte[] {1, 2});
    key[0] = 1;
    assertNull(Frames.open(key, sealed));
    sealed[4] ^= 1;
    assertNull(Frames.open(new byte[16], sealed));
    assertNull(Frames.open(key, new byte[] {1}));
  }

  @Test
  public void parserReassemblesAndRecoversFromGarbage() {
    Frames.Parser p = new Frames.Parser();
    byte[] packet = Frames.packet(0x90a7, new byte[] {0}, new byte[16]);
    List<Frames.Frame> out = new ArrayList<>();
    out.addAll(p.feed(new byte[] {7, 8, 9}));
    for (byte b : packet) out.addAll(p.feed(new byte[] {b}));
    assertEquals(1, out.size());
    assertEquals(0x90a7, out.get(0).command());
  }

  @Test
  public void plaintextChallengeOmitsDeclaredCrc() {
    Frames.Parser p = new Frames.Parser();
    byte[] body = new byte[48], packet = Frames.packet(0x48, body, null);
    assertEquals(48, p.feed(Arrays.copyOf(packet, packet.length - 4)).get(0).body().length);
  }

  @Test
  public void outOfSequenceFeatureChunksAreDiscarded() {
    Frames.Chunks c = new Frames.Chunks();
    assertNull(c.append(new Frames.Frame(1, 1, 2, 2, new byte[0]), new byte[] {2}));
    assertNull(c.append(new Frames.Frame(1, 1, 2, 1, new byte[0]), new byte[] {1}));
    assertArrayEquals(
        new byte[] {1, 2}, c.append(new Frames.Frame(1, 1, 2, 2, new byte[0]), new byte[] {2}));
  }

  @Test
  public void alarmWireEndianness() {
    Settings.Alarm a = new Settings.Alarm(0, 25200, true, 0, 0, "Wake");
    byte[] encoded = Settings.alarms(Arrays.asList(a));
    assertArrayEquals(unhex("00006270"), Arrays.copyOf(encoded, 4));
    byte[] reply = encoded.clone();
    System.arraycopy(le(25200, 4), 0, reply, 0, 4);
    assertEquals(a, Settings.alarms(reply).get(0));
  }

  @Test
  public void reminderAndContactRoundTrip() {
    Settings.Reminder r = new Settings.Reminder(true, 45, 79200, 28800);
    assertEquals(r, Settings.reminder(Settings.reminder(r)));
    List<Settings.Contact> people = Arrays.asList(new Settings.Contact("Example", "+10000000000"));
    assertEquals(people, Settings.contacts(Settings.contacts(people)));
  }

  @Test
  public void malformedSettingsFail() {
    assertThrows(
        IllegalArgumentException.class, () -> Settings.Battery.decode(new byte[] {(byte) 150, 0}));
    assertThrows(IllegalArgumentException.class, () -> Settings.alarms(new byte[3]));
    assertThrows(
        IllegalArgumentException.class,
        () -> Settings.reminder(new Settings.Reminder(true, 0, 0, 0)));
  }

  @Test
  public void healthUsesOnlyValidatedReadings() {
    WatchHealth h = new WatchHealth();
    byte[] activity = join(le(1_800_000_000, 4), le(100, 4), le(75, 4), le(2500, 4), new byte[16]);
    h.ingest(0x56, 1, activity);
    h.ingest(0x56, 1, activity);
    assertEquals(1, h.activity.size());
    assertEquals(100, h.activity.firstEntry().getValue().steps());
    h.ingest(0x53, 1, join(le(1_800_000_000, 4), le(999, 4)));
    assertTrue(h.points.isEmpty());
  }

  @Test
  public void preflightBlocksUnverifiedConditions() {
    Transfer.preflight("1.0.0.73", 70, 1000, 255);
    assertThrows(
        IllegalArgumentException.class, () -> Transfer.preflight("1.0.0.74", 70, 1000, 255));
    assertThrows(
        IllegalArgumentException.class, () -> Transfer.preflight("1.0.0.73", 29, 1000, 255));
    assertThrows(
        IllegalArgumentException.class, () -> Transfer.preflight("1.0.0.73", 70, 120000, 255));
    assertThrows(IllegalArgumentException.class, () -> Transfer.preflight("1.0.0.73", 70, 0, 0));
  }

  @Test
  public void packageChecksEveryChecksum() {
    byte[] b = appFixture();
    AppPackage p = new AppPackage(b);
    assertEquals("counter", p.name);
    assertEquals(7, p.version);
    b[90] ^= 1;
    assertThrows(IllegalArgumentException.class, () -> new AppPackage(b));
  }

  @Test
  public void mapChecksAllCompressedPagesAndIndexes() throws Exception {
    WatchMap m = new WatchMap(mapFixture());
    assertEquals(1, m.trailSegments);
    assertEquals("Public Trail", m.search("trail", 0, 0).get(0).name());
    assertEquals(1, m.visible(0, 0, 1000, 1000).size());
    assertTrue(m.visible(100000, 100000, 100001, 100001).isEmpty());
    byte[] bad = mapFixture();
    bad[bad.length - 2] ^= 1;
    assertThrows(Exception.class, () -> new WatchMap(bad));
  }

  @Test
  public void mapTransferResumesAndRequiresReadback() throws Exception {
    WatchMap map = new WatchMap(mapFixture());
    MapPeer peer = new MapPeer(map, 80);
    List<Integer> progress = new ArrayList<>();
    var saved = Transfer.map(peer, map, progress::add, b -> {});
    assertEquals(Integer.valueOf(80), progress.get(0));
    assertEquals(map.data.length, saved.bytes());
    assertArrayEquals(map.data, peer.bytes);
    assertTrue(peer.committed);
    MapPeer broken = new MapPeer(map, 0);
    broken.wrongReadback = true;
    assertThrows(IllegalArgumentException.class, () -> Transfer.map(broken, map, n -> {}, b -> {}));
  }

  @Test
  public void stockAndCustomHandshakeWithFragmentedReplies() throws Exception {
    Peer link = new Peer();
    WatchSession session = new WatchSession(link);
    session.openCustom();
    assertEquals(255, session.ping()[0]);
    byte[] auth = session.pair();
    assertEquals(16, auth.length);
    assertTrue(session.hasStandardSession());
    assertEquals(82, session.battery().percent());
    session.clock(1_800_000_000, 0, 0, 0);
    assertArrayEquals(join(be(1_800_000_000, 4), be(0, 4)), link.clock);
    session.syncHealth();
    assertEquals(1, session.health.activity.size());
    session.close();
  }

  @Test
  public void clockBackwardsIsBlocked() throws Exception {
    Peer peer = new Peer();
    WatchSession session = new WatchSession(peer);
    session.pair();
    assertThrows(IllegalArgumentException.class, () -> session.clock(10000, -3600000, 10000, 60));
    assertNull(peer.clock);
  }

  @Test
  public void actualPythonConverterMapOpensAndSearches() throws Exception {
    String path = System.getProperty("demoMapPath");
    org.junit.Assume.assumeTrue(path != null && new File(path).isFile());
    WatchMap map = new WatchMap(java.nio.file.Files.readAllBytes(new File(path).toPath()));
    assertTrue(map.names.length > 100);
    assertTrue(
        map.visible(map.centerX - 8192, map.centerY - 8192, map.centerX + 8192, map.centerY + 8192)
                .size()
            > 800);
  }

  @Test
  public void cameraUsesImportedBoundsWithoutFabricatingGps() throws Exception {
    WatchMap map = new WatchMap(mapFixture());
    List<byte[]> sent = new ArrayList<>();
    Queue<byte[]> reply = new ArrayDeque<>();
    Transfer.Channel peer =
        new Transfer.Channel() {
          public byte[] call(int c, byte[] b) {
            throw new UnsupportedOperationException();
          }

          public void send(byte[] b) {
            sent.add(b);
            if (b[3] == 1 || b[3] == 3) reply.add(new byte[] {84, 77, 1, (byte) 128, 25, 0, 0});
          }

          public byte[] receive(long timeout) {
            return reply.remove();
          }
        };
    Transfer.mapCamera(peer, map, "Imported region", 25, b -> {});
    assertEquals(3, sent.size());
    byte[] body = Arrays.copyOfRange(sent.get(1), 8, sent.get(1).length);
    assertEquals("TM02", text(body, 0, 4));
    assertEquals(Math.round(map.centerX), le(body, 4, 4));
    assertEquals(0, le(body, 12, 2));
    assertEquals(crc(body), le(sent.get(0), 8, 4));
  }

  static byte[] appFixture() {
    byte[] b = new byte[64 + 512];
    System.arraycopy("WP2A".getBytes(), 0, b, 0, 4);
    b[4] = 1;
    b[7] = 1;
    System.arraycopy(fixed("counter", 24), 0, b, 8, 24);
    put(b, 32, 7, 4);
    put(b, 36, 512, 4);
    put(b, 48, crc(Arrays.copyOfRange(b, 64, b.length)), 4);
    put(b, 52, crc(Arrays.copyOf(b, 52)), 4);
    return b;
  }

  static void put(byte[] b, int p, long value, int n) {
    System.arraycopy(le(value, n), 0, b, p, n);
  }

  static byte[] mapFixture() throws Exception {
    byte[] body =
        join(new byte[] {0, 0}, le(1, 2), le(1000, 4), new byte[] {0, 1, 2, 0, 0, 20, 20});
    byte[] raw = join(le(body.length, 2), body);
    ByteArrayOutputStream compressed = new ByteArrayOutputStream();
    try (DeflaterOutputStream z = new DeflaterOutputStream(compressed)) {
      z.write(raw);
    }
    byte[] page =
        join(
            le(compressed.size(), 2), le(raw.length, 2), le(crc(raw), 4), compressed.toByteArray());
    int start = 64 + 8 + 64, size = start + page.length;
    byte[] b = new byte[size];
    System.arraycopy("WP2MAP1\0".getBytes(), 0, b, 0, 8);
    put(b, 8, 1, 4);
    put(b, 12, size, 4);
    put(b, 24, 1, 2);
    put(b, 26, 1, 2);
    put(b, 28, 72, 4);
    put(b, 32, 2, 4);
    put(b, 36, start, 4);
    put(b, 40, 1, 4);
    put(b, 44, 16, 4);
    put(b, 48, 8192, 4);
    put(b, 52, 1, 4);
    put(b, 60, crc(Arrays.copyOf(b, 60)), 4);
    put(b, 64, start, 4);
    put(b, 68, page.length, 4);
    System.arraycopy(fixed("Public Trail", 32), 0, b, 104, 32);
    System.arraycopy(page, 0, b, start, page.length);
    return b;
  }

  static final class MapPeer implements Transfer.Channel {
    final WatchMap map;
    final Queue<byte[]> replies = new ArrayDeque<>();
    final byte[] bytes;
    int offset;
    boolean committed, wrongReadback;

    MapPeer(WatchMap m, int resume) {
      map = m;
      bytes = new byte[m.data.length];
      System.arraycopy(m.data, 0, bytes, 0, resume);
      offset = resume;
    }

    public byte[] call(int command, byte[] b) {
      throw new UnsupportedOperationException();
    }

    public void send(byte[] b) {
      int op = b[3] & 255;
      if (op == 0x33) {
        replies.add(
            join(
                new byte[] {84, 77, 1, 0x34},
                le(9_000_000, 4),
                le(committed ? bytes.length : 0, 4),
                le(1, 4),
                le(offset, 4),
                le(committed ? (wrongReadback ? 0 : map.crc) : 0, 4),
                le(1, 4)));
      } else if (op == 0x30) {
        replies.add(ack(0xb0, offset));
      } else if (op == 0x31) {
        assertEquals(offset, le(b, 4, 4));
        System.arraycopy(b, 9, bytes, offset, b.length - 9);
        offset += b.length - 9;
        if (b[8] == 1) replies.add(ack(0xb1, offset));
      } else if (op == 0x32) {
        assertEquals(bytes.length, offset);
        assertEquals(map.crc, crc(bytes));
        committed = true;
        replies.add(ack(0xb2, 0));
      }
    }

    public byte[] receive(long timeout) throws IOException {
      byte[] b = replies.poll();
      if (b == null) throw new IOException("No reply");
      return b;
    }

    static byte[] ack(int op, int value) {
      return join(new byte[] {84, 77, 1, (byte) op}, le(value, 4));
    }
  }

  static final class Peer implements WatchSession.Link {
    BiConsumer<String, byte[]> listener = (u, b) -> {};
    final byte[] secret = unhex("00112233445566778899aabbccddeeff"), nonce = new byte[16];
    byte[] auth, stock, clock;

    public void listen(BiConsumer<String, byte[]> l) {
      listener = l;
    }

    void reply(int command, byte[] data, byte[] key) {
      feed(Frames.packet(command, data, key));
    }

    void feed(byte[] data) {
      for (int p = 0; p < data.length; p += 7)
        listener.accept(
            WatchSession.NOTIFY, Arrays.copyOfRange(data, p, Math.min(p + 7, data.length)));
    }

    public void write(String uuid, byte[] bytes) {
      if (uuid.equals(WatchSession.SHELL)) {
        String request = new String(bytes);
        listener.accept(
            WatchSession.SHELL_NOTIFY,
            (request.contains("GETSECRET")
                    ? "GETSECRET:" + hex(secret) + ",OK\r\n"
                    : "GETVERSION:1.0.0.73,OK\r\n")
                .getBytes());
        return;
      }
      Frames.Frame f = new Frames.Parser().feed(bytes).get(0);
      int cmd = f.command();
      if (cmd == 0x8047) {
        byte[] plain = Arrays.copyOf(f.body(), f.body().length - 4),
            random = Arrays.copyOf(plain, 16),
            other = new byte[16];
        Arrays.fill(other, (byte) 3);
        assertArrayEquals(sha(join(random, secret)), Arrays.copyOfRange(plain, 16, 48));
        auth = Arrays.copyOf(sha(join(random, other, secret)), 16);
        byte[] packet = Frames.packet(0x48, join(other, sha(join(other, secret))), null);
        feed(Arrays.copyOf(packet, packet.length - 4));
      } else if (cmd == 0x8049) {
        assertNotNull(Frames.open(auth, f.body()));
        reply(0x49, new byte[] {1}, auth);
      } else if (cmd == 0x804b) {
        reply(0x4c, nonce, auth);
        stock = Arrays.copyOf(sha(join(nonce, auth)), 16);
      } else if (cmd == 0x804d) {
        assertNotNull(Frames.open(stock, f.body()));
        reply(4, new byte[] {1}, stock);
      } else if (cmd == 0x90a7) {
        assertNotNull(Frames.open(secret, f.body()));
        reply(cmd | 0xa000, new byte[] {0, (byte) 255, 0}, secret);
      } else if (f.ability() == 0x5c) {
        feed(Frames.packet(0x5c, 1, 1, 1, new byte[] {82, 0}, stock));
      } else if (cmd == 0x8004) {
        clock = Frames.open(stock, f.body());
      } else if (cmd == 0x8005) {
        reply(5, new byte[] {1}, stock);
      } else if (cmd == 0x9057) {
        reply(0xa057, new byte[] {1}, stock);
        feed(
            Frames.packet(
                0x56,
                1,
                1,
                1,
                join(le(1_800_000_000, 4), le(100, 4), le(75, 4), le(2500, 4), new byte[16]),
                stock));
        reply(5, new byte[] {2}, stock);
      } else throw new IllegalArgumentException("Unexpected test command");
    }
  }
}
