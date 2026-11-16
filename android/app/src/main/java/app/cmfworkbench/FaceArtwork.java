package app.cmfworkbench;

import android.graphics.*;
import app.cmfworkbench.protocol.WatchFace;
import java.text.SimpleDateFormat;
import java.util.*;

final class FaceArtwork {
  private static Typeface font(boolean round) {
    return Typeface.create(round ? "sans-serif-medium" : "monospace", Typeface.NORMAL);
  }

  static Bitmap glyph(String text, int w, int h, int size, int color, boolean round) {
    Bitmap b = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888);
    Canvas c = new Canvas(b);
    Paint p = new Paint(3);
    p.setColor(color);
    p.setTextSize(size);
    p.setTypeface(font(round));
    p.setTextAlign(Paint.Align.CENTER);
    Paint.FontMetrics m = p.getFontMetrics();
    c.drawText(text, w / 2f, h / 2f - (m.ascent + m.descent) / 2, p);
    return b;
  }

  static WatchFace.Image pixels(Bitmap b, boolean alpha) {
    int w = b.getWidth(), h = b.getHeight();
    int[] colors = new int[w * h];
    b.getPixels(colors, 0, w, 0, 0, w, h);
    byte[] raw = new byte[w * h * (alpha ? 3 : 2)];
    int at = 0;
    for (int c : colors) {
      int v = ((c >> 19) & 31) << 11 | ((c >> 10) & 63) << 5 | ((c >> 3) & 31);
      raw[at++] = (byte) v;
      raw[at++] = (byte) (v >> 8);
      if (alpha) raw[at++] = (byte) (c >>> 24);
    }
    return new WatchFace.Image(w, h, alpha ? 5 : 4, raw);
  }

  static Bitmap bitmap(WatchFace.Image image) {
    int[] colors = new int[image.width() * image.height()];
    byte[] b = image.pixels();
    int step = image.format() == 5 ? 3 : 2;
    for (int p = 0, i = 0; p < colors.length; p++, i += step) {
      int v = (b[i] & 255) | (b[i + 1] & 255) << 8, a = step == 3 ? b[i + 2] & 255 : 255;
      colors[p] =
          a << 24
              | ((v >> 11) * 255 / 31) << 16
              | (((v >> 5) & 63) * 255 / 63) << 8
              | (v & 31) * 255 / 31;
    }
    return Bitmap.createBitmap(colors, image.width(), image.height(), Bitmap.Config.ARGB_8888);
  }

  static Bitmap background(Bitmap photo) {
    Bitmap b = Bitmap.createBitmap(466, 466, Bitmap.Config.ARGB_8888);
    Canvas c = new Canvas(b);
    c.drawColor(Color.BLACK);
    if (photo != null) {
      float scale = Math.max(466f / photo.getWidth(), 466f / photo.getHeight()),
          w = photo.getWidth() * scale,
          h = photo.getHeight() * scale;
      c.drawBitmap(
          photo,
          null,
          new RectF((466 - w) / 2, (466 - h) / 2, (466 + w) / 2, (466 + h) / 2),
          new Paint(3));
      c.drawColor(0x7a000000);
    }
    c.drawBitmap(glyph("BATTERY", 206, 22, 14, 0xff999999, true), 130, 325, null);
    return b;
  }

  static Bitmap preview(int color, boolean round, Bitmap photo) {
    Bitmap b = background(photo);
    Canvas c = new Canvas(b);
    Date date = new Date();
    c.drawBitmap(
        glyph(new SimpleDateFormat("HH:mm", Locale.US).format(date), 306, 104, 88, color, round),
        80,
        160,
        null);
    c.drawBitmap(
        glyph(
            new SimpleDateFormat("MM/dd", Locale.US).format(date), 146, 32, 27, Color.WHITE, round),
        160,
        290,
        null);
    return circular(b);
  }

  static Bitmap circular(Bitmap image) {
    Bitmap result =
        Bitmap.createBitmap(image.getWidth(), image.getHeight(), Bitmap.Config.ARGB_8888);
    Canvas c = new Canvas(result);
    Paint paint = new Paint(Paint.ANTI_ALIAS_FLAG | Paint.FILTER_BITMAP_FLAG);
    paint.setShader(new BitmapShader(image, Shader.TileMode.CLAMP, Shader.TileMode.CLAMP));
    c.drawOval(0, 0, image.getWidth(), image.getHeight(), paint);
    return result;
  }

  static WatchFace make(String name, int color, boolean round, Bitmap photo) {
    List<WatchFace.Image> digits = new ArrayList<>(),
        small = new ArrayList<>(),
        aod = new ArrayList<>();
    for (int i = 0; i < 10; i++) {
      digits.add(pixels(glyph("" + i, 64, 104, 88, color, round), true));
      small.add(pixels(glyph("" + i, 20, 32, 27, Color.WHITE, round), true));
      aod.add(pixels(glyph("" + i, 32, 56, 48, 0xff808080, round), true));
    }
    Bitmap preview = Bitmap.createScaledBitmap(preview(color, round, photo), 120, 120, true);
    return WatchFace.digital(
        name,
        pixels(background(photo), false),
        digits,
        small,
        aod,
        pixels(glyph(":", 20, 104, 80, color, round), true),
        pixels(glyph("/", 12, 32, 25, Color.WHITE, round), true),
        pixels(glyph(":", 12, 56, 42, 0xff808080, round), true),
        pixels(preview, false));
  }
}
