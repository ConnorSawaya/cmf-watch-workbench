package app.cmfworkbench;

import static app.cmfworkbench.protocol.Bytes.*;

import android.annotation.SuppressLint;
import android.bluetooth.*;
import android.bluetooth.le.*;
import android.content.*;
import android.location.Location;
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

  public record SavedPlace(String name, double x, double y) {}

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
  public volatile Integer battery, satellites;
  public volatile boolean charging, gpsFix, gpsActive;
  public volatile long batteryAt, watchMapBytes;
  public volatile int runningSlot = 255;
  public volatile double progress = -1;
  public volatile int received, total;
  public volatile WatchMap map;
  public volatile String mapName = "No offline map";
  public volatile List<AppPackage.Header> apps = new ArrayList<>();
  public volatile List<Settings.Alarm> alarms;
  public volatile List<Settings.Contact> contacts;
  public final List<SavedPlace> saved = new CopyOnWriteArrayList<>();
  public volatile WatchHealth health = new WatchHealth();
  public volatile Location lastLocation;
  private volatile Runnable listener = () -> {};
  private long placesCRC = -1, lastAutoSync;
  private volatile boolean foreground;
  private long clockLocal, clockAt;

  public WatchController(Context context) {
    this.context = context;
    secrets = new SecretStore(context);
    loadLocal();
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
    placesCRC = -1;
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

  public void syncHealth() {
    run(
        "Syncing watch health",
        () -> {
          ensureStandard();
          syncClock();
          readBattery();
          session.syncHealth();
          health.merge(session.health);
          lastAutoSync = System.currentTimeMillis();
          saveHealth();
          status = "Health synced from watch";
        });
  }

  public void readAlarms() {
    run(
        "Reading alarms",
        () -> {
          ensureStandard();
          alarms = Settings.alarms(session.read(0x63));
          status = "Alarms read from watch";
        });
  }

  public void saveAlarms(List<Settings.Alarm> values) {
    run(
        "Saving alarms",
        () -> {
          ensureStandard();
          session.write(0x63, Settings.alarms(values));
          List<Settings.Alarm> readback = Settings.alarms(session.read(0x63));
          require(readback.size() == values.size(), "Alarm readback did not match");
          alarms = readback;
          status = "Alarms saved and read back";
        });
  }

  public void readContacts() {
    run(
        "Reading favorite contacts",
        () -> {
          ensureStandard();
          contacts = Settings.contacts(session.read(0xd5));
          status = "Contacts read from watch";
        });
  }

  public void saveContacts(List<Settings.Contact> values) {
    run(
        "Saving favorite contacts",
        () -> {
          ensureStandard();
          session.write(0xd5, Settings.contacts(values));
          List<Settings.Contact> result = Settings.contacts(session.read(0xd5));
          require(result.equals(values), "Contact readback did not match");
          contacts = result;
          status = "Contacts saved and read back";
        });
  }

  public void booleanSetting(String title, int ability, boolean enabled) {
    run(
        "Saving " + title,
        () -> {
          ensureStandard();
          session.write(ability, new byte[] {(byte) (enabled ? 1 : 0)});
          byte[] reply = session.read(ability);
          require(
              reply.length == 1 && reply[0] == (byte) (enabled ? 1 : 0),
              "Watch setting readback did not match");
          status = title + " saved";
        });
  }

  public void monitor(int kind, boolean enabled) {
    run(
        "Saving monitoring setting",
        () -> {
          ensureStandard();
          require(kind == 1 || kind == 2 || kind == 4, "Invalid monitoring kind");
          session.write(0x9b, new byte[] {(byte) kind, (byte) (enabled ? 1 : 0)});
          status = "Monitoring setting acknowledged";
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

  public void units(boolean imperial, boolean fahrenheit) {
    run(
        "Saving units",
        () -> {
          ensureStandard();
          session.units(imperial, fahrenheit);
          status = "Units saved and read back";
        });
  }

  public void goals(int steps, int meters, int kcal) {
    run(
        "Saving activity goals",
        () -> {
          ensureStandard();
          require(
              steps >= 2000
                  && steps <= 30000
                  && meters >= 1000
                  && meters <= 99000
                  && kcal >= 100
                  && kcal <= 5000,
              "Goals exceed watch limits");
          session.write(0x5e, join(be(steps, 4), be(meters, 4), be(kcal, 2)));
          status = "Activity goals acknowledged";
        });
  }

  public void profile(int height, int weight, int age, boolean male) {
    run(
        "Saving profile",
        () -> {
          ensureStandard();
          require(
              height >= 80
                  && height <= 255
                  && weight >= 20
                  && weight <= 255
                  && age >= 5
                  && age <= 120,
              "Profile values exceed watch limits");
          session.write(
              0x95, new byte[] {(byte) height, (byte) weight, (byte) age, (byte) (male ? 1 : 0)});
          status = "Profile acknowledged";
        });
  }

  public void reminder(int ability, Settings.Reminder reminder) {
    run(
        "Saving reminder",
        () -> {
          ensureStandard();
          require(ability == 0x60 || ability == 0x61, "Unsupported reminder");
          session.write(ability, Settings.reminder(reminder));
          require(
              Settings.reminder(session.read(ability)).equals(reminder),
              "Reminder readback did not match");
          status = "Reminder saved and read back";
        });
  }

  public void importMap(Uri uri) {
    run(
        "Checking offline map",
        () -> {
          byte[] b = read(uri, 9_200_000);
          WatchMap candidate = new WatchMap(b);
          writeAtomic("offline.wp2map", b);
          map = candidate;
          mapName = fileName(uri);
          context.getSharedPreferences("settings", 0).edit().putString("map-name", mapName).apply();
          status = "Offline map imported";
        });
  }

  private void loadLocal() {
    worker.execute(
        () -> {
          try {
            android.content.SharedPreferences location =
                context.getSharedPreferences("last-location", 0);
            if (location.contains("time")) {
              Location last = new Location("saved");
              last.setLatitude(Double.longBitsToDouble(location.getLong("lat", 0)));
              last.setLongitude(Double.longBitsToDouble(location.getLong("lon", 0)));
              last.setAccuracy(location.getFloat("accuracy", 1000));
              last.setTime(location.getLong("time", 0));
              if (Math.abs(last.getLatitude()) <= 85
                  && Math.abs(last.getLongitude()) <= 180
                  && last.getTime() <= System.currentTimeMillis()) lastLocation = last;
            }
            File file = new File(context.getFilesDir(), "offline.wp2map");
            if (file.exists()) {
              map = new WatchMap(readFile(file, 9_200_000));
              mapName =
                  context
                      .getSharedPreferences("settings", 0)
                      .getString("map-name", "Offline region");
            } else {
              try {
                map = new WatchMap(readAsset("generated/demo-map.wp2map", 9_200_000));
                mapName = "Monaco example";
              } catch (FileNotFoundException noExample) {
              }
            }
            String raw = context.getSharedPreferences("settings", 0).getString("places", "[]");
            JSONArray entries = new JSONArray(raw);
            for (int i = 0; i < Math.min(1000, entries.length()); i++) {
              JSONObject p = entries.getJSONObject(i);
              saved.add(new SavedPlace(p.getString("name"), p.getDouble("x"), p.getDouble("y")));
            }
            File h = new File(context.getFilesDir(), "health.json");
            if (h.exists()) {
              JSONObject json =
                  new JSONObject(new String(readFile(h, 8_000_000), StandardCharsets.UTF_8));
              JSONArray activity = json.optJSONArray("activity");
              if (activity != null)
                for (int i = 0; i < Math.min(15000, activity.length()); i++) {
                  JSONArray a = activity.getJSONArray(i);
                  health.activity.put(
                      a.getLong(0),
                      new WatchHealth.Activity(
                          a.getLong(0), a.getLong(1), a.getLong(2), a.getLong(3)));
                }
              JSONArray points = json.optJSONArray("points");
              if (points != null)
                for (int i = 0; i < Math.min(30000, points.length()); i++) {
                  JSONArray a = points.getJSONArray(i);
                  WatchHealth.Point point =
                      new WatchHealth.Point(a.getLong(0), a.getInt(1), a.getLong(2));
                  health.points.put(point.metric() + ":" + point.timestamp(), point);
                }
              JSONArray sleeps = json.optJSONArray("sleep");
              if (sleeps != null)
                for (int i = 0; i < Math.min(100, sleeps.length()); i++) {
                  JSONArray a = sleeps.getJSONArray(i);
                  WatchHealth.Sleep record =
                      new WatchHealth.Sleep(
                          a.getLong(0),
                          a.getLong(1),
                          a.getInt(2),
                          a.getInt(3),
                          a.getInt(4),
                          a.getInt(5));
                  health.sleep.put(record.start(), record);
                }
              health.syncedAt = json.optLong("syncedAt");
            }
          } catch (Exception e) {
            problem = "A saved file could not be read. Import that file again.";
          }
          publish();
        });
  }

  public void downloadMap() {
    run(
        "Downloading offline map",
        () -> {
          require(custom && map != null, "Connect to the app loader and import a map first");
          require(
              apps.stream().anyMatch(h -> h.name().equals("loader") && h.version() >= (map.codec==2?5:4))
                  && apps.stream().anyMatch(h -> h.name().equals("trail-map") && h.version() >= (map.codec==2?11:9)),
              "Update the loader and Trail Map first");
          require(session.ping()[0] == trailSlot(), "Open Trail Map on the watch first");
          total = map.data.length;
          Transfer.MapInfo info =
              Transfer.map(
                  session,
                  map,
                  n -> {
                    received = n;
                    progress = (double) n / total;
                    publish();
                  },
                  this::appMessage);
          watchMapBytes = info.bytes();
          Transfer.mapCamera(session, map, mapName, 0x7001, this::appMessage);
          status = "Offline map saved and verified on watch";
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

  public void savePlace(SavedPlace p) {
    require(
        Double.isFinite(p.x())
            && Double.isFinite(p.y())
            && Math.abs(p.x()) <= 21000000
            && Math.abs(p.y()) <= 21000000
            && !p.name().trim().isEmpty(),
        "Invalid saved place");
    saved.removeIf(old -> old.name().equals(p.name()) && old.x() == p.x() && old.y() == p.y());
    saved.add(p);
    while (saved.size() > 1000) saved.remove(0);
    persistPlaces();
    placesCRC = -1;
    publish();
  }

  public void mergePlaces(Collection<SavedPlace> places) {
    LinkedHashSet<SavedPlace> merged = new LinkedHashSet<>(saved);
    for (var p : places) {
      require(
          Double.isFinite(p.x())
              && Double.isFinite(p.y())
              && Math.abs(p.x()) <= 21000000
              && Math.abs(p.y()) <= 21000000
              && !p.name().trim().isEmpty(),
          "Invalid saved place");
      merged.remove(p);
      merged.add(p);
    }
    List<SavedPlace> all = new ArrayList<>(merged);
    saved.clear();
    saved.addAll(all.subList(Math.max(0, all.size() - 1000), all.size()));
    persistPlaces();
    placesCRC = -1;
    publish();
  }

  public void removePlace(SavedPlace p) {
    saved.remove(p);
    persistPlaces();
    placesCRC = -1;
    publish();
  }

  private void persistPlaces() {
    JSONArray all = new JSONArray();
    for (var p : saved) {
      JSONObject row = new JSONObject();
      try {
        row.put("name", p.name());
        row.put("x", p.x());
        row.put("y", p.y());
        all.put(row);
      } catch (JSONException impossible) {
        throw new IllegalArgumentException(impossible);
      }
    }
    context.getSharedPreferences("settings", 0).edit().putString("places", all.toString()).apply();
  }

  private int trailSlot() {
    for (var p : apps) if (p.name().equals("trail-map")) return p.slot();
    return -1;
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
            if (runningSlot == trailSlot()) {
              for (int i = 0; i < 8; i++) {
                try {
                  appMessage(session.receive(25));
                } catch (IOException empty) {
                  break;
                }
              }
              if (placesCRC < 0) syncPlaces();
              if (lastLocation != null && !gpsFix) sendLocation(lastLocation);
            }
            if (runningSlot == 255
                && standard
                && context.getSharedPreferences("settings", 0).getBoolean("auto-sync", true)
                && System.currentTimeMillis() - lastAutoSync >= 15 * 60 * 1000) {
              syncClock();
              readBattery();
              session.syncHealth();
              health.merge(session.health);
              lastAutoSync = System.currentTimeMillis();
              saveHealth();
            }
          } catch (Exception e) {
            if (connected) status = "Sync will retry when the watch is ready";
          } finally {
            busy = false;
            publish();
          }
        });
  }

  private void appMessage(byte[] b) {
    Transfer.MapInfo i = Transfer.MapInfo.parse(b);
    if (i != null) watchMapBytes = i.bytes();
    else if (b.length == 7 && b[0] == 84 && b[1] == 77 && b[2] == 1 && b[3] == 0x17) {
      gpsActive = b[4] == 1;
      gpsFix = b[5] == 1;
      satellites = (b[6] & 255) <= 100 ? b[6] & 255 : null;
    }
  }

  private void syncPlaces() throws Exception {
    List<SavedPlace> all = new ArrayList<>(saved);
    all = all.subList(Math.max(0, all.size() - 32), all.size());
    byte[] records = new byte[all.size() * 32];
    for (int i = 0; i < all.size(); i++) {
      SavedPlace p = all.get(i);
      System.arraycopy(le(Math.round(p.x()), 4), 0, records, i * 32, 4);
      System.arraycopy(le(Math.round(p.y()), 4), 0, records, i * 32 + 4, 4);
      String ascii = p.name().replaceAll("[^\\x20-\\x7e]", "");
      System.arraycopy(fixed(ascii, 24), 0, records, i * 32 + 8, 24);
    }
    long crc = crc(records);
    byte[] payload =
        join(
            "TP10".getBytes(StandardCharsets.US_ASCII),
            le(all.size(), 2),
            new byte[2],
            le(crc, 4),
            records);
    session.send(join(new byte[] {84, 77, 1, 0x40}, le(payload.length, 2)));
    ack(0xc0);
    for (int off = 0; off < payload.length; off += 120) {
      int next = Math.min(off + 120, payload.length);
      session.send(
          join(new byte[] {84, 77, 1, 0x41}, le(off, 2), Arrays.copyOfRange(payload, off, next)));
      require(ack(0xc1) == next, "Saved-place offset mismatch");
    }
    session.send(new byte[] {84, 77, 1, 0x42});
    require(ack(0xc2) == 0, "Saved places were not committed");
    session.send(new byte[] {84, 77, 1, 0x43});
    long until = System.nanoTime() + 8_000_000_000L;
    while (System.nanoTime() < until) {
      byte[] b = session.receive(1000);
      if (b.length == 10 && b[0] == 84 && b[1] == 77 && b[2] == 1 && b[3] == 0x44) {
        require((b[4] & 255) == all.size() && le(b, 6, 4) == crc, "Saved-place readback mismatch");
        placesCRC = crc;
        return;
      }
      appMessage(b);
    }
    throw new IOException("Saved places were not confirmed");
  }

  private int ack(int op) throws Exception {
    long end = System.nanoTime() + 8_000_000_000L;
    while (System.nanoTime() < end) {
      byte[] b = session.receive(1000);
      if (b.length == 8 && b[0] == 84 && b[1] == 77 && b[2] == 1 && (b[3] & 255) == op) {
        int n = (int) le(b, 4, 4);
        require(n >= 0, "Watch rejected saved places");
        return n;
      }
      appMessage(b);
    }
    throw new IOException("Saved-place acknowledgement timed out");
  }

  public void location(Location location) {
    if (location.getAccuracy() <= 0
        || location.getAccuracy() > 1000
        || Math.abs(location.getLatitude()) > 85) return;
    lastLocation = new Location(location);
    context
        .getSharedPreferences("last-location", 0)
        .edit()
        .putLong("lat", Double.doubleToRawLongBits(location.getLatitude()))
        .putLong("lon", Double.doubleToRawLongBits(location.getLongitude()))
        .putFloat("accuracy", location.getAccuracy())
        .putLong("time", location.getTime())
        .apply();
    publish();
  }

  private void sendLocation(Location p) throws Exception {
    long age = Math.max(0, (System.currentTimeMillis() - p.getTime()) / 1000);
    double x = Math.toRadians(p.getLongitude()) * 6378137,
        y = -6378137 * Math.log(Math.tan(Math.PI / 4 + Math.toRadians(p.getLatitude()) / 2));
    session.send(
        join(
            new byte[] {84, 77, 1, 6},
            le(Math.round(x), 4),
            le(Math.round(y), 4),
            le(Math.max(1, Math.min(1000, Math.round(p.getAccuracy()))), 2),
            new byte[] {(byte) (age < 10 ? 1 : 0), (byte) 255},
            le(p.getTime() / 1000, 4),
            le(age, 4)));
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

  private String fileName(Uri uri) {
    String name = null;
    try (android.database.Cursor c =
        context
            .getContentResolver()
            .query(
                uri,
                new String[] {android.provider.OpenableColumns.DISPLAY_NAME},
                null,
                null,
                null)) {
      if (c != null && c.moveToFirst()) name = c.getString(0);
    } catch (Exception ignored) {
    }
    return name == null ? "Offline region" : name.replaceFirst("\\.wp2map$", "");
  }

  private void saveHealth() throws Exception {
    JSONObject out = new JSONObject();
    JSONArray activity = new JSONArray();
    synchronized (health) {
      for (var p : health.activity.values())
        activity.put(
            new JSONArray()
                .put(p.timestamp())
                .put(p.steps())
                .put(p.meters())
                .put(p.milliCalories()));
    }
    JSONArray points = new JSONArray(), sleep = new JSONArray();
    synchronized (health) {
      for (var p : health.points.values())
        points.put(new JSONArray().put(p.timestamp()).put(p.metric()).put(p.value()));
      for (var p : health.sleep.values())
        sleep.put(
            new JSONArray()
                .put(p.start())
                .put(p.end())
                .put(p.deep())
                .put(p.light())
                .put(p.rem())
                .put(p.awake()));
    }
    out.put("activity", activity)
        .put("points", points)
        .put("sleep", sleep)
        .put("syncedAt", health.syncedAt);
    writeAtomic("health.json", out.toString().getBytes(StandardCharsets.UTF_8));
  }
}
