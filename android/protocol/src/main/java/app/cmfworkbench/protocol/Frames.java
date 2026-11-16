package app.cmfworkbench.protocol;

import static app.cmfworkbench.protocol.Bytes.*;

import java.util.*;
import javax.crypto.Cipher;
import javax.crypto.spec.*;

/** Stock wire framing, AES-CBC and CRC. The IV is a public protocol constant. */
public final class Frames {
  private static final byte[] IV = unhex("5051525354555657606162636465665a");

  public record Frame(int ability, int command, int count, int index, byte[] body) {}

  private Frames() {}

  public static byte[] seal(byte[] key, byte[] plain) {
    return aes(Cipher.ENCRYPT_MODE, key, join(plain, le(crc(plain), 4)));
  }

  public static byte[] open(byte[] key, byte[] cipher) {
    if (cipher.length == 0 || cipher.length % 16 != 0) return null;
    try {
      byte[] body = aes(Cipher.DECRYPT_MODE, key, cipher);
      if (body.length < 4) return null;
      byte[] plain = Arrays.copyOf(body, body.length - 4);
      return crc(plain) == le(body, body.length - 4, 4) ? plain : null;
    } catch (IllegalArgumentException e) {
      return null;
    }
  }

  private static byte[] aes(int mode, byte[] key, byte[] b) {
    require(key.length == 16, "Invalid key length");
    try {
      Cipher c = Cipher.getInstance("AES/CBC/PKCS5Padding");
      c.init(mode, new SecretKeySpec(key, "AES"), new IvParameterSpec(IV));
      return c.doFinal(b);
    } catch (Exception e) {
      throw new IllegalArgumentException("Invalid encrypted packet", e);
    }
  }

  public static byte[] packet(
      int ability, int command, int count, int index, byte[] plain, byte[] key) {
    byte[] body = key == null ? join(plain, le(crc(plain), 4)) : seal(key, plain);
    return join(
        new byte[] {(byte) 0xf5},
        be(body.length, 2),
        be(ability, 2),
        be(count, 2),
        be(index, 2),
        be(command, 2),
        body);
  }

  public static byte[] packet(int command, byte[] plain, byte[] key) {
    return packet(0xffff, command, 1, 1, plain, key);
  }

  public static final class Parser {
    private byte[] buffer = new byte[0];

    public synchronized List<Frame> feed(byte[] value) {
      buffer = join(buffer, value);
      List<Frame> out = new ArrayList<>();
      int p = 0;
      while (true) {
        while (p < buffer.length && (buffer[p] & 255) != 0xf5) p++;
        if (buffer.length - p < 11) break;
        int n = be16(buffer, p + 1), a = be16(buffer, p + 3), c = be16(buffer, p + 9);
        if (n > 4096 || (a == 0xffff && c == 0x48 && n < 4)) {
          p++;
          continue;
        }
        int body = a == 0xffff && c == 0x48 ? n - 4 : n;
        if (buffer.length - p < 11 + body) break;
        out.add(
            new Frame(
                a,
                c,
                be16(buffer, p + 5),
                be16(buffer, p + 7),
                Arrays.copyOfRange(buffer, p + 11, p + 11 + body)));
        p += 11 + body;
      }
      buffer = Arrays.copyOfRange(buffer, p, buffer.length);
      return out;
    }
  }

  public static final class Chunks {
    private static final class Partial {
      int count, next;
      byte[] body = new byte[0];

      Partial(int count) {
        this.count = count;
        next = 1;
      }
    }

    private final Map<Integer, Partial> partial = new HashMap<>();

    public byte[] append(Frame f, byte[] plain) {
      if (f.count() <= 1) return plain;
      int id = f.ability() << 16 | f.command();
      if (f.count() > 1024 || f.index() < 1 || f.index() > f.count()) {
        partial.remove(id);
        return null;
      }
      if (f.index() == 1) {
        if (partial.size() >= 16) partial.clear();
        partial.put(id, new Partial(f.count()));
      }
      Partial p = partial.get(id);
      if (p == null
          || p.count != f.count()
          || p.next != f.index()
          || p.body.length + plain.length > 131072) {
        partial.remove(id);
        return null;
      }
      p.body = join(p.body, plain);
      p.next++;
      if (f.index() == f.count()) {
        partial.remove(id);
        return p.body;
      }
      return null;
    }
  }
}
