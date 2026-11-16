package app.cmfworkbench;

import static app.cmfworkbench.protocol.Bytes.*;

import android.content.Context;
import android.security.keystore.*;
import android.util.Base64;
import java.security.*;
import javax.crypto.*;
import javax.crypto.spec.GCMParameterSpec;

/** Pairing keys are encrypted with a non-exportable Android Keystore key. */
final class SecretStore {
  private final Context context;
  private static final String ALIAS = "cmf-workbench-pairing";

  SecretStore(Context c) {
    context = c;
  }

  private SecretKey key() throws Exception {
    KeyStore store = KeyStore.getInstance("AndroidKeyStore");
    store.load(null);
    if (!store.containsAlias(ALIAS)) {
      KeyGenerator g = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore");
      g.init(
          new KeyGenParameterSpec.Builder(
                  ALIAS, KeyProperties.PURPOSE_ENCRYPT | KeyProperties.PURPOSE_DECRYPT)
              .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
              .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
              .build());
      return g.generateKey();
    }
    return (SecretKey) store.getKey(ALIAS, null);
  }

  private String id(String address) {
    return hex(sha(address.getBytes(java.nio.charset.StandardCharsets.UTF_8)));
  }

  void put(String address, byte[] value) throws Exception {
    Cipher c = Cipher.getInstance("AES/GCM/NoPadding");
    c.init(Cipher.ENCRYPT_MODE, key());
    byte[] iv = c.getIV();
    String sealed =
        Base64.encodeToString(
            join(new byte[] {(byte) iv.length}, iv, c.doFinal(value)), Base64.NO_WRAP);
    if (!context.getSharedPreferences("pairing", 0).edit().putString(id(address), sealed).commit())
      throw new java.io.IOException("Could not save pairing key");
  }

  byte[] get(String address) throws Exception {
    String s = context.getSharedPreferences("pairing", 0).getString(id(address), null);
    if (s == null) return null;
    byte[] b = Base64.decode(s, Base64.NO_WRAP);
    int n = b[0] & 255;
    require(n >= 12 && n <= 16 && b.length > n + 1, "Invalid stored pairing key");
    Cipher c = Cipher.getInstance("AES/GCM/NoPadding");
    c.init(
        Cipher.DECRYPT_MODE,
        key(),
        new GCMParameterSpec(128, java.util.Arrays.copyOfRange(b, 1, n + 1)));
    return c.doFinal(java.util.Arrays.copyOfRange(b, n + 1, b.length));
  }
}
