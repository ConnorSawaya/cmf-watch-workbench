package app.cmfworkbench;

import android.content.Context;
import android.graphics.*;
import android.location.Location;
import android.view.*;
import app.cmfworkbench.protocol.WatchMap;
import java.util.*;
import java.util.concurrent.*;
import java.util.function.Consumer;

/** Pan and pinch remain immediate while spatial decoding runs off the UI thread. */
public final class OfflineMapView extends View {
  private final WatchController watch;
  private final Paint paint = new Paint(3);
  private final ExecutorService renderWorker = Executors.newSingleThreadExecutor();
  private final GestureDetector gestures;
  private final ScaleGestureDetector pinch;
  private WatchMap current;
  private Bitmap image;
  private double imageX, imageY, imageScale;
  public double x, y, scale = 20;
  private boolean needsFit = true;
  private int generation;
  private boolean scheduled, rendering;
  private final List<WatchMap.Place> pins = new ArrayList<>();
  public Consumer<WatchController.SavedPlace> selected = p -> {};

  public OfflineMapView(Context context, WatchController watch) {
    super(context);
    this.watch = watch;
    setContentDescription("Offline map. Drag to pan, pinch to zoom, or hold to save a location.");
    pinch =
        new ScaleGestureDetector(
            context,
            new ScaleGestureDetector.SimpleOnScaleGestureListener() {
              @Override
              public boolean onScale(ScaleGestureDetector d) {
                double old = scale;
                scale = Math.max(.5, Math.min(60000, scale / d.getScaleFactor()));
                x += (d.getFocusX() - getWidth() / 2.0) * (old - scale);
                y += (d.getFocusY() - getHeight() / 2.0) * (old - scale);
                request();
                return true;
              }
            });
    gestures =
        new GestureDetector(
            context,
            new GestureDetector.SimpleOnGestureListener() {
              @Override
              public boolean onDown(android.view.MotionEvent e) {
                return true;
              }

              @Override
              public boolean onScroll(
                  android.view.MotionEvent a, android.view.MotionEvent b, float dx, float dy) {
                if (!pinch.isInProgress()) {
                  x += dx * scale;
                  y += dy * scale;
                  request();
                }
                return true;
              }

              @Override
              public boolean onDoubleTap(android.view.MotionEvent e) {
                x += (e.getX() - getWidth() / 2.0) * scale / 2;
                y += (e.getY() - getHeight() / 2.0) * scale / 2;
                scale = Math.max(.5, scale / 2);
                request();
                return true;
              }

              @Override
              public void onLongPress(android.view.MotionEvent e) {
                selected.accept(
                    new WatchController.SavedPlace(
                        "",
                        x + (e.getX() - getWidth() / 2.0) * scale,
                        y + (e.getY() - getHeight() / 2.0) * scale));
              }

              @Override
              public boolean onSingleTapConfirmed(android.view.MotionEvent e) {
                WatchController.SavedPlace nearest = null;
                double distance = 32;
                List<WatchController.SavedPlace> all = new ArrayList<>(watch.saved);
                for (var p : pins) all.add(new WatchController.SavedPlace(p.name(), p.x(), p.y()));
                for (var p : all) {
                  double d =
                      Math.hypot(
                          (p.x() - x) / scale + getWidth() / 2.0 - e.getX(),
                          (p.y() - y) / scale + getHeight() / 2.0 - e.getY());
                  if (d < distance) {
                    nearest = p;
                    distance = d;
                  }
                }
                if (nearest != null) selected.accept(nearest);
                return true;
              }
            });
  }

  public void sync() {
    if (current != watch.map) {
      current = watch.map;
      needsFit = true;
    }
    if (current != null && needsFit && getWidth() > 0 && getHeight() > 0) {
      x = current.centerX;
      y = current.centerY;
      scale =
          Math.max(
              .5,
              Math.max(
                      (current.right - current.left) / getWidth(),
                      (current.bottom - current.top) / getHeight())
                  * 1.15);
      needsFit = false;
      request();
    }
    invalidate();
  }

  public void pins(List<WatchMap.Place> results) {
    pins.clear();
    pins.addAll(results);
    invalidate();
  }

  public void center(double x, double y) {
    this.x = x;
    this.y = y;
    scale = Math.min(scale, 12);
    request();
  }

  public void locate() {
    Location p = watch.lastLocation;
    if (p != null)
      center(
          Math.toRadians(p.getLongitude()) * 6378137,
          -6378137 * Math.log(Math.tan(Math.PI / 4 + Math.toRadians(p.getLatitude()) / 2)));
  }

  public void zoom(double factor) {
    scale = Math.max(.5, Math.min(60000, scale * factor));
    request();
  }

  @Override
  protected void onSizeChanged(int w, int h, int oldW, int oldH) {
    super.onSizeChanged(w, h, oldW, oldH);
    sync();
    request();
  }

  public void request() {
    invalidate();
    generation++;
    if (scheduled) return;
    scheduled = true;
    postDelayed(
        () -> {
          scheduled = false;
          render();
        },
        70);
  }

  private void render() {
    WatchMap map = current;
    if (map == null
        || getWidth() == 0
        || getHeight() == 0
        || rendering
        || renderWorker.isShutdown()) return;
    rendering = true;
    final int version = generation, w = getWidth(), h = getHeight();
    final double cx = x, cy = y, s = scale;
    renderWorker.execute(
        () -> {
          Bitmap next = Bitmap.createBitmap(w, h, Bitmap.Config.RGB_565);
          Canvas c = new Canvas(next);
          c.drawColor(0xfff2f1e8);
          Paint p = new Paint(3);
          Path path = new Path();
          try {
            List<WatchMap.Feature> features =
                map.visible(cx - w * s / 2, cy - h * s / 2, cx + w * s / 2, cy + h * s / 2);
            for (int group : new int[] {3, 4, 1, 0, 2})
              for (var f : features) {
                if (f.kind() != group || s<f.minScale() || s>f.maxScale()) continue;
                path.rewind();
                path.setFillType(Path.FillType.EVEN_ODD);
                boolean visible = false;
                for (int[] points : f.parts()) {
                  float lastX = Float.NaN, lastY = Float.NaN;
                  int kept = 0;
                  for (int i = 0; i < points.length; i += 2) {
                    float px = (float) ((points[i] - cx) / s + w / 2.0),
                        py = (float) ((points[i + 1] - cy) / s + h / 2.0);
                    if (kept > 0
                        && Math.abs(px - lastX) + Math.abs(py - lastY) < 1
                        && i + 2 < points.length) continue;
                    if (kept++ == 0) path.moveTo(px, py);
                    else path.lineTo(px, py);
                    lastX = px;
                    lastY = py;
                  }
                  if (f.closed()) path.close();
                  visible |= kept > 1;
                }
                if (!visible) continue;
                p.setStyle(f.closed() ? Paint.Style.FILL : Paint.Style.STROKE);
                p.setStrokeWidth(f.kind() == 0 ? 2 : 3);
                p.setStrokeCap(Paint.Cap.ROUND);
                p.setColor(
                    switch (f.kind()) {
                      case 0 -> 0xff426c43;
                      case 1 -> Color.WHITE;
                      case 2 -> 0xff609dac;
                      case 3 -> 0xffcedfbd;
                      case 4 -> 0xffa6cfd5;
                      default -> 0xffdddcd4;
                    });
                c.drawPath(path, p);
              }
            p.setStyle(Paint.Style.FILL);
            p.setTypeface(Typeface.create("sans-serif-medium", Typeface.NORMAL));
            p.setTextSize(11 * getResources().getDisplayMetrics().density);
            p.setTextAlign(Paint.Align.CENTER);
            List<RectF> occupied = new ArrayList<>();
            Set<Integer> named = new HashSet<>();
            if (s < 40)
              for (var f : features) {
                if (f.name() == 0 || named.contains(f.name()) || f.parts().isEmpty()) continue;
                int[] xy = f.parts().get(0);
                if (xy.length < 2) continue;
                int at = (xy.length / 4) * 2;
                float px = (float) ((xy[at] - cx) / s + w / 2.0),
                    py = (float) ((xy[at + 1] - cy) / s + h / 2.0);
                String name = map.names[f.name()];
                float half = p.measureText(name) / 2;
                RectF box =
                    new RectF(
                        px - half - 12,
                        py + p.ascent() - 10,
                        px + half + 12,
                        py + p.descent() + 10);
                if (box.left < 6 || box.right > w - 6 || box.top < 6 || box.bottom > h - 6)
                  continue;
                boolean overlap = false;
                for (var previous : occupied)
                  if (RectF.intersects(previous, box)) {
                    overlap = true;
                    break;
                  }
                if (overlap) continue;
                occupied.add(box);
                named.add(f.name());
                p.setStyle(Paint.Style.STROKE);
                p.setStrokeWidth(4);
                p.setColor(0xfff2f1e8);
                c.drawText(name, px, py, p);
                p.setStyle(Paint.Style.FILL);
                p.setColor(0xff283e33);
                c.drawText(name, px, py, p);
                if (named.size() >= 22) break;
              }
          } catch (Exception ignored) {
            p.setColor(0xff67716c);
            p.setTextSize(32);
            c.drawText("Zoom in to view detail", 24, 50, p);
          }
          post(
              () -> {
                rendering = false;
                if (renderWorker.isShutdown()) {
                  next.recycle();
                  return;
                }
                if (version == generation) {
                  Bitmap old = image;
                  image = next;
                  imageX = cx;
                  imageY = cy;
                  imageScale = s;
                  if (old != null) old.recycle();
                  invalidate();
                } else {
                  next.recycle();
                  render();
                }
              });
        });
  }

  @Override
  protected void onDraw(Canvas c) {
    super.onDraw(c);
    c.drawColor(0xfff2f1e8);
    if (image != null) {
      double ratio = imageScale / scale;
      float left = (float) ((imageX - x) / scale + getWidth() / 2.0 - image.getWidth() * ratio / 2),
          top = (float) ((imageY - y) / scale + getHeight() / 2.0 - image.getHeight() * ratio / 2);
      c.drawBitmap(
          image,
          null,
          new RectF(
              left,
              top,
              left + (float) (image.getWidth() * ratio),
              top + (float) (image.getHeight() * ratio)),
          paint);
    }
    if (current == null) {
      paint.setColor(0xff65706a);
      paint.setTextSize(18 * getResources().getDisplayMetrics().scaledDensity);
      paint.setTextAlign(Paint.Align.CENTER);
      c.drawText("Import an offline region to begin", getWidth() / 2f, getHeight() / 2f, paint);
      paint.setTextAlign(Paint.Align.LEFT);
    }
    for (var p : pins) pin(c, p.x(), p.y(), 0xff4a758b, 5);
    for (var p : watch.saved) pin(c, p.x(), p.y(), 0xffe6532e, 7);
    Location fix = watch.lastLocation;
    if (fix != null) {
      double px = Math.toRadians(fix.getLongitude()) * 6378137,
          py = -6378137 * Math.log(Math.tan(Math.PI / 4 + Math.toRadians(fix.getLatitude()) / 2));
      pin(
          c,
          px,
          py,
          System.currentTimeMillis() - fix.getTime() < 10000 ? 0xff1577ca : 0xff9c752f,
          8);
    }
    float density = getResources().getDisplayMetrics().density;
    double lat = 2 * Math.atan(Math.exp(-y / 6378137)) - Math.PI / 2,
        metersPerPixel = scale * Math.cos(lat);
    double target = 100 * density * metersPerPixel;
    double exponent = Math.pow(10, Math.floor(Math.log10(Math.max(1, target))));
    double length =
        target / exponent >= 5 ? 5 * exponent : target / exponent >= 2 ? 2 * exponent : exponent;
    float pixels = (float) (length / metersPerPixel);
    float sx = 20 * density, sy = getHeight() - 24 * density;
    paint.setColor(0xff253d35);
    paint.setStrokeWidth(2 * density);
    c.drawLine(sx, sy, sx + pixels, sy, paint);
    c.drawLine(sx, sy - 5 * density, sx, sy, paint);
    c.drawLine(sx + pixels, sy - 5 * density, sx + pixels, sy, paint);
    paint.setTextSize(12 * density);
    paint.setStyle(Paint.Style.FILL);
    c.drawText(
        length >= 1000
            ? String.format(Locale.ROOT, "%.1f km", length / 1000)
            : String.format(Locale.ROOT, "%.0f m", length),
        sx,
        sy - 10 * density,
        paint);
    paint.setTextAlign(Paint.Align.RIGHT);
    paint.setTextSize(10 * density);
    c.drawText(
        "© OpenStreetMap contributors",
        getWidth() - 12 * density,
        getHeight() - 7 * density,
        paint);
    paint.setTextAlign(Paint.Align.LEFT);
  }

  private void pin(Canvas c, double px, double py, int color, float radius) {
    float sx = (float) ((px - x) / scale + getWidth() / 2.0),
        sy = (float) ((py - y) / scale + getHeight() / 2.0);
    if (sx < 0 || sy < 0 || sx > getWidth() || sy > getHeight()) return;
    float d = getResources().getDisplayMetrics().density;
    paint.setStyle(Paint.Style.FILL);
    paint.setColor(Color.WHITE);
    c.drawCircle(sx, sy, (radius + 2) * d, paint);
    paint.setColor(color);
    c.drawCircle(sx, sy, radius * d, paint);
  }

  @Override
  public boolean onTouchEvent(MotionEvent e) {
    getParent().requestDisallowInterceptTouchEvent(true);
    pinch.onTouchEvent(e);
    gestures.onTouchEvent(e);
    if (e.getActionMasked() == MotionEvent.ACTION_UP) performClick();
    return true;
  }

  @Override
  public boolean performClick() {
    super.performClick();
    return true;
  }

  @Override
  protected void onDetachedFromWindow() {
    super.onDetachedFromWindow();
    generation++;
    renderWorker.shutdownNow();
    if (image != null) {
      image.recycle();
      image = null;
    }
  }
}
