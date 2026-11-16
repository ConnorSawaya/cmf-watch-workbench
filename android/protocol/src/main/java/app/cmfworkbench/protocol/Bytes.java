package app.cmfworkbench.protocol;

import java.nio.*;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.*;
import java.util.zip.CRC32;

public final class Bytes {
  private Bytes() {}

  public static long le(byte[] b, int p, int n) {
    require(p >= 0 && n >= 0 && p + n <= b.length, "Truncated data");
    long v = 0;
    for (int i = 0; i < n; i++) v |= (long) (b[p + i] & 255) << (8 * i);
    return v;
  }

  public static int be16(byte[] b, int p) {
    require(p >= 0 && p + 2 <= b.length, "Truncated data");
    return (b[p] & 255) << 8 | (b[p + 1] & 255);
  }

  public static byte[] le(long v, int n) {
    byte[] b = new byte[n];
    for (int i = 0; i < n; i++) b[i] = (byte) (v >> (8 * i));
    return b;
  }

  public static byte[] be(long v, int n) {
    byte[] b = new byte[n];
    for (int i = 0; i < n; i++) b[i] = (byte) (v >> (8 * (n - i - 1)));
    return b;
  }

  public static byte[] join(byte[]... parts) {
    int n = 0;
    for (byte[] p : parts) n = Math.addExact(n, p.length);
    byte[] b = new byte[n];
    int i = 0;
    for (byte[] p : parts) {
      System.arraycopy(p, 0, b, i, p.length);
      i += p.length;
    }
    return b;
  }

  public static long crc(byte[] b) {
    CRC32 c = new CRC32();
    c.update(b);
    return c.getValue();
  }

  public static byte[] sha(byte[] b) {
    try {
      return MessageDigest.getInstance("SHA-256").digest(b);
    } catch (Exception e) {
      throw new IllegalStateException(e);
    }
  }

  public static String hex(byte[] b) {
    StringBuilder s = new StringBuilder();
    for (byte v : b) s.append(String.format(Locale.ROOT, "%02x", v & 255));
    return s.toString();
  }

  public static byte[] unhex(String s) {
    require(s.length() % 2 == 0, "Invalid hex");
    byte[] b = new byte[s.length() / 2];
    for (int i = 0; i < b.length; i++) {
      int a = Character.digit(s.charAt(i * 2), 16), z = Character.digit(s.charAt(i * 2 + 1), 16);
      require(a >= 0 && z >= 0, "Invalid hex");
      b[i] = (byte) (a * 16 + z);
    }
    return b;
  }

  public static String text(byte[] b, int p, int n) {
    require(p >= 0 && n >= 0 && p + n <= b.length, "Truncated text");
    int end = p;
    while (end < p + n && b[end] != 0) end++;
    return new String(b, p, end - p, StandardCharsets.UTF_8);
  }

  public static byte[] fixed(String s, int length) {
    byte[] out = new byte[length];
    int n = 0;
    for (int c : s.codePoints().toArray()) {
      byte[] b = new String(Character.toChars(c)).getBytes(StandardCharsets.UTF_8);
      if (n + b.length > length) break;
      System.arraycopy(b, 0, out, n, b.length);
      n += b.length;
    }
    return out;
  }

  public static void require(boolean valid, String message) {
    if (!valid) throw new IllegalArgumentException(message);
  }
}
