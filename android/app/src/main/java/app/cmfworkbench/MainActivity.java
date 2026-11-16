package app.cmfworkbench;

import android.Manifest;
import android.app.*;
import android.bluetooth.*;
import android.content.*;
import android.content.pm.PackageManager;
import android.graphics.*;
import android.location.*;
import android.net.Uri;
import android.os.*;
import android.text.*;
import android.view.*;
import android.widget.*;
import app.cmfworkbench.protocol.*;
import com.google.zxing.*;
import com.google.zxing.common.HybridBinarizer;
import java.io.*;
import java.time.*;
import java.util.*;
import java.util.concurrent.*;

public final class MainActivity extends Activity {
  private static final int PAPER = 0xfff6f5f0,
      INK = 0xff1d2c26,
      MUTED = 0xff6c756e,
      ORANGE = 0xffe6532e;
  private static final int MAP_FILE = 10,
      APP_FILE = 11,
      BOOKMARK_FILE = 12,
      BOOKMARK_EXPORT = 13,
      QR_IMAGE = 14;
  private WatchController watch;
  private LinearLayout root, content, nav;
  private int tab;
  private String fingerprint = "";
  private Runnable afterPermission;
  private String pendingSheet;
  private OfflineMapView mapView;
  private TextView mapStatus;
  private ProgressBar progress;
  private TextView progressLabel;
  private final Handler handler = new Handler(Looper.getMainLooper());
  private final ExecutorService searchWorker = Executors.newSingleThreadExecutor();
  private int searchGeneration;
  private final LocationListener location =
      new LocationListener() {
        @Override
        public void onLocationChanged(Location p) {
          watch.location(p);
          if (mapView != null) mapView.invalidate();
        }
      };

  @Override
  public void onCreate(Bundle state) {
    super.onCreate(state);
    watch = ((WorkbenchApp) getApplication()).watch;
    tab = getIntent().getIntExtra("start_tab", 0);
    if (tab < 0 || tab > 3) tab = 0;
    getWindow().setStatusBarColor(PAPER);
    getWindow().setNavigationBarColor(PAPER);
    getWindow()
        .getDecorView()
        .setSystemUiVisibility(
            View.SYSTEM_UI_FLAG_LIGHT_STATUS_BAR | View.SYSTEM_UI_FLAG_LIGHT_NAVIGATION_BAR);
    root = new LinearLayout(this);
    root.setOrientation(LinearLayout.VERTICAL);
    root.setBackgroundColor(PAPER);
    root.setFitsSystemWindows(true);
    setContentView(root);
    root.setOnApplyWindowInsetsListener(
        (v, insets) -> {
          if (Build.VERSION.SDK_INT >= 30) {
            android.graphics.Insets i = insets.getInsets(WindowInsets.Type.systemBars());
            v.setPadding(i.left, i.top, i.right, i.bottom);
          }
          return insets;
        });
    content = new LinearLayout(this);
    content.setOrientation(LinearLayout.VERTICAL);
    root.addView(content, new LinearLayout.LayoutParams(-1, 0, 1));
    nav = new LinearLayout(this);
    nav.setPadding(dp(10), dp(6), dp(10), dp(8));
    root.addView(nav, new LinearLayout.LayoutParams(-1, dp(68)));
    watch.listen(this::stateChanged);
    render();
  }

  @Override
  protected void onResume() {
    super.onResume();
    watch.listen(this::stateChanged);
    watch.foreground(true);
    stateChanged();
  }

  @Override
  protected void onPause() {
    watch.foreground(false);
    try {
      getSystemService(LocationManager.class).removeUpdates(location);
    } catch (Exception ignored) {
    }
    super.onPause();
  }

  @Override
  protected void onDestroy() {
    watch.listen(() -> {});
    searchWorker.shutdownNow();
    super.onDestroy();
  }

  private int dp(float n) {
    return Math.round(n * getResources().getDisplayMetrics().density);
  }

  private TextView text(String value, int size, int color, boolean medium) {
    TextView t = new TextView(this);
    t.setText(value);
    t.setTextSize(size);
    t.setTextColor(color);
    t.setTypeface(Typeface.create(medium ? "sans-serif-medium" : "sans-serif", Typeface.NORMAL));
    t.setIncludeFontPadding(false);
    return t;
  }

  private LinearLayout column() {
    LinearLayout l = new LinearLayout(this);
    l.setOrientation(LinearLayout.VERTICAL);
    return l;
  }

  private void gap(LinearLayout l, int size) {
    View v = new View(this);
    l.addView(v, new LinearLayout.LayoutParams(1, dp(size)));
  }

  private void divider(LinearLayout l) {
    View v = new View(this);
    v.setBackgroundColor(0xffdfE2da);
    LinearLayout.LayoutParams p = new LinearLayout.LayoutParams(-1, dp(1));
    p.topMargin = dp(14);
    p.bottomMargin = dp(14);
    l.addView(v, p);
  }

  private Button button(String label, Runnable action) {
    Button b = new Button(this);
    b.setText(label);
    b.setTextSize(15);
    b.setAllCaps(false);
    b.setTextColor(
        new android.content.res.ColorStateList(
            new int[][] {new int[] {-android.R.attr.state_enabled}, new int[] {}},
            new int[] {0xff8e968d, ORANGE}));
    b.setTypeface(Typeface.create("sans-serif-medium", Typeface.NORMAL));
    b.setMinHeight(dp(48));
    b.setStateListAnimator(null);
    b.setElevation(0);
    android.graphics.drawable.StateListDrawable states =
        new android.graphics.drawable.StateListDrawable();
    for (int mode = 0; mode < 3; mode++) {
      android.graphics.drawable.GradientDrawable shape =
          new android.graphics.drawable.GradientDrawable();
      shape.setCornerRadius(dp(12));
      shape.setColor(mode == 0 ? 0xffeeeFe8 : mode == 1 ? 0xffeee6dc : 0xffffffff);
      shape.setStroke(dp(1), 0xffdfe2d9);
      states.addState(
          mode == 0
              ? new int[] {-android.R.attr.state_enabled}
              : mode == 1 ? new int[] {android.R.attr.state_pressed} : new int[] {},
          shape);
    }
    b.setBackground(states);
    b.setPadding(dp(12), 0, dp(12), 0);
    b.setOnClickListener(
        v -> {
          try {
            action.run();
          } catch (Exception e) {
            watch.error(e);
          }
        });
    return b;
  }

  private void action(LinearLayout l, String label, Runnable action, boolean enabled) {
    Button b = button(label, action);
    b.setEnabled(enabled);
    LinearLayout.LayoutParams layout = new LinearLayout.LayoutParams(-1, dp(50));
    layout.topMargin = dp(8);
    l.addView(b, layout);
  }

  private void label(LinearLayout l, String name, String value) {
    LinearLayout row = new LinearLayout(this);
    row.setGravity(Gravity.CENTER_VERTICAL);
    TextView a = text(name, 15, INK, false), b = text(value, 15, MUTED, false);
    row.addView(a, new LinearLayout.LayoutParams(0, dp(40), 1));
    b.setGravity(Gravity.END | Gravity.CENTER_VERTICAL);
    row.addView(b, new LinearLayout.LayoutParams(-2, dp(40)));
    a.setGravity(Gravity.CENTER_VERTICAL);
    l.addView(row);
  }

  private void heading(LinearLayout l, String value) {
    gap(l, 22);
    l.addView(text(value, 21, INK, true));
    gap(l, 10);
  }

  private LinearLayout page(String title, String subtitle) {
    ScrollView scroll = new ScrollView(this);
    scroll.setFillViewport(true);
    LinearLayout page = column();
    page.setPadding(dp(24), dp(24), dp(24), dp(28));
    scroll.addView(page);
    content.addView(scroll, new LinearLayout.LayoutParams(-1, -1));
    page.addView(text(title, 32, INK, true));
    gap(page, 8);
    page.addView(text(subtitle, 14, MUTED, false));
    gap(page, 24);
    return page;
  }

  private void stateChanged() {
    if (!watch.busy && pendingSheet != null) {
      if (pendingSheet.equals("alarms") && watch.alarms != null) {
        pendingSheet = null;
        handler.post(this::alarmsDialog);
      } else if (pendingSheet.equals("contacts") && watch.contacts != null) {
        pendingSheet = null;
        handler.post(this::contactsDialog);
      } else if (watch.problem != null) pendingSheet = null;
    }
    getWindow().clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
    if (watch.busy) getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
    if (progress != null) {
      progress.setVisibility(watch.busy && watch.progress >= 0 ? View.VISIBLE : View.GONE);
      progress.setProgress((int) Math.round(watch.progress * 1000));
      if (progressLabel != null)
        progressLabel.setText(
            watch.progress < 0
                ? watch.status
                : String.format(
                    Locale.ROOT,
                    "%d%% · %s / %s",
                    (int) (watch.progress * 100),
                    bytes(watch.received),
                    bytes(watch.total)));
    }
    if (tab == 1 && mapView != null) {
      mapView.sync();
      mapStatus.setText(
          watch.mapName
              + " · "
              + (watch.map == null ? "Import a region" : bytes(watch.map.data.length)));
      return;
    }
    String next =
        tab
            + "|"
            + watch.status
            + "|"
            + watch.busy
            + "|"
            + watch.problem
            + "|"
            + watch.connected
            + "|"
            + watch.standard
            + "|"
            + watch.battery
            + "|"
            + watch.apps
            + "|"
            + watch.devices()
            + "|"
            + watch.health.syncedAt;
    if (!next.equals(fingerprint)) {
      fingerprint = next;
      render();
    }
  }

  private void render() {
    content.removeAllViews();
    nav.removeAllViews();
    mapView = null;
    progress = null;
    progressLabel = null;
    for (int i = 0; i < 4; i++) {
      final int index = i;
      LinearLayout item = column();
      item.setGravity(Gravity.CENTER);
      Icon icon = new Icon(this, i, tab == i ? ORANGE : MUTED);
      item.addView(icon, new LinearLayout.LayoutParams(dp(24), dp(24)));
      gap(item, 5);
      item.addView(
          text(
              new String[] {"Watch", "Maps", "Apps", "Device"}[i],
              11,
              tab == i ? ORANGE : MUTED,
              tab == i));
      item.setContentDescription(
          new String[] {"Watch overview", "Offline maps", "Custom apps", "Device settings"}[i]);
      item.setOnClickListener(
          v -> {
            tab = index;
            fingerprint = "";
            render();
          });
      nav.addView(item, new LinearLayout.LayoutParams(0, -1, 1));
    }
    if (tab == 0) watchPage();
    else if (tab == 1) mapPage();
    else if (tab == 2) appsPage();
    else devicePage();
  }

  private void progress(LinearLayout l) {
    progressLabel = text(watch.status, 14, MUTED, false);
    l.addView(progressLabel);
    gap(l, 8);
    progress = new ProgressBar(this, null, android.R.attr.progressBarStyleHorizontal);
    progress.setMax(1000);
    progress.setProgressTintList(android.content.res.ColorStateList.valueOf(ORANGE));
    progress.setVisibility(watch.busy && watch.progress >= 0 ? View.VISIBLE : View.GONE);
    l.addView(progress, new LinearLayout.LayoutParams(-1, dp(4)));
    if (watch.problem != null) {
      gap(l, 12);
      l.addView(text(watch.problem, 14, 0xffa34028, false));
    }
  }

  private void watchPage() {
    LinearLayout p =
        page(
            "Watch Pro 2",
            watch.connected
                ? (watch.custom ? "Connected to the app loader" : "Bluetooth connected")
                : "Connect to manage apps and offline maps.");
    LinearLayout hero = new LinearLayout(this);
    hero.setGravity(Gravity.CENTER_VERTICAL);
    LinearLayout details = column();
    details.addView(text(watch.battery == null ? "—" : watch.battery + "%", 44, INK, false));
    gap(details, 6);
    details.addView(
        text(
            watch.battery == null
                ? "Battery not read yet"
                : watch.charging ? "Charging" : "Watch battery",
            14,
            MUTED,
            false));
    hero.addView(details, new LinearLayout.LayoutParams(0, dp(176), 1));
    hero.addView(new WatchFace(this), new LinearLayout.LayoutParams(dp(146), dp(176)));
    p.addView(hero);
    progress(p);
    if (!watch.connected) {
      action(
          p,
          watch.scanning ? "Scanning…" : "Find my watch",
          () -> nearby(watch::scan),
          !watch.scanning && !watch.busy);
      for (var d : watch.devices()) {
        action(
            p,
            d.name() + " · " + d.signal() + " dBm",
            () -> {
              startForegroundService(new Intent(this, ConnectionService.class));
              watch.connect(d.handle());
            },
            !watch.busy);
      }
    }
    divider(p);
    heading(p, "Today");
    long steps = 0, meters = 0, calories = 0;
    boolean any = false;
    LocalDate today = LocalDate.now();
    synchronized (watch.health) {
      for (var a : watch.health.activity.values())
        if (Instant.ofEpochSecond(a.timestamp())
            .atZone(ZoneId.systemDefault())
            .toLocalDate()
            .equals(today)) {
          any = true;
          steps += a.steps();
          meters += a.meters();
          calories += a.milliCalories();
        }
    }
    label(p, "Steps", any ? String.format(Locale.getDefault(), "%,d", steps) : "—");
    label(p, "Distance", any ? String.format(Locale.ROOT, "%.2f km", meters / 1000.0) : "—");
    label(
        p, "Active energy", any ? String.format(Locale.ROOT, "%.0f kcal", calories / 1000.0) : "—");
    if (watch.health.syncedAt == 0)
      p.addView(text("Readings appear after a health sync.", 13, MUTED, false));
    else
      p.addView(
          text(
              "Synced "
                  + java.text.DateFormat.getDateTimeInstance(
                          java.text.DateFormat.SHORT, java.text.DateFormat.SHORT)
                      .format(new Date(watch.health.syncedAt)),
              12,
              MUTED,
              false));
    action(p, "Sync watch health", watch::syncHealth, watch.standard && !watch.busy);
    action(p, "View heart rate, sleep & activity", this::healthDialog, true);
    heading(p, "Explore");
    p.addView(
        text("Offline regions, saved places and the watch's built-in GPS.", 15, MUTED, false));
    action(
        p,
        "Open maps",
        () -> {
          tab = 1;
          render();
        },
        true);
  }

  private void healthDialog() {
    StringBuilder b = new StringBuilder();
    synchronized (watch.health) {
      List<WatchHealth.Point> values = new ArrayList<>(watch.health.points.values());
      values.sort(Comparator.comparingLong(WatchHealth.Point::timestamp).reversed());
      for (int metric : new int[] {0x53, 0x55, 0x9d}) {
        WatchHealth.Point found = null;
        for (var p : values)
          if (p.metric() == metric) {
            found = p;
            break;
          }
        b.append(
                switch (metric) {
                  case 0x53 -> "Heart rate";
                  case 0x55 -> "Blood oxygen";
                  case 0x9d -> "Stress";
                  case 0xda -> "Heart metric";
                  default -> "Health metric";
                })
            .append(": ")
            .append(
                found == null
                    ? "No reading"
                    : found.value() + " · " + new Date(found.timestamp() * 1000))
            .append("\n\n");
      }
      var sleep = watch.health.sleep.isEmpty() ? null : watch.health.sleep.lastEntry().getValue();
      b.append("Latest sleep: ")
          .append(
              sleep == null
                  ? "No reading"
                  : ((sleep.end() - sleep.start()) / 60)
                      + " minutes\nDeep "
                      + sleep.deep()
                      + " · Light "
                      + sleep.light()
                      + " · REM "
                      + sleep.rem()
                      + " · Awake "
                      + sleep.awake());
    }
    new AlertDialog.Builder(this)
        .setTitle("Watch health")
        .setMessage(b.toString())
        .setPositiveButton("Done", null)
        .show();
  }

  private void mapPage() {
    LinearLayout top = column();
    top.setPadding(dp(20), dp(16), dp(20), dp(8));
    top.addView(text("Offline maps", 28, INK, true));
    gap(top, 6);
    mapStatus =
        text(
            watch.mapName
                + " · "
                + (watch.map == null ? "Import a region" : bytes(watch.map.data.length)),
            13,
            MUTED,
            false);
    top.addView(mapStatus);
    EditText search = new EditText(this);
    search.setSingleLine();
    search.setHint("Search this region");
    search.setTextSize(16);
    top.addView(search, new LinearLayout.LayoutParams(-1, dp(52)));
    content.addView(top);
    FrameLayout frame = new FrameLayout(this);
    mapView = new OfflineMapView(this, watch);
    mapView.selected = this::placeDialog;
    frame.addView(mapView, new FrameLayout.LayoutParams(-1, -1));
    content.addView(frame, new LinearLayout.LayoutParams(-1, 0, 1));
    LinearLayout controls = column();
    controls.setPadding(dp(8), dp(8), dp(8), dp(8));
    Button plus = button("+", () -> mapView.zoom(.5)),
        minus = button("−", () -> mapView.zoom(2)),
        locate = button("◎", this::locate);
    for (Button b : new Button[] {plus, minus, locate})
      controls.addView(b, new LinearLayout.LayoutParams(dp(50), dp(50)));
    FrameLayout.LayoutParams cp =
        new FrameLayout.LayoutParams(dp(66), -2, Gravity.END | Gravity.BOTTOM);
    cp.bottomMargin = dp(10);
    frame.addView(controls, cp);
    LinearLayout options = new LinearLayout(this);
    options.setGravity(Gravity.CENTER);
    options.addView(
        button("Import region", () -> pick(MAP_FILE, "*/*")),
        new LinearLayout.LayoutParams(0, dp(52), 1));
    options.addView(
        button("Saved places", this::savedDialog), new LinearLayout.LayoutParams(0, dp(52), 1));
    options.addView(
        button("Results", () -> showResults(search.getText().toString())),
        new LinearLayout.LayoutParams(0, dp(52), 1));
    content.addView(options);
    mapView.sync();
    search.addTextChangedListener(
        new TextWatcher() {
          public void beforeTextChanged(CharSequence s, int st, int count, int after) {}

          public void onTextChanged(CharSequence s, int st, int before, int count) {
            int version = ++searchGeneration;
            handler.postDelayed(
                () -> {
                  if (version != searchGeneration || watch.map == null || mapView == null) return;
                  WatchMap map = watch.map;
                  double x = mapView.x, y = mapView.y;
                  searchWorker.execute(
                      () -> {
                        var results = map.search(s.toString(), x, y);
                        handler.post(
                            () -> {
                              if (version == searchGeneration && mapView != null) {
                                mapView.pins(results);
                                mapStatus.setText(
                                    watch.mapName
                                        + " · "
                                        + results.size()
                                        + " results"
                                        + (results.size() == 300 ? " (limit)" : ""));
                              }
                            });
                      });
                },
                250);
          }

          public void afterTextChanged(Editable e) {}
        });
  }

  private void showResults(String query) {
    if (watch.map == null || mapView == null) return;
    var results = watch.map.search(query, mapView.x, mapView.y);
    if (results.isEmpty()) {
      toast("No matching places in this region");
      return;
    }
    String[] labels =
        results.stream().map(p -> p.name() + distance(p.x(), p.y())).toArray(String[]::new);
    new AlertDialog.Builder(this)
        .setTitle(results.size() + " results")
        .setItems(
            labels,
            (d, i) -> {
              var p = results.get(i);
              mapView.center(p.x(), p.y());
              placeDialog(new WatchController.SavedPlace(p.name(), p.x(), p.y()));
            })
        .setNeutralButton("Show all on map", (d, i) -> mapView.pins(results))
        .setNegativeButton("Close", null)
        .show();
  }

  private String distance(double x, double y) {
    if (watch.lastLocation == null) return "";
    float[] value = new float[1];
    Location.distanceBetween(
        watch.lastLocation.getLatitude(),
        watch.lastLocation.getLongitude(),
        BookmarkFiles.latitude(y),
        BookmarkFiles.longitude(x),
        value);
    double feet = value[0] * 3.280839895;
    return feet < 5280
        ? String.format(Locale.ROOT, " · %.0f ft", feet)
        : String.format(Locale.ROOT, " · %.1f mi", feet / 5280);
  }

  private void placeDialog(WatchController.SavedPlace p) {
    if (p.name().isEmpty()) {
      EditText name = field("Location name", "", false);
      new AlertDialog.Builder(this)
          .setTitle("Save this location")
          .setView(name)
          .setPositiveButton(
              "Save",
              (d, i) -> {
                try {
                  watch.savePlace(
                      new WatchController.SavedPlace(name.getText().toString(), p.x(), p.y()));
                  if (mapView != null) mapView.invalidate();
                } catch (Exception e) {
                  watch.error(e);
                }
              })
          .setNegativeButton("Cancel", null)
          .show();
      return;
    }
    new AlertDialog.Builder(this)
        .setTitle(p.name())
        .setMessage(
            String.format(
                    Locale.ROOT,
                    "%.5f, %.5f",
                    BookmarkFiles.latitude(p.y()),
                    BookmarkFiles.longitude(p.x()))
                + distance(p.x(), p.y()))
        .setPositiveButton(
            "Save place",
            (d, i) -> {
              watch.savePlace(p);
              if (mapView != null) mapView.invalidate();
            })
        .setNeutralButton("Organic Maps", (d, i) -> organic(p))
        .setNegativeButton("Close", null)
        .show();
  }

  private void organic(WatchController.SavedPlace p) {
    Uri uri =
        Uri.parse(
            "om://map?v=1&ll="
                + BookmarkFiles.latitude(p.y())
                + ","
                + BookmarkFiles.longitude(p.x())
                + "&n="
                + Uri.encode(p.name()));
    try {
      startActivity(new Intent(Intent.ACTION_VIEW, uri));
    } catch (ActivityNotFoundException e) {
      toast("Install Organic Maps to open this place there");
    }
  }

  private void savedDialog() {
    String[] names =
        watch.saved.stream().map(p -> p.name() + distance(p.x(), p.y())).toArray(String[]::new);
    new AlertDialog.Builder(this)
        .setTitle("Saved places · " + names.length)
        .setItems(
            names,
            (d, i) -> {
              var p = watch.saved.get(i);
              new AlertDialog.Builder(this)
                  .setTitle(p.name())
                  .setItems(
                      new String[] {"Show on map", "Open in Organic Maps", "Remove saved place"},
                      (a, n) -> {
                        if (n == 0 && mapView != null) mapView.center(p.x(), p.y());
                        else if (n == 1) organic(p);
                        else if (n == 2) watch.removePlace(p);
                      })
                  .show();
            })
        .setPositiveButton("Import GPX / GeoJSON", (d, i) -> pick(BOOKMARK_FILE, "*/*"))
        .setNeutralButton(
            "Export GPX",
            (d, i) -> {
              Intent out =
                  new Intent(Intent.ACTION_CREATE_DOCUMENT)
                      .setType("application/gpx+xml")
                      .putExtra(Intent.EXTRA_TITLE, "Saved places.gpx")
                      .addCategory(Intent.CATEGORY_OPENABLE);
              startActivityForResult(out, BOOKMARK_EXPORT);
            })
        .setNegativeButton("Close", null)
        .show();
  }

  private void appsPage() {
    LinearLayout p = page("Custom apps", "Small apps. Separate installs. Your watch.");
    progress(p);
    for (String name : new String[] {"trail-map", "stopwatch", "intervals", "counter"}) {
      heading(
          p,
          switch (name) {
            case "trail-map" -> "Trail Map";
            case "stopwatch" -> "Stopwatch";
            case "intervals" -> "Interval timer";
            default -> "Counter";
          });
      String description =
          switch (name) {
            case "trail-map" -> "Offline vectors, GPS, saved places and crown zoom.";
            case "stopwatch" -> "Start, pause, record a lap and reset.";
            case "intervals" -> "Set work, rest and rounds with the crown.";
            default -> "Tap or turn the crown. Your count stays on the watch.";
          };
      p.addView(text(description, 14, MUTED, false));
      var installed =
          watch.apps.stream().filter(a -> a.name().equals(name)).findFirst().orElse(null);
      if (installed != null) label(p, "Installed", "v" + installed.version());
      action(
          p,
          installed == null ? "Install" : "Update",
          () -> watch.installBundled(name),
          watch.custom && watch.standard && !watch.busy);
      divider(p);
    }
    heading(p, "Offline region");
    label(p, "Selected", watch.mapName);
    label(p, "Map size", watch.map == null ? "—" : bytes(watch.map.data.length));
    label(
        p,
        "Saved on watch",
        watch.watchMapBytes == 0 ? "Not confirmed" : bytes(watch.watchMapBytes));
    action(p, "Import watch map", () -> pick(MAP_FILE, "*/*"), !watch.busy);
    action(
        p,
        "Download map to watch",
        watch::downloadMap,
        watch.map != null && watch.custom && !watch.busy);
    p.addView(
        text(
            "Open Trail Map on the watch during map downloads. Close Custom Apps before installing"
                + " app code.",
            13,
            MUTED,
            false));
    heading(p, "Developer tools");
    action(
        p,
        "Install reviewed app package",
        () -> pick(APP_FILE, "*/*"),
        watch.custom && !watch.busy);
    action(
        p,
        "Update app loader",
        () -> watch.installBundled("loader"),
        watch.custom && watch.standard && !watch.busy);
    action(p, "Refresh installed apps", watch::refresh, watch.custom && !watch.busy);
    action(
        p,
        "Build an app / initial loader setup",
        () ->
            browse(
                "https://github.com/ConnorSawaya/cmf-watch-workbench/blob/main/docs/getting-started.md"),
        true);
  }

  private void devicePage() {
    LinearLayout p =
        page(
            "Device",
            watch.connected
                ? "Connected settings and watch controls"
                : "Connect a Watch Pro 2 to manage its settings.");
    progress(p);
    label(p, "Firmware", watch.firmware == null ? "Not read" : watch.firmware);
    label(p, "Standard controls", watch.standard ? "Paired" : "Not paired");
    label(p, "App loader", watch.custom ? "Responding" : "Not connected");
    action(
        p,
        "Find / connect watch",
        () -> {
          tab = 0;
          render();
          nearby(watch::scan);
        },
        !watch.busy);
    action(p, "Pair standard controls", watch::pairStandard, watch.connected && !watch.busy);
    action(p, "Read QR code from image", () -> pick(QR_IMAGE, "image/*"), !watch.busy);
    action(
        p,
        "Use pairing QR link",
        () ->
            input(
                "Pairing QR link",
                new String[] {"Paste scanned link"},
                false,
                values -> applyQR(values[0])),
        !watch.busy);
    divider(p);
    action(p, "Sync date, time & battery", watch::syncTime, watch.standard && !watch.busy);
    action(p, "Read battery", watch::refreshBattery, watch.standard && !watch.busy);
    action(p, "Find watch", () -> watch.findWatch(true), watch.standard && !watch.busy);
    action(p, "Stop finding watch", () -> watch.findWatch(false), watch.standard && !watch.busy);
    heading(p, "Daily controls");
    action(
        p, "Watch faces", () -> startActivity(new Intent(this, FaceActivity.class)), !watch.busy);
    action(p, "Alarms", this::alarmsDialog, watch.standard && !watch.busy);
    action(p, "Favorite contacts", this::contactsDialog, watch.standard && !watch.busy);
    action(
        p,
        "Wrist wake",
        () -> chooseBoolean("Wrist wake", v -> watch.booleanSetting("Wrist wake", 0x62, v)),
        watch.standard && !watch.busy);
    action(
        p,
        "12-hour time",
        () -> chooseBoolean("12-hour time", v -> watch.booleanSetting("12-hour time", 0x5f, v)),
        watch.standard && !watch.busy);
    action(
        p,
        "Units",
        () ->
            new AlertDialog.Builder(this)
                .setTitle("Watch units")
                .setItems(
                    new String[] {
                      "Metric · Celsius",
                      "Metric · Fahrenheit",
                      "Imperial · Celsius",
                      "Imperial · Fahrenheit"
                    },
                    (d, i) -> watch.units(i >= 2, i % 2 == 1))
                .show(),
        watch.standard && !watch.busy);
    action(
        p,
        "Activity goals",
        () ->
            input(
                "Activity goals",
                new String[] {
                  "Steps (2,000–30,000)",
                  "Distance in meters (1,000–99,000)",
                  "Energy in kcal (100–5,000)"
                },
                true,
                v ->
                    watch.goals(
                        Integer.parseInt(v[0]), Integer.parseInt(v[1]), Integer.parseInt(v[2]))),
        watch.standard && !watch.busy);
    action(p, "Profile", this::profileDialog, watch.standard && !watch.busy);
    action(
        p,
        "Sedentary reminder",
        () -> reminder(0x60, "Sedentary reminder"),
        watch.standard && !watch.busy);
    action(
        p,
        "Hydration reminder",
        () -> reminder(0x61, "Hydration reminder"),
        watch.standard && !watch.busy);
    for (int kind : new int[] {1, 2, 4}) {
      String title =
          kind == 1
              ? "Heart-rate monitoring"
              : kind == 2 ? "Oxygen monitoring" : "Stress monitoring";
      action(
          p,
          title,
          () -> chooseBoolean(title, value -> watch.monitor(kind, value)),
          watch.standard && !watch.busy);
    }
    Switch auto = new Switch(this);
    auto.setText("Auto-sync health");
    auto.setTextColor(INK);
    auto.setPadding(0, dp(12), 0, dp(12));
    auto.setChecked(getSharedPreferences("settings", 0).getBoolean("auto-sync", true));
    auto.setOnCheckedChangeListener(
        (b, on) -> getSharedPreferences("settings", 0).edit().putBoolean("auto-sync", on).apply());
    p.addView(auto);
    heading(p, "Watch GPS");
    label(p, "◈", watch.satellites == null ? "—" : String.valueOf(watch.satellites));
    label(
        p,
        "Position",
        watch.gpsFix ? "Watch fix" : watch.gpsActive ? "Searching" : "Open Trail Map");
    p.addView(
        text(
            "The count comes from the watch receiver. Phone location is a fallback while this"
                + " companion is open.",
            13,
            MUTED,
            false));
    action(p, "Disconnect", watch::disconnect, watch.connected && !watch.busy);
    heading(p, "About");
    action(p, "Licenses and map attribution", this::licensesDialog, true);
  }

  private void licensesDialog() {
    try (java.io.InputStream input = getAssets().open("licenses/NOTICE.md")) {
      java.io.ByteArrayOutputStream bytes = new java.io.ByteArrayOutputStream();
      byte[] chunk = new byte[4096];
      int n;
      while ((n = input.read(chunk)) != -1) bytes.write(chunk, 0, n);
      new AlertDialog.Builder(this)
          .setTitle("Licenses and attribution")
          .setMessage(bytes.toString("UTF-8"))
          .setPositiveButton("Done", null)
          .setNeutralButton(
              "OpenStreetMap license", (d, i) -> browse("https://www.openstreetmap.org/copyright"))
          .show();
    } catch (Exception e) {
      watch.error(e);
    }
  }

  private void alarmsDialog() {
    if (watch.alarms == null) {
      pendingSheet = "alarms";
      watch.readAlarms();
      return;
    }
    String[] labels =
        watch.alarms.stream()
            .map(
                a ->
                    String.format(
                        Locale.ROOT,
                        "%02d:%02d · %s · %s",
                        a.seconds() / 3600,
                        a.seconds() / 60 % 60,
                        a.label(),
                        a.enabled() ? "On" : "Off"))
            .toArray(String[]::new);
    new AlertDialog.Builder(this)
        .setTitle("Watch alarms")
        .setItems(
            labels,
            (d, i) -> {
              Settings.Alarm a = watch.alarms.get(i);
              new AlertDialog.Builder(this)
                  .setTitle(a.label())
                  .setItems(
                      new String[] {a.enabled() ? "Disable" : "Enable", "Delete"},
                      (dialog, n) -> {
                        var all = new ArrayList<>(watch.alarms);
                        if (n == 1) all.remove(i);
                        else
                          all.set(
                              i,
                              new Settings.Alarm(
                                  a.id(),
                                  a.seconds(),
                                  !a.enabled(),
                                  a.weekdays(),
                                  a.flag(),
                                  a.label()));
                        watch.saveAlarms(all);
                      })
                  .show();
            })
        .setPositiveButton(
            "Add",
            (d, i) ->
                input(
                    "New alarm",
                    new String[] {"Hour (0–23)", "Minute (0–59)", "Label"},
                    false,
                    v -> {
                      int hour = Integer.parseInt(v[0]), minute = Integer.parseInt(v[1]);
                      if (hour < 0 || hour > 23 || minute < 0 || minute > 59)
                        throw new IllegalArgumentException("Enter a valid time");
                      var all = new ArrayList<>(watch.alarms);
                      int id = 0;
                      while (id < 5) {
                        final int candidate = id;
                        if (all.stream().noneMatch(a -> a.id() == candidate)) break;
                        id++;
                      }
                      all.add(new Settings.Alarm(id, hour * 3600 + minute * 60, true, 0, 0, v[2]));
                      watch.saveAlarms(all);
                    }))
        .setNeutralButton("Refresh", (d, i) -> watch.readAlarms())
        .setNegativeButton("Close", null)
        .show();
  }

  private void contactsDialog() {
    if (watch.contacts == null) {
      pendingSheet = "contacts";
      watch.readContacts();
      return;
    }
    String[] names =
        watch.contacts.stream().map(c -> c.name() + " · " + c.number()).toArray(String[]::new);
    new AlertDialog.Builder(this)
        .setTitle("Favorite contacts")
        .setItems(
            names,
            (d, i) ->
                new AlertDialog.Builder(this)
                    .setTitle("Remove " + watch.contacts.get(i).name() + "?")
                    .setPositiveButton(
                        "Remove",
                        (a, b) -> {
                          var all = new ArrayList<>(watch.contacts);
                          all.remove(i);
                          watch.saveContacts(all);
                        })
                    .setNegativeButton("Cancel", null)
                    .show())
        .setPositiveButton(
            "Add",
            (d, i) ->
                input(
                    "New favorite contact",
                    new String[] {"Name", "Phone number"},
                    false,
                    v -> {
                      var all = new ArrayList<>(watch.contacts);
                      all.add(new Settings.Contact(v[0], v[1]));
                      watch.saveContacts(all);
                    }))
        .setNeutralButton("Refresh", (d, i) -> watch.readContacts())
        .setNegativeButton("Close", null)
        .show();
  }

  private void profileDialog() {
    LinearLayout form = column();
    form.setPadding(dp(18), 0, dp(18), 0);
    EditText height = field("Height in cm", "", true),
        weight = field("Weight in kg", "", true),
        age = field("Age", "", true);
    form.addView(height);
    form.addView(weight);
    form.addView(age);
    Spinner sex = new Spinner(this);
    sex.setAdapter(
        new ArrayAdapter<String>(
            this, android.R.layout.simple_spinner_dropdown_item, new String[] {"Female", "Male"}));
    form.addView(sex);
    AlertDialog dialog =
        new AlertDialog.Builder(this)
            .setTitle("Watch profile")
            .setView(form)
            .setPositiveButton("Save", null)
            .setNegativeButton("Cancel", null)
            .create();
    dialog.setOnShowListener(
        d ->
            dialog
                .getButton(-1)
                .setOnClickListener(
                    v -> {
                      try {
                        int h = Integer.parseInt(height.getText().toString()),
                            w = Integer.parseInt(weight.getText().toString()),
                            a = Integer.parseInt(age.getText().toString());
                        if (h < 80 || h > 255 || w < 20 || w > 255 || a < 5 || a > 120)
                          throw new IllegalArgumentException();
                        watch.profile(h, w, a, sex.getSelectedItemPosition() == 1);
                        dialog.dismiss();
                      } catch (Exception e) {
                        toast("Enter a valid height, weight and age");
                      }
                    }));
    dialog.show();
  }

  private void reminder(int ability, String title) {
    LinearLayout form = column();
    form.setPadding(dp(18), 0, dp(18), 0);
    Switch enabled = new Switch(this);
    enabled.setText("Enabled");
    form.addView(enabled);
    EditText interval = field("Repeat every N minutes", "", true);
    form.addView(interval);
    int[] hours = {22, 8};
    Button start =
        button(
            "Quiet hours start · 22:00",
            () ->
                new TimePickerDialog(
                        this,
                        (v, h, m) -> {
                          hours[0] = h * 60 + m;
                          startQuietLabel(form, 1, h, m);
                        },
                        22,
                        0,
                        true)
                    .show());
    Button end =
        button(
            "Quiet hours end · 08:00",
            () ->
                new TimePickerDialog(
                        this,
                        (v, h, m) -> {
                          hours[1] = h * 60 + m;
                          startQuietLabel(form, 2, h, m);
                        },
                        8,
                        0,
                        true)
                    .show());
    form.addView(start);
    form.addView(end);
    hours[0] = 22 * 60;
    hours[1] = 8 * 60;
    AlertDialog dialog =
        new AlertDialog.Builder(this)
            .setTitle(title)
            .setView(form)
            .setPositiveButton("Save", null)
            .setNegativeButton("Cancel", null)
            .create();
    dialog.setOnShowListener(
        d ->
            dialog
                .getButton(-1)
                .setOnClickListener(
                    v -> {
                      try {
                        int minutes = Integer.parseInt(interval.getText().toString());
                        if (minutes < 1 || minutes > 1440) throw new IllegalArgumentException();
                        watch.reminder(
                            ability,
                            new Settings.Reminder(
                                enabled.isChecked(), minutes, hours[0] * 60, hours[1] * 60));
                        dialog.dismiss();
                      } catch (Exception e) {
                        toast("Enter an interval from 1 to 1,440 minutes");
                      }
                    }));
    dialog.show();
  }

  private void startQuietLabel(LinearLayout form, int kind, int h, int m) {
    View view = form.getChildAt(kind + 1);
    if (view instanceof Button b)
      b.setText(
          String.format(
              Locale.ROOT, "Quiet hours %s · %02d:%02d", kind == 1 ? "start" : "end", h, m));
  }

  private void chooseBoolean(String title, java.util.function.Consumer<Boolean> selected) {
    new AlertDialog.Builder(this)
        .setTitle(title)
        .setItems(new String[] {"On", "Off"}, (d, i) -> selected.accept(i == 0))
        .show();
  }

  private EditText field(String hint, String value, boolean numeric) {
    EditText e = new EditText(this);
    e.setHint(hint);
    e.setText(value);
    e.setSingleLine();
    e.setTextSize(16);
    if (numeric) e.setInputType(android.text.InputType.TYPE_CLASS_NUMBER);
    e.setPadding(dp(16), dp(12), dp(16), dp(12));
    return e;
  }

  private void input(
      String title, String[] hints, boolean numeric, java.util.function.Consumer<String[]> result) {
    LinearLayout fields = column();
    fields.setPadding(dp(10), 0, dp(10), 0);
    List<EditText> all = new ArrayList<>();
    for (String hint : hints) {
      EditText e = field(hint, "", numeric);
      fields.addView(e, new LinearLayout.LayoutParams(-1, dp(58)));
      all.add(e);
    }
    AlertDialog dialog =
        new AlertDialog.Builder(this)
            .setTitle(title)
            .setView(fields)
            .setPositiveButton("Save", null)
            .setNegativeButton("Cancel", null)
            .create();
    dialog.setOnShowListener(
        d ->
            dialog
                .getButton(AlertDialog.BUTTON_POSITIVE)
                .setOnClickListener(
                    v -> {
                      try {
                        String[] values =
                            all.stream()
                                .map(e -> e.getText().toString().trim())
                                .toArray(String[]::new);
                        result.accept(values);
                        dialog.dismiss();
                      } catch (Exception e) {
                        toast(e.getMessage() == null ? "Check your entries" : e.getMessage());
                      }
                    }));
    dialog.show();
  }

  private void pick(int request, String mime) {
    startActivityForResult(
        new Intent(Intent.ACTION_OPEN_DOCUMENT).addCategory(Intent.CATEGORY_OPENABLE).setType(mime),
        request);
  }

  @Override
  protected void onActivityResult(int request, int result, Intent data) {
    super.onActivityResult(request, result, data);
    if (result != RESULT_OK || data == null || data.getData() == null) return;
    Uri uri = data.getData();
    if (request == MAP_FILE) watch.importMap(uri);
    else if (request == APP_FILE) watch.importPackage(uri);
    else if (request == BOOKMARK_FILE)
      watch.run(
          "Importing bookmarks",
          () -> {
            var places = BookmarkFiles.read(watch.read(uri, 5_000_000));
            watch.mergePlaces(places);
            watch.status = places.size() + " point bookmarks imported";
          });
    else if (request == BOOKMARK_EXPORT) {
      try (OutputStream out = getContentResolver().openOutputStream(uri)) {
        if (out == null) throw new IOException("Could not create GPX");
        out.write(BookmarkFiles.export(new ArrayList<>(watch.saved)));
        toast("Saved places exported");
      } catch (Exception e) {
        watch.error(e);
      }
    } else if (request == QR_IMAGE)
      watch.run(
          "Reading watch QR",
          () -> {
            BitmapFactory.Options o = new BitmapFactory.Options();
            o.inJustDecodeBounds = true;
            try (InputStream in = getContentResolver().openInputStream(uri)) {
              BitmapFactory.decodeStream(in, null, o);
            }
            o.inJustDecodeBounds = false;
            o.inSampleSize = 1;
            while (Math.max(o.outWidth, o.outHeight) / o.inSampleSize > 2048) o.inSampleSize *= 2;
            Bitmap bitmap;
            try (InputStream in = getContentResolver().openInputStream(uri)) {
              bitmap = BitmapFactory.decodeStream(in, null, o);
            }
            if (bitmap == null) throw new IOException("Could not read QR image");
            int w = bitmap.getWidth(), h = bitmap.getHeight();
            int[] pixels = new int[w * h];
            bitmap.getPixels(pixels, 0, w, 0, 0, w, h);
            bitmap.recycle();
            String raw =
                new MultiFormatReader()
                    .decode(
                        new BinaryBitmap(new HybridBinarizer(new RGBLuminanceSource(w, h, pixels))))
                    .getText();
            runOnUiThread(
                () -> {
                  try {
                    applyQR(raw);
                  } catch (Exception e) {
                    watch.error(e);
                  }
                });
            watch.status = "Watch QR read";
          });
  }

  private void applyQR(String raw) {
    Uri uri = Uri.parse(raw);
    String fragment = uri.getFragment();
    if (fragment == null || !fragment.contains("?"))
      throw new IllegalArgumentException("Unsupported watch setup QR");
    Uri parameters =
        Uri.parse("https://setup.invalid/?" + fragment.substring(fragment.indexOf('?') + 1));
    String address = parameters.getQueryParameter("M");
    if (address == null || !address.matches("(?i)[0-9a-f]{12}"))
      throw new IllegalArgumentException("Unsupported watch setup QR");
    String suffix = address.substring(8).toUpperCase(Locale.ROOT);
    toast("Find the watch whose name ends in " + suffix);
    tab = 0;
    render();
    nearby(watch::scan);
  }

  private void nearby(Runnable next) {
    String[] permissions =
        Build.VERSION.SDK_INT >= 31
            ? new String[] {
              Manifest.permission.BLUETOOTH_SCAN, Manifest.permission.BLUETOOTH_CONNECT
            }
            : new String[] {Manifest.permission.ACCESS_FINE_LOCATION};
    List<String> missing = new ArrayList<>();
    for (String p : permissions)
      if (checkSelfPermission(p) != PackageManager.PERMISSION_GRANTED) missing.add(p);
    if (!missing.isEmpty()) {
      afterPermission = next;
      requestPermissions(missing.toArray(new String[0]), 1);
    } else next.run();
  }

  private void locate() {
    if (checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION)
            != PackageManager.PERMISSION_GRANTED
        && checkSelfPermission(Manifest.permission.ACCESS_COARSE_LOCATION)
            != PackageManager.PERMISSION_GRANTED) {
      afterPermission = this::locate;
      requestPermissions(
          new String[] {
            Manifest.permission.ACCESS_FINE_LOCATION, Manifest.permission.ACCESS_COARSE_LOCATION
          },
          2);
      return;
    }
    try {
      LocationManager manager = getSystemService(LocationManager.class);
      for (String provider :
          new String[] {LocationManager.GPS_PROVIDER, LocationManager.NETWORK_PROVIDER})
        if (manager.isProviderEnabled(provider)) {
          Location last = manager.getLastKnownLocation(provider);
          if (last != null && last.getAccuracy() > 0 && last.getAccuracy() <= 1000)
            watch.location(last);
          manager.requestLocationUpdates(provider, 1000, 3, location, Looper.getMainLooper());
        }
      if (mapView != null) mapView.locate();
      if (watch.lastLocation == null) toast("Waiting for a location fix");
    } catch (Exception e) {
      watch.error(e);
    }
  }

  @Override
  public void onRequestPermissionsResult(int code, String[] permissions, int[] results) {
    super.onRequestPermissionsResult(code, permissions, results);
    boolean any = results.length > 0;
    if (code == 2) {
      any = false;
      for (int r : results) any |= r == PackageManager.PERMISSION_GRANTED;
    } else {
      for (int r : results) any &= r == PackageManager.PERMISSION_GRANTED;
    }
    if (any && afterPermission != null) {
      Runnable next = afterPermission;
      afterPermission = null;
      next.run();
    } else toast("Permission is needed for this feature");
  }

  private void browse(String url) {
    startActivity(new Intent(Intent.ACTION_VIEW, Uri.parse(url)));
  }

  private void toast(String message) {
    Toast.makeText(this, message, Toast.LENGTH_LONG).show();
  }

  static String bytes(long count) {
    if (count >= 1000000) return String.format(Locale.ROOT, "%.2f MB", count / 1000000.0);
    return String.format(Locale.ROOT, "%.1f KB", count / 1000.0);
  }

  private final class WatchFace extends View {
    private final Paint p = new Paint(3);

    WatchFace(Context c) {
      super(c);
      setContentDescription("Watch Pro 2 illustration");
    }

    @Override
    protected void onDraw(Canvas c) {
      float w = getWidth(), h = getHeight(), r = w * .43f, x = w * .47f, y = h * .5f;
      p.setColor(0xffb4b8b1);
      c.drawRoundRect(x - r, y - r, x + r, y + r, r, r, p);
      p.setColor(0xff171e1b);
      c.drawCircle(x, y, r - 4, p);
      p.setColor(0xff949c92);
      c.drawRoundRect(x + r - 1, y - 8, x + r + 9, y + 12, 3, 3, p);
      p.setColor(0xfff2f1e8);
      p.setTypeface(Typeface.create("sans-serif-medium", Typeface.NORMAL));
      p.setTextSize(w * .15f);
      p.setTextAlign(Paint.Align.CENTER);
      c.drawText("CMF", x, y + 5, p);
      p.setColor(watch.connected ? ORANGE : 0xff616b63);
      c.drawCircle(x, y + r * .45f, 4, p);
    }
  }

  private static final class Icon extends View {
    private final int kind, color;
    private final Paint p = new Paint(3);

    Icon(Context c, int kind, int color) {
      super(c);
      this.kind = kind;
      this.color = color;
    }

    @Override
    protected void onDraw(Canvas c) {
      float s = getWidth() / 24f;
      c.save();
      c.scale(s, s);
      p.setColor(color);
      p.setStyle(Paint.Style.STROKE);
      p.setStrokeWidth(1.6f);
      p.setStrokeCap(Paint.Cap.ROUND);
      if (kind == 0) {
        c.drawRoundRect(5, 5, 19, 19, 6, 6, p);
        c.drawLine(8, 1, 16, 1, p);
        c.drawLine(8, 23, 16, 23, p);
        c.drawLine(12, 9, 12, 13, p);
        c.drawLine(12, 13, 15, 13, p);
      } else if (kind == 1) {
        Path path = new Path();
        path.moveTo(2, 5);
        path.lineTo(8, 2);
        path.lineTo(16, 5);
        path.lineTo(22, 2);
        path.lineTo(22, 19);
        path.lineTo(16, 22);
        path.lineTo(8, 19);
        path.lineTo(2, 22);
        path.close();
        c.drawPath(path, p);
        c.drawLine(8, 3, 8, 19, p);
        c.drawLine(16, 5, 16, 21, p);
      } else if (kind == 2) {
        for (int x : new int[] {3, 14})
          for (int y : new int[] {3, 14}) c.drawRoundRect(x, y, x + 7, y + 7, 1.5f, 1.5f, p);
      } else {
        c.drawCircle(12, 12, 4, p);
        for (int i = 0; i < 8; i++) {
          double a = i * Math.PI / 4;
          c.drawLine(
              12 + (float) Math.cos(a) * 8,
              12 + (float) Math.sin(a) * 8,
              12 + (float) Math.cos(a) * 10,
              12 + (float) Math.sin(a) * 10,
              p);
        }
      }
      c.restore();
    }
  }
}
