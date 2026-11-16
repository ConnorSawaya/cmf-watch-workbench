package app.cmfworkbench;

import static app.cmfworkbench.protocol.Bytes.*;

import android.annotation.SuppressLint;
import android.bluetooth.*;
import android.bluetooth.le.*;
import android.content.*;
import android.net.Uri;
import android.os.*;
import app.cmfworkbench.protocol.*;
import java.io.*;
import java.nio.charset.StandardCharsets;
import java.util.*;
import java.util.concurrent.*;
import java.util.function.*;
import org.json.*;

/** App-scoped state. Unknown hardware readings stay null until a valid reply arrives. */
@SuppressLint("MissingPermission")
public final class WatchController {
  public record Device(BluetoothDevice handle, String name, int signal) {}

  public final Context context;
  public final ExecutorService worker = Executors.newSingleThreadExecutor();
  private final ScheduledExecutorService timer = Executors.newSingleThreadScheduledExecutor();
  private final Handler main = new Handler(Looper.getMainLooper());
  private final SecretStore secrets;
  private volatile GattLink link;
  private volatile WatchSession session;
  private BluetoothDevice device;
  private int generation;
  private final List<Device> devices = new CopyOnWriteArrayList<>();
  public volatile boolean busy, connected, custom, standard, scanning;
  public volatile String status = "Ready to connect", firmware, problem;
  public volatile Integer battery;
  public volatile boolean charging;
  public volatile long batteryAt;
  public volatile int runningSlot = 255;
  public volatile double progress = -1;
  public volatile int received, total;
  public volatile List<AppPackage.Header> apps = new ArrayList<>();
  public volatile List<Settings.Alarm> alarms;
  public volatile List<Settings.Contact> contacts;
  private volatile Runnable listener = () -> {};
  private long lastAutoSync;
  private volatile boolean foreground;
  private long clockLocal, clockAt;

  public WatchController(Context context) {
    this.context = context;
    secrets = new SecretStore(context);
    timer.scheduleWithFixedDelay(this::poll, 3, 3, TimeUnit.SECONDS);
  }

  public void listen(Runnable callback) {
    listener = callback;
    publish();
  }

  public void foreground(boolean active) {
    foreground = active;
  }

  private void publish() {
    main.post(() -> listener.run());
  }

  public List<Device> devices() {
    return new ArrayList<>(devices);
  }

  public void error(Throwable error) {
    Throwable e = error;
    while ((e instanceof ExecutionException || e instanceof CompletionException)
        && e.getCause() != null) e = e.getCause();
    problem = e.getMessage() == null ? "The operation could not finish" : e.getMessage();
    status = "Operation stopped";
    publish();
  }

  public void run(String title, Throwing action) {
    synchronized (this) {
      if (busy) return;
      busy = true;
    }
    status = title;
    problem = null;
    progress = -1;
    publish();
    worker.execute(
        () -> {
          try {
            action.run();
          } catch (Exception e) {
            error(e);
          } finally {
            busy = false;
            progress = -1;
            publish();
          }
        });
  }

  public interface Throwing {
    void run() throws Exception;
  }

  public void scan() {
    BluetoothManager manager = context.getSystemService(BluetoothManager.class);
    BluetoothAdapter adapter = manager == null ? null : manager.getAdapter();
    if (adapter == null || !adapter.isEnabled()) {
      problem = "Turn on Bluetooth to find your watch";
      publish();
      return;
    }
    BluetoothLeScanner scanner = adapter.getBluetoothLeScanner();
    if (scanner == null) return;
    devices.clear();
    scanning = true;
    status = "Looking for Watch Pro 2";
    publish();
    scanner.startScan(scanCallback);
    main.postDelayed(this::stopScan, 15000);
  }

  private final ScanCallback scanCallback =
      new ScanCallback() {
        @Override
        public void onScanResult(int type, ScanResult result) {
          String name =
              result.getScanRecord() == null ? null : result.getScanRecord().getDeviceName();
          if (name == null) name = result.getDevice().getName();
          if (name == null || !name.toLowerCase(Locale.ROOT).contains("watch pro 2")) return;
          BluetoothDevice d = result.getDevice();
          devices.removeIf(v -> v.handle().equals(d));
          devices.add(new Device(d, name, result.getRssi()));
          publish();
        }

        @Override
        public void onScanFailed(int error) {
          scanning = false;
          problem = "Bluetooth scan could not start (" + error + ")";
          publish();
        }
      };

  public void stopScan() {
    try {
      BluetoothAdapter a = context.getSystemService(BluetoothManager.class).getAdapter();
      if (a != null && a.isEnabled()) a.getBluetoothLeScanner().stopScan(scanCallback);
    } catch (Exception ignored) {
    }
    scanning = false;
    publish();
  }

  public void connect(BluetoothDevice d) {
    stopScan();
    run(
        "Connecting to watch",
        () -> {
          int token = ++generation;
          closeLink();
          device = d;
          GattLink next =
              new GattLink(
                  context,
                  d,
                  () -> {
                    if (token == generation) {
                      connected = false;
                      custom = false;
                      standard = false;
                      status = "Watch disconnected";
                      publish();
                    }
                  });
          link = next;
          try {
            next.connect();
            connected = true;
            WatchSession s = new WatchSession(next);
            session = s;
            firmware = s.at("GETVERSION");
            byte[] auth = secrets.get(d.getAddress());
            if (auth != null) {
              s.resume(auth);
              standard = true;
              syncClock();
              readBattery();
            }
            try {
              s.openCustom();
              custom = true;
              refreshApps();
            } catch (Exception unavailable) {
              custom = false;
            }
            status = custom ? "Watch connected" : "Connected. Install the loader to add apps.";
          } catch (Exception e) {
            next.close();
            connected = false;
            throw e;
          }
        });
  }

  private void closeLink() {
    WatchSession s = session;
    session = null;
    if (s != null) s.close();
    GattLink g = link;
    link = null;
    if (g != null) g.close();
    custom = false;
    standard = false;
    connected = false;
  }

  public void disconnect() {
    generation++;
    closeLink();
    busy = false;
    status = "Disconnected";
    context.stopService(new Intent(context, ConnectionService.class));
    publish();
  }

  public void pairStandard() {
    run(
        "Pairing standard controls",
        () -> {
          require(session != null && device != null, "Connect your watch first");
          byte[] auth = session.pair();
          secrets.put(device.getAddress(), auth);
          standard = true;
          syncClock();
          readBattery();
          status = "Standard controls paired";
        });
  }

  private void ensureStandard() {
    require(session != null && standard, "Pair standard controls in Device first");
  }

  private void syncClock() throws Exception {
    ensureStandard();
    long now = System.currentTimeMillis(), epoch = now / 1000;
    int offset = TimeZone.getDefault().getOffset(now);
    long previous = context.getSharedPreferences("settings", 0).getLong("clock-local", 0);
    long elapsed = clockAt == 0 ? 0 : (SystemClock.elapsedRealtime() - clockAt) / 1000;
    session.clock(epoch, offset, previous, elapsed);
    clockLocal = epoch + offset / 1000L;
    clockAt = SystemClock.elapsedRealtime();
    context.getSharedPreferences("settings", 0).edit().putLong("clock-local", clockLocal).apply();
  }

  public void syncTime() {
    run(
        "Syncing watch clock",
        () -> {
          syncClock();
          readBattery();
          status = "Date, time and battery synced";
        });
  }

  private void readBattery() throws Exception {
    Settings.Battery b = session.battery();
    battery = b.percent();
    charging = b.charging();
    batteryAt = System.currentTimeMillis();
  }

  public void refreshBattery() {
    run(
        "Reading watch battery",
        () -> {
          ensureStandard();
          readBattery();
          status = "Battery read from watch";
        });
  }

  private void refreshApps() throws Exception {
    apps = Transfer.list(session);
    runningSlot = session.ping()[0];
  }

  public void refresh() {
    run(
        "Reading installed apps",
        () -> {
          require(custom, "Connect to the app loader first");
          refreshApps();
          status = "Installed apps read from watch";
        });
  }

  public void findWatch(boolean active) {
    run(
        active ? "Finding watch" : "Stopping find watch",
        () -> {
          ensureStandard();
          session.write(0x5d, new byte[] {(byte) (active ? 1 : 0)});
          status = "Watch acknowledged";
        });
  }

  public String deviceKey() {
    return device == null ? "" : device.getAddress();
  }

  public void transferFace(File file, int id, boolean delete, Runnable confirmed) {
    run(
        delete ? "Removing watch face" : "Installing watch face",
        () -> {
          ensureStandard();
          if (custom) require(session.ping()[0] == 255, "Close the custom app on the watch first");
          require(file.length() <= WatchFace.MAX_BYTES, "Face is too large");
          WatchFace face;
          try (InputStream in = new FileInputStream(file)) {
            face = new WatchFace(FaceFiles.read(in, WatchFace.MAX_BYTES));
          }
          total = face.bytes().length;
          session.uploadFace(
              face,
              id,
              delete,
              n -> {
                received = n;
                progress = (double) n / total;
                publish();
              });
          confirmed.run();
          status =
              delete
                  ? "Watch confirmed the face was removed"
                  : "Watch confirmed the face is active";
        });
  }

  public void installBundled(String name) {
    run(
        "Reading tested app",
        () -> {
          JSONObject found = null;
          JSONArray manifest =
              new JSONArray(
                  new String(
                      readAsset("generated/tested-packages.json", 100000), StandardCharsets.UTF_8));
          for (int i = 0; i < manifest.length(); i++)
            if (manifest.getJSONObject(i).getString("name").equals(name))
              found = manifest.getJSONObject(i);
          require(found != null, "Build and stage this app's reviewed package first");
          byte[] b = readAsset("generated/" + name + ".wp2app", 262208);
          AppPackage p = new AppPackage(b);
          require(
              p.sha256.equals(found.getString("sha256"))
                  && b.length == found.getInt("bytes")
                  && p.version == found.getLong("version")
                  && p.kind == found.getInt("kind"),
              "App does not match its reviewed package record");
          require(custom, "Connect to the app loader first");
          ensureStandard();
          readBattery();
          Transfer.preflight(
              firmware, battery, System.currentTimeMillis() - batteryAt, session.ping()[0]);
          total = b.length;
          Transfer.install(
              session,
              p,
              n -> {
                received = n;
                progress = (double) n / total;
                publish();
              });
          refreshApps();
          status = name + " installed and confirmed";
        });
  }

  public void importPackage(Uri uri) {
    run(
        "Checking imported app",
        () -> {
          byte[] b = read(uri, 262208);
          AppPackage p = new AppPackage(b);
          JSONArray manifest =
              new JSONArray(
                  new String(
                      readAsset("generated/tested-packages.json", 100000), StandardCharsets.UTF_8));
          boolean accepted = false;
          for (int i = 0; i < manifest.length(); i++) {
            JSONObject r = manifest.getJSONObject(i);
            if (r.getString("name").equals(p.name)
                && r.getString("sha256").equals(p.sha256)
                && r.getInt("bytes") == b.length
                && r.getLong("version") == p.version
                && r.getInt("kind") == p.kind) accepted = true;
          }
          require(
              accepted,
              "This package is not in the companion's reviewed build list. Stage and rebuild the"
                  + " companion after emulator testing.");
          require(custom, "Connect to the app loader first");
          ensureStandard();
          readBattery();
          Transfer.preflight(
              firmware, battery, System.currentTimeMillis() - batteryAt, session.ping()[0]);
          total = b.length;
          Transfer.install(
              session,
              p,
              n -> {
                received = n;
                progress = (double) n / total;
                publish();
              });
          refreshApps();
          status = p.name + " installed and confirmed";
        });
  }

  private void poll() {
    if (!foreground || busy || !custom || session == null) return;
    synchronized (this) {
      if (busy) return;
      busy = true;
    }
    worker.execute(
        () -> {
          try {
            int[] ping = session.ping();
            runningSlot = ping[0];
            if (runningSlot == 255
                && standard
                && true
                && System.currentTimeMillis() - lastAutoSync >= 5 * 60 * 1000) {
              syncClock();
              readBattery();
              lastAutoSync = System.currentTimeMillis();
            }
          } catch (Exception e) {
            if (connected) status = "Sync will retry when the watch is ready";
          } finally {
            busy = false;
            publish();
          }
        });
  }

  public byte[] read(Uri uri, int limit) throws IOException {
    try (InputStream stream = context.getContentResolver().openInputStream(uri)) {
      if (stream == null) throw new IOException("Could not open file");
      return bounded(stream, limit);
    }
  }

  private byte[] readAsset(String name, int limit) throws IOException {
    try (InputStream stream = context.getAssets().open(name)) {
      return bounded(stream, limit);
    }
  }

  public static byte[] readFile(File file, int limit) throws IOException {
    try (InputStream stream = new FileInputStream(file)) {
      return bounded(stream, limit);
    }
  }

  private static byte[] bounded(InputStream input, int limit) throws IOException {
    ByteArrayOutputStream out = new ByteArrayOutputStream();
    byte[] buffer = new byte[8192];
    int n;
    while ((n = input.read(buffer)) != -1) {
      if (out.size() + n > limit) throw new IOException("File exceeds the supported size");
      out.write(buffer, 0, n);
    }
    return out.toByteArray();
  }

  private void writeAtomic(String name, byte[] bytes) throws IOException {
    File next = new File(context.getFilesDir(), name + ".part"),
        target = new File(context.getFilesDir(), name);
    try (FileOutputStream out = new FileOutputStream(next)) {
      out.write(bytes);
      out.getFD().sync();
    }
    if (!next.renameTo(target)) throw new IOException("Could not save imported file");
  }
}
