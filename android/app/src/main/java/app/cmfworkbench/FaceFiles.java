package app.cmfworkbench;

import java.io.*;

final class FaceFiles {
  static byte[] read(InputStream in, int maximum) throws IOException {
    ByteArrayOutputStream out = new ByteArrayOutputStream();
    byte[] buffer = new byte[8192];
    int n;
    while ((n = in.read(buffer)) != -1) {
      if (out.size() + n > maximum) throw new IOException("Face exceeds its supported size");
      out.write(buffer, 0, n);
    }
    return out.toByteArray();
  }
}
