package app.cmfworkbench;

import android.Manifest;
import android.app.*;
import android.bluetooth.*;
import android.content.*;
import android.content.pm.PackageManager;
import android.graphics.*;
import android.net.Uri;
import android.os.*;
import android.view.*;
import android.widget.*;
import com.google.zxing.*;
import com.google.zxing.common.HybridBinarizer;
import java.io.*;
import java.util.*;
import java.util.concurrent.*;
import org.json.*;

/** A small companion shell for building and installing custom watch apps. */
public final class MainActivity extends Activity {
  private static final int APP_FILE = 11, QR_IMAGE = 14, PAPER = 0xfff6f5f0, INK = 0xff1d2c26;
  private WatchController watch;
  private LinearLayout root, content;
  private int tab;
  private String fingerprint = "";
  private Runnable afterPermission;
  private final ExecutorService worker = Executors.newSingleThreadExecutor();

  @Override
  public void onCreate(Bundle state) {
    super.onCreate(state);
    watch = ((WorkbenchApp) getApplication()).watch;
    tab = getIntent().getIntExtra("start_tab", 0);
    if (tab != 0 && tab != 1 && tab != 3) tab = 0;
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
            Insets i = insets.getInsets(WindowInsets.Type.systemBars());
            v.setPadding(i.left, i.top, i.right, i.bottom);
          }
          return insets;
        });
    content = new LinearLayout(this);
    content.setOrientation(LinearLayout.VERTICAL);
    root.addView(content, new LinearLayout.LayoutParams(-1, 0, 1));
    LinearLayout nav = new LinearLayout(this);
    nav.setPadding(dp(12), dp(8), dp(12), dp(10));
    for (int value : new int[] {0, 1, 3}) {
      String label = value == 0 ? "Watch" : value == 1 ? "Apps" : "Device";
      Button b =
          button(
              label,
              () -> {
                tab = value;
                fingerprint = "";
                refresh();
              });
      nav.addView(b, new LinearLayout.LayoutParams(0, dp(52), 1));
    }
    root.addView(nav);
    refresh();
  }

  @Override
  public void onResume() {
    super.onResume();
    watch.foreground(true);
    watch.listen(this::refresh);
  }

  @Override
  public void onPause() {
    super.onPause();
    watch.foreground(false);
    watch.listen(() -> {});
  }

  @Override
  public void onDestroy() {
    worker.shutdownNow();
    super.onDestroy();
  }

  private int dp(int n) {
    return Math.round(n * getResources().getDisplayMetrics().density);
  }

  private Button button(String title, Runnable run) {
    Button b = new Button(this);
    b.setText(title);
    b.setAllCaps(false);
    b.setOnClickListener(v -> run.run());
    return b;
  }

  private void text(LinearLayout page, String value, int size, boolean muted) {
    TextView t = new TextView(this);
    t.setText(value);
    t.setTextSize(size);
    t.setTextColor(muted ? 0xff6c756e : INK);
    t.setPadding(0, dp(8), 0, dp(10));
    page.addView(t);
  }

  private void action(LinearLayout page, String title, Runnable run, boolean enabled) {
    Button b = button(title, run);
    b.setEnabled(enabled);
    page.addView(b, new LinearLayout.LayoutParams(-1, dp(54)));
  }

  private void label(LinearLayout page, String name, String value) {
    LinearLayout row = new LinearLayout(this);
    TextView a = new TextView(this), b = new TextView(this);
    a.setText(name);
    b.setText(value);
    b.setTextColor(0xff6c756e);
    row.setPadding(0, dp(12), 0, dp(12));
    row.addView(a, new LinearLayout.LayoutParams(0, -2, 1));
    row.addView(b);
    page.addView(row);
  }

  private void refresh() {
    if (watch.busy) getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
    else getWindow().clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
    String key =
        tab
            + "|"
            + watch.status
            + watch.problem
            + watch.busy
            + watch.connected
            + watch.custom
            + watch.standard
            + watch.firmware
            + watch.battery
            + watch.apps
            + watch.devices()
            + watch.received;
    if (key.equals(fingerprint)) return;
    fingerprint = key;
    content.removeAllViews();
    ScrollView scroll = new ScrollView(this);
    LinearLayout page = new LinearLayout(this);
    page.setOrientation(LinearLayout.VERTICAL);
    page.setPadding(dp(24), dp(20), dp(24), dp(24));
    scroll.addView(page);
    content.addView(scroll);
    text(page, tab == 1 ? "Custom apps" : tab == 3 ? "Device" : "CMF Workbench", 30, false);
    text(page, watch.status, 15, true);
    if (watch.problem != null) text(page, watch.problem, 14, false);
    if (watch.busy) {
      ProgressBar bar = new ProgressBar(this, null, android.R.attr.progressBarStyleHorizontal);
      bar.setIndeterminate(watch.progress < 0);
      bar.setMax(1000);
      if (watch.progress >= 0) bar.setProgress((int) (watch.progress * 1000));
      page.addView(bar);
      if (watch.total > 0) text(page, watch.received + " / " + watch.total + " bytes", 13, true);
    }
    if (tab == 1) {
      apps(page);
      return;
    }
    label(page, "Connection", watch.connected ? "Connected" : "Disconnected");
    label(
        page,
        "Battery",
        watch.battery == null
            ? "Not read"
            : watch.battery + "%" + (watch.charging ? " · Charging" : ""));
    label(page, "Firmware", watch.firmware == null ? "Not read" : watch.firmware);
    label(page, "Custom app channel", watch.custom ? "Responding" : "Not connected");
    if (watch.connected) action(page, "Disconnect watch", watch::disconnect, !watch.busy);
    else
      action(
          page,
          watch.scanning ? "Scanning…" : "Find watch",
          () -> permissions(watch::scan),
          !watch.busy && !watch.scanning);
    for (WatchController.Device d : watch.devices())
      action(
          page,
          d.name() + " · " + d.signal() + " dBm",
          () -> permissions(() -> connect(d.handle())),
          !watch.busy);
    action(
        page,
        "Watch faces",
        () -> startActivity(new Intent(this, FaceActivity.class)),
        !watch.busy);
    if (tab == 0) {
      text(page, "A base for your own apps", 21, false);
      text(
          page,
          "Connect your watch, install reviewed packages and build your own features with the Rust"
              + " SDK and phone protocol library.",
          16,
          true);
      action(
          page,
          "Build and install guide",
          () ->
              startActivity(
                  new Intent(
                      Intent.ACTION_VIEW,
                      Uri.parse(
                          "https://github.com/ConnorSawaya/cmf-watch-workbench/blob/main/docs/getting-started.md"))),
          true);
      return;
    }
    text(page, "Pairing", 21, false);
    action(page, "Pair standard controls", watch::pairStandard, watch.connected && !watch.busy);
    action(page, "Read QR code from image", () -> pick(QR_IMAGE, "image/*"), !watch.busy);
    action(page, "Use pairing QR link", this::qrDialog, !watch.busy);
    text(
        page,
        "Use reset pairing only while the watch shows its setup screen. Install the initial stock"
            + " loader patch separately before adding custom apps.",
        14,
        true);
    text(page, "Clock and status", 21, false);
    action(page, "Sync date, time & battery", watch::syncTime, watch.standard && !watch.busy);
    action(page, "Read battery", watch::refreshBattery, watch.standard && !watch.busy);
    action(page, "Find watch", () -> watch.findWatch(true), watch.standard && !watch.busy);
    action(page, "Stop finding watch", () -> watch.findWatch(false), watch.standard && !watch.busy);
    text(page, "Watch Pro 2 · JX402 / D398 · Firmware 1.0.0.73", 13, true);
  }

  private void apps(LinearLayout page) {
    text(page, "Examples", 21, false);
    try (InputStream in = getAssets().open("generated/tested-packages.json")) {
      JSONArray records =
          new JSONArray(
              new String(FaceFiles.read(in, 100000), java.nio.charset.StandardCharsets.UTF_8));
      for (int i = 0; i < records.length(); i++) {
        JSONObject r = records.getJSONObject(i);
        String name = r.getString("name");
        action(
            page,
            r.getInt("kind") == 1 ? "Install or update loader" : "Install " + name,
            () -> watch.installBundled(name),
            watch.custom && !watch.busy);
      }
    } catch (Exception absent) {
      text(page, "Build, verify and stage the example packages to include them here.", 15, true);
    }
    action(page, "Import tested app package", () -> pick(APP_FILE, "*/*"), !watch.busy);
    text(page, "On the watch", 21, false);
    if (watch.apps.isEmpty())
      text(page, watch.custom ? "No apps installed" : "Connect to read installed apps", 15, true);
    for (var app : watch.apps)
      label(page, app.kind() == 1 ? "App loader" : app.name(), "v" + app.version());
    action(page, "Refresh apps", watch::refresh, watch.custom && !watch.busy);
    text(
        page,
        "Return the watch to its clock face and close Custom Apps before installing. New packages"
            + " must match this companion’s tested manifest; ordinary app updates do not reflash"
            + " firmware.",
        14,
        true);
  }

  private void connect(BluetoothDevice device) {
    Intent service = new Intent(this, ConnectionService.class);
    startForegroundService(service);
    watch.connect(device);
  }

  private void permissions(Runnable action) {
    List<String> missing = new ArrayList<>();
    for (String p :
        Build.VERSION.SDK_INT >= 31
            ? new String[] {
              Manifest.permission.BLUETOOTH_SCAN, Manifest.permission.BLUETOOTH_CONNECT
            }
            : new String[] {Manifest.permission.ACCESS_FINE_LOCATION})
      if (checkSelfPermission(p) != PackageManager.PERMISSION_GRANTED) missing.add(p);
    if (missing.isEmpty()) {
      action.run();
      return;
    }
    afterPermission = action;
    requestPermissions(missing.toArray(new String[0]), 20);
  }

  @Override
  public void onRequestPermissionsResult(int request, String[] permissions, int[] grants) {
    super.onRequestPermissionsResult(request, permissions, grants);
    if (request == 20) {
      Runnable next = afterPermission;
      afterPermission = null;
      boolean allowed = grants.length > 0;
      for (int g : grants) allowed &= g == PackageManager.PERMISSION_GRANTED;
      if (allowed && next != null) next.run();
      else
        Toast.makeText(this, "Bluetooth permission is required to connect", Toast.LENGTH_LONG)
            .show();
    }
  }

  private void pick(int request, String type) {
    startActivityForResult(
        new Intent(Intent.ACTION_OPEN_DOCUMENT).setType(type).addCategory(Intent.CATEGORY_OPENABLE),
        request);
  }

  private void qrDialog() {
    EditText input = new EditText(this);
    input.setHint("Watch pairing URL");
    new AlertDialog.Builder(this)
        .setTitle("Pairing QR link")
        .setView(input)
        .setNegativeButton("Cancel", null)
        .setPositiveButton("Use link", (d, w) -> acceptQR(input.getText().toString()))
        .show();
  }

  private void acceptQR(String raw) {
    try {
      Uri uri = Uri.parse(raw);
      String fragment = uri.getFragment();
      if (fragment == null) throw new IllegalArgumentException("Unsupported watch QR");
      Uri query = Uri.parse("https://example.invalid/" + fragment);
      String value = query.getQueryParameter("M");
      if (value == null || !value.matches("(?i)[0-9a-f]{12}"))
        throw new IllegalArgumentException("Unsupported watch QR");
      Toast.makeText(
              this,
              "Select the watch ending in " + value.substring(8).toUpperCase(Locale.ROOT),
              Toast.LENGTH_LONG)
          .show();
      permissions(watch::scan);
    } catch (Exception e) {
      watch.error(e);
    }
  }

  @Override
  protected void onActivityResult(int request, int result, Intent data) {
    super.onActivityResult(request, result, data);
    if (result != RESULT_OK || data == null || data.getData() == null) return;
    Uri uri = data.getData();
    if (request == APP_FILE) {
      watch.importPackage(uri);
      return;
    }
    if (request == QR_IMAGE)
      worker.execute(
          () -> {
            try {
              BitmapFactory.Options o = new BitmapFactory.Options();
              o.inJustDecodeBounds = true;
              try (InputStream in = getContentResolver().openInputStream(uri)) {
                BitmapFactory.decodeStream(in, null, o);
              }
              o.inSampleSize = 1;
              while (Math.max(o.outWidth, o.outHeight) / o.inSampleSize > 1600) o.inSampleSize *= 2;
              o.inJustDecodeBounds = false;
              Bitmap bitmap;
              try (InputStream in = getContentResolver().openInputStream(uri)) {
                bitmap = BitmapFactory.decodeStream(in, null, o);
              }
              if (bitmap == null) throw new IOException("Could not read QR image");
              int w = bitmap.getWidth(), h = bitmap.getHeight();
              int[] pixels = new int[w * h];
              bitmap.getPixels(pixels, 0, w, 0, 0, w, h);
              Result decoded =
                  new MultiFormatReader()
                      .decode(
                          new BinaryBitmap(
                              new HybridBinarizer(new RGBLuminanceSource(w, h, pixels))));
              runOnUiThread(() -> acceptQR(decoded.getText()));
            } catch (Exception e) {
              watch.error(new IOException("No supported QR code found in this image"));
            }
          });
  }
}
