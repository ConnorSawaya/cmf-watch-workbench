package app.cmfworkbench.protocol;

import static app.cmfworkbench.protocol.Bytes.*;

import java.util.*;

public final class AppPackage {
  public final byte[] data;
  public final String name, sha256;
  public final int kind, imageBytes;
  public final long version;

  public AppPackage(byte[] input) {
    byte[] b = input.clone();
    require(
        b.length >= 64 && b.length <= 262208 && text(b, 0, 4).equals("WP2A") && le(b, 4, 2) == 1,
        "Invalid app package");
    kind = b[6] & 255;
    require(kind <= 1 && (b[7] & 255) <= 3, "Unsupported app ABI");
    for (int i = 56; i < 64; i++) require(b[i] == 0, "Invalid package reserved bytes");
    require(crc(Arrays.copyOf(b, 52)) == le(b, 52, 4), "App header checksum mismatch");
    imageBytes = (int) le(b, 36, 4);
    long reloc = le(b, 44, 4), entry = le(b, 40, 4);
    require(
        imageBytes > 0
            && imageBytes <= (kind == 0 ? 131072 : 65536)
            && entry < imageBytes
            && entry % 2 == 0
            && reloc <= imageBytes / 4
            && b.length == 64L + imageBytes + 4 * reloc,
        "Invalid app image layout");
    require(crc(Arrays.copyOfRange(b, 64, b.length)) == le(b, 48, 4), "App body checksum mismatch");
    name = text(b, 8, 24);
    require(
        !name.isEmpty() && name.length() <= 23 && name.chars().allMatch(c -> c >= 32 && c < 127),
        "Invalid app name");
    long previous = -1;
    for (int i = 0; i < reloc; i++) {
      long off = le(b, 64 + imageBytes + 4 * i, 4);
      require(off > previous && off <= imageBytes - 4, "Invalid app relocation");
      previous = off;
    }
    version = le(b, 32, 4);
    data = b;
    sha256 = hex(sha(b));
  }

  public record Header(int slot, int kind, String name, long version) {
    public static Header parse(int slot, byte[] b) {
      require(b.length >= 64 && text(b, 0, 4).equals("WP2A"), "Invalid installed app header");
      return new Header(slot, b[6] & 255, text(b, 8, 24), le(b, 32, 4));
    }
  }
}
