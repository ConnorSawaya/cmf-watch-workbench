package app.cmfworkbench.protocol;

import static app.cmfworkbench.protocol.Bytes.*;
import static org.junit.Assert.*;

import java.io.*;
import java.util.*;
import java.util.function.*;
import org.junit.Test;

public final class WatchFaceTest {
  static WatchFace.Image image(int w, int h, int value) {
    byte[] b = new byte[w * h * 2];
    Arrays.fill(b, (byte) value);
    return new WatchFace.Image(w, h, 4, b);
  }

  static WatchFace fixture() {
    List<WatchFace.Image> main = new ArrayList<>(),
        small = new ArrayList<>(),
        aod = new ArrayList<>();
    for (int i = 0; i < 10; i++) {
      main.add(image(58, 104, i));
      small.add(image(18, 32, i));
      aod.add(image(32, 56, i));
    }
    return WatchFace.digital(
        "Test clock",
        image(466, 466, 0),
        main,
        small,
        aod,
        image(20, 104, 1),
        image(12, 32, 1),
        image(12, 56, 1),
        image(120, 120, 0));
  }

  @Test
  public void compressionAndCorruptFiles() {
    Random r = new Random(42);
    for (int size : new int[] {1, 12, 13, 16, 100, 8192}) {
      byte[] b = new byte[size];
      r.nextBytes(b);
      assertArrayEquals(b, WatchFace.unpack(WatchFace.pack(b), size));
      Arrays.fill(b, (byte) 0);
      assertArrayEquals(b, WatchFace.unpack(WatchFace.pack(b), size));
    }
    assertThrows(Exception.class, () -> WatchFace.unpack(new byte[] {0, 0, 0}, 10));
    WatchFace face = fixture();
    assertEquals(35, face.images.size());
    assertEquals(120, face.preview.width());
    assertTrue(face.bytes().length < 20000);
    byte[] bad = face.bytes();
    bad[bad.length - 1] ^= 1;
    assertThrows(Exception.class, () -> new WatchFace(bad));
  }

  @Test
  public void readsTheProductionSwiftFace() throws Exception {
    File f = new File("../../build/watchface-fixture/face.wfdl");
    if (!f.isFile()) return;
    WatchFace face = new WatchFace(java.nio.file.Files.readAllBytes(f.toPath()));
    assertEquals("Workbench", face.name);
    assertEquals(35, face.images.size());
  }

  static final class Peer implements WatchSession.Link {
    final byte[] auth = new byte[16], nonce = new byte[16], key;
    final boolean invalid;
    final int finish;
    BiConsumer<String, byte[]> listener;
    int length, newID, oldID, pass, frameCount;
    boolean ended;
    ByteArrayOutputStream part = new ByteArrayOutputStream();
    byte[] received;

    Peer(boolean invalid, int finish) {
      this.invalid = invalid;
      this.finish = finish;
      Arrays.fill(auth, (byte) 0x44);
      Arrays.fill(nonce, (byte) 0x55);
      key = Arrays.copyOf(sha(join(nonce, auth)), 16);
    }

    public void listen(BiConsumer<String, byte[]> l) {
      listener = l;
    }

    void reply(int c, byte[] d, boolean face) {
      listener.accept(
          face ? WatchSession.BULK_NOTIFY : WatchSession.NOTIFY,
          Frames.packet(c, d, c == 0x49 || c == 0x4c ? auth : key));
    }

    void request(int offset, int size) {
      reply(0xa064, join(be(offset, 4), be(size, 4), new byte[] {0}), true);
    }

    public void write(String uuid, byte[] b) {
      assertNotEquals(WatchSession.FACE, uuid);
      if (uuid.equals(WatchSession.SHELL)) {
        listener.accept(WatchSession.SHELL_NOTIFY, "GETVERSION:1.0.0.73,OK\r\n".getBytes());
        return;
      }
      int c = be16(b, 9);
      switch (c) {
        case 0x8049 -> reply(0x49, new byte[6], false);
        case 0x804b -> reply(0x4c, nonce, false);
        case 0x804d -> reply(4, new byte[] {1}, false);
        default -> throw new AssertionError("Unexpected command " + c);
      }
    }

    public void writeWithoutResponse(String uuid, byte[] b) {
      assertEquals(WatchSession.FACE, uuid);
      int c = be16(b, 9);
      byte[] raw = Arrays.copyOfRange(b, 11, b.length),
          body = c == 0x9064 ? Arrays.copyOf(raw, raw.length - 4) : Frames.open(key, raw);
      switch (c) {
        case 0x8052 -> reply(0x52, new byte[] {1}, true);
        case 0x9075 -> {
          oldID = (int) le(body, 1, 4);
          newID = (int) le(body, 5, 4);
          length = (int) le(body, 9, 4);
          reply(0xa075, new byte[] {1}, true);
          request(invalid ? length : 0, invalid ? 1 : length);
        }
        case 0x9064 -> {
          assertEquals(crc(body), le(raw, raw.length - 4, 4));
          part.writeBytes(body);
          frameCount++;
          if (be16(b, 7) == be16(b, 5)) {
            if (pass++ == 0) {
              received = part.toByteArray();
              part.reset();
              request(0, Math.min(16, length));
            } else reply(0xa065, new byte[] {(byte) finish}, true);
          }
        }
        case 0x9065 -> ended = true;
        default -> throw new AssertionError("Unexpected face command");
      }
    }
  }

  @Test
  public void faceChannelRetriesAndActivation() throws Exception {
    Peer p = new Peer(false, 1);
    WatchSession s = new WatchSession(p);
    s.resume(p.auth);
    WatchFace f = fixture();
    List<Integer> progress = new ArrayList<>();
    s.uploadFace(f, 12345, false, progress::add);
    assertEquals(0, p.oldID);
    assertEquals(12345, p.newID);
    assertArrayEquals(f.bytes(), p.received);
    assertTrue(p.ended);
    assertTrue(progress.stream().allMatch(n -> n <= f.bytes().length));
    assertEquals(f.bytes().length, (int) progress.get(progress.size() - 1));
  }

  @Test
  public void storedOnlyAndInvalidPullCannotReportSuccess() throws Exception {
    Peer p = new Peer(false, 10);
    WatchSession s = new WatchSession(p);
    s.resume(p.auth);
    Exception e =
        assertThrows(Exception.class, () -> s.uploadFace(fixture(), 12345, false, n -> {}));
    assertTrue(e.getMessage().contains("not activated"));
    assertTrue(p.ended);
    Peer bad = new Peer(true, 1);
    WatchSession other = new WatchSession(bad);
    other.resume(bad.auth);
    assertThrows(Exception.class, () -> other.uploadFace(fixture(), 12345, false, n -> {}));
    assertEquals(0, bad.frameCount);
  }
}
