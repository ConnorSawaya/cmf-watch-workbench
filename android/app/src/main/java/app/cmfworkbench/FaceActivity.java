package app.cmfworkbench;

import android.app.*;
import android.content.*;
import android.graphics.*;
import android.net.Uri;
import android.os.*;
import android.view.*;
import android.widget.*;
import app.cmfworkbench.protocol.WatchFace;
import java.io.*;
import java.util.*;
import java.util.concurrent.*;
import org.json.*;

public final class FaceActivity extends Activity {
  private static final int IMPORT = 41, PHOTO = 42, EXPORT = 43;
  private WatchController watch;
  private LinearLayout list;
  private TextView status;
  private ProgressBar progress;
  private final ExecutorService build = Executors.newSingleThreadExecutor();
  private String fingerprint = "";
  private File exporting;
  private Bitmap photo;
  private ImageView preview;
  private Spinner colors;
  private Switch rounded;
  private final int[] palette = {Color.WHITE, 0xffff7045, 0xffffc76a, 0xff9dd7ae, 0xff8ed9ed};

  private File folder() {
    File f = new File(getFilesDir(), "watch-faces");
    f.mkdirs();
    return f;
  }

  private List<File> files() {
    File[] f = folder().listFiles((p, n) -> n.endsWith(".wfdl"));
    if (f == null) return new ArrayList<>();
    List<File> r = new ArrayList<>(Arrays.asList(f));
    r.sort(Comparator.comparingLong(File::lastModified).reversed());
    return r;
  }

  private String installedKey(File file) {
    return "face-" + watch.deviceKey() + "-" + file.getName();
  }

  private int installed(File file) {
    return watch.deviceKey().isEmpty()
        ? 0
        : getSharedPreferences("watch-faces", 0).getInt(installedKey(file), 0);
  }

  @Override
  public void onCreate(Bundle state) {
    super.onCreate(state);
    watch = ((WorkbenchApp) getApplication()).watch;
    LinearLayout page = new LinearLayout(this);
    page.setOrientation(LinearLayout.VERTICAL);
    page.setPadding(dp(22), dp(24), dp(22), dp(14));
    page.setBackgroundColor(0xfff6f5f0);
    getWindow().setStatusBarColor(0xfff6f5f0);
    getWindow().setNavigationBarColor(0xfff6f5f0);
    getWindow()
        .getDecorView()
        .setSystemUiVisibility(
            View.SYSTEM_UI_FLAG_LIGHT_STATUS_BAR | View.SYSTEM_UI_FLAG_LIGHT_NAVIGATION_BAR);
    page.setOnApplyWindowInsetsListener(
        (v, insets) -> {
          if (Build.VERSION.SDK_INT >= 30) {
            Insets i = insets.getInsets(WindowInsets.Type.systemBars());
            v.setPadding(dp(22) + i.left, dp(24) + i.top, dp(22) + i.right, dp(14) + i.bottom);
          } else {
            v.setPadding(
                dp(22) + insets.getSystemWindowInsetLeft(),
                dp(24) + insets.getSystemWindowInsetTop(),
                dp(22) + insets.getSystemWindowInsetRight(),
                dp(14) + insets.getSystemWindowInsetBottom());
          }
          return insets;
        });
    setContentView(page);
    TextView title = new TextView(this);
    title.setText("Watch faces");
    title.setTextSize(30);
    title.setTextColor(0xff1d2c26);
    page.addView(title);
    TextView help = new TextView(this);
    help.setText(
        "Your own face on the watch home screen. Live clock, date, battery and a separate always-on"
            + " clock.");
    help.setPadding(0, dp(10), 0, dp(18));
    page.addView(help);
    Button create = button("Create watch face", this::designer);
    page.addView(create);
    page.addView(button("Import .wfdl or .bin", () -> pick(IMPORT, "*/*")));
    status = new TextView(this);
    status.setPadding(0, dp(12), 0, dp(8));
    page.addView(status);
    progress = new ProgressBar(this, null, android.R.attr.progressBarStyleHorizontal);
    progress.setMax(1000);
    page.addView(progress);
    ScrollView scroll = new ScrollView(this);
    list = new LinearLayout(this);
    list.setOrientation(LinearLayout.VERTICAL);
    scroll.addView(list);
    page.addView(scroll, new LinearLayout.LayoutParams(-1, 0, 1));
    page.addView(button("Back", this::finish));
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
    build.shutdownNow();
    super.onDestroy();
  }

  private int dp(int n) {
    return Math.round(n * getResources().getDisplayMetrics().density);
  }

  private Button button(String title, Runnable action) {
    Button b = new Button(this);
    b.setText(title);
    b.setAllCaps(false);
    b.setOnClickListener(v -> action.run());
    return b;
  }

  private void refresh() {
    if (watch.busy) getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
    else getWindow().clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
    status.setText(watch.status + (watch.problem == null ? "" : "\n" + watch.problem));
    progress.setVisibility(watch.busy ? View.VISIBLE : View.GONE);
    progress.setIndeterminate(watch.progress < 0);
    if (watch.progress >= 0) progress.setProgress((int) (watch.progress * 1000));
    String key =
        files().toString()
            + watch.busy
            + watch.deviceKey()
            + getSharedPreferences("watch-faces", 0).getAll();
    if (key.equals(fingerprint)) return;
    fingerprint = key;
    list.removeAllViews();
    for (File file : files()) {
      try {
        WatchFace face = new WatchFace(read(file, WatchFace.MAX_BYTES));
        LinearLayout card = new LinearLayout(this);
        card.setOrientation(LinearLayout.VERTICAL);
        card.setPadding(0, dp(18), 0, dp(18));
        ImageView image = new ImageView(this);
        File thumb = new File(file.getPath() + ".png");
        Bitmap bitmap = BitmapFactory.decodeFile(thumb.getPath());
        if (bitmap != null) {
          image.setImageBitmap(FaceArtwork.circular(bitmap));
          image.setScaleType(ImageView.ScaleType.FIT_CENTER);
          card.addView(image, new LinearLayout.LayoutParams(-1, dp(150)));
        }
        TextView label = new TextView(this);
        label.setText(
            face.name
                + " · "
                + android.text.format.Formatter.formatShortFileSize(this, file.length())
                + "\n"
                + (installed(file) > 0 ? "Installed on this watch" : "Saved on this phone"));
        label.setTextSize(17);
        card.addView(label);
        Button send =
            button(
                installed(file) > 0 ? "Installed" : "Install on watch", () -> install(file, false));
        send.setEnabled(!watch.busy && watch.standard && installed(file) == 0);
        card.addView(send);
        card.addView(
            button(
                "Export file",
                () -> {
                  exporting = file;
                  Intent i =
                      new Intent(Intent.ACTION_CREATE_DOCUMENT)
                          .setType("application/octet-stream")
                          .putExtra(Intent.EXTRA_TITLE, face.name + ".wfdl");
                  startActivityForResult(i, EXPORT);
                }));
        card.addView(
            button(
                installed(file) > 0 ? "Delete from watch" : "Delete saved face",
                () ->
                    new AlertDialog.Builder(this)
                        .setTitle(
                            installed(file) > 0
                                ? "Delete this face from the watch?"
                                : "Delete this saved face?")
                        .setNegativeButton("Cancel", null)
                        .setPositiveButton(
                            "Delete",
                            (d, w) -> {
                              if (installed(file) > 0) install(file, true);
                              else {
                                file.delete();
                                thumb.delete();
                                fingerprint = "";
                                refresh();
                              }
                            })
                        .show()));
        list.addView(card);
      } catch (Exception e) {
        TextView bad = new TextView(this);
        bad.setText("A saved face could not be read: " + e.getMessage());
        list.addView(bad);
      }
    }
  }

  private void install(File file, boolean remove) {
    String key = installedKey(file);
    android.content.SharedPreferences saved = getSharedPreferences("watch-faces", 0);
    int id = remove ? installed(file) : saved.getInt(key + "-pending", 0);
    if (id == 0) id = 10000 + new Random().nextInt(Integer.MAX_VALUE - 10000);
    if (!remove && !saved.edit().putInt(key + "-pending", id).commit()) {
      watch.error(new IOException("Could not save installation state"));
      return;
    }
    final int candidateID = id;
    watch.transferFace(
        file,
        id,
        remove,
        () -> {
          saved.edit().putInt(key, remove ? 0 : candidateID).remove(key + "-pending").apply();
        });
  }

  private void designer() {
    photo = null;
    LinearLayout form = new LinearLayout(this);
    form.setPadding(dp(22), dp(8), dp(22), dp(8));
    form.setOrientation(LinearLayout.VERTICAL);
    EditText name = new EditText(this);
    name.setHint("Face name");
    name.setText("My face");
    form.addView(name);
    colors = new Spinner(this);
    colors.setAdapter(
        new ArrayAdapter<>(
            this,
            android.R.layout.simple_spinner_dropdown_item,
            new String[] {"White", "Orange", "Amber", "Green", "Blue"}));
    form.addView(colors);
    rounded = new Switch(this);
    rounded.setText("Rounded digits");
    rounded.setChecked(true);
    form.addView(rounded);
    preview = new ImageView(this);
    preview.setImageBitmap(FaceArtwork.preview(palette[0], true, null));
    form.addView(preview, new LinearLayout.LayoutParams(-1, dp(220)));
    TextView hint = new TextView(this);
    hint.setText("Phone preview. The installed face reads live values from the watch.");
    form.addView(hint);
    form.addView(button("Choose background photo", () -> pick(PHOTO, "image/*")));
    colors.setOnItemSelectedListener(
        new android.widget.AdapterView.OnItemSelectedListener() {
          public void onItemSelected(android.widget.AdapterView<?> p, View v, int at, long id) {
            preview.setImageBitmap(FaceArtwork.preview(palette[at], rounded.isChecked(), photo));
          }

          public void onNothingSelected(android.widget.AdapterView<?> p) {}
        });
    rounded.setOnCheckedChangeListener(
        (b, on) ->
            preview.setImageBitmap(
                FaceArtwork.preview(palette[colors.getSelectedItemPosition()], on, photo)));
    ScrollView fields = new ScrollView(this);
    fields.addView(form);
    AlertDialog dialog =
        new AlertDialog.Builder(this)
            .setTitle("New watch face")
            .setView(fields)
            .setNegativeButton("Cancel", null)
            .setPositiveButton("Save face", null)
            .create();
    dialog.setOnShowListener(
        d ->
            dialog
                .getButton(-1)
                .setOnClickListener(
                    v -> {
                      String title = name.getText().toString();
                      int color = palette[colors.getSelectedItemPosition()];
                      boolean round = rounded.isChecked();
                      Bitmap photoCopy = photo;
                      dialog.getButton(-1).setEnabled(false);
                      build.execute(
                          () -> {
                            try {
                              save(FaceArtwork.make(title, color, round, photoCopy));
                              runOnUiThread(
                                  () -> {
                                    dialog.dismiss();
                                    fingerprint = "";
                                    refresh();
                                  });
                            } catch (Exception e) {
                              runOnUiThread(
                                  () -> {
                                    watch.error(e);
                                    dialog.getButton(-1).setEnabled(true);
                                  });
                            }
                          });
                    }));
    dialog.show();
  }

  private void save(WatchFace face) throws Exception {
    File file = new File(folder(), UUID.randomUUID() + ".wfdl");
    File pending = new File(file.getPath() + ".tmp");
    try {
      try (FileOutputStream out = new FileOutputStream(pending)) {
        out.write(face.bytes());
        out.getFD().sync();
      }
      if (!pending.renameTo(file)) throw new IOException("Could not save face");
    } finally {
      pending.delete();
    }
    WatchFace.Image image = face.preview;
    if (image != null && (image.format() == 4 || image.format() == 5))
      try (FileOutputStream out = new FileOutputStream(file.getPath() + ".png")) {
        FaceArtwork.bitmap(image).compress(Bitmap.CompressFormat.PNG, 100, out);
      }
  }

  private static byte[] read(File f, int max) throws Exception {
    try (InputStream in = new FileInputStream(f)) {
      byte[] data = FaceFiles.read(in, max);
      if (data.length > max) throw new IOException("Face exceeds its supported size");
      return data;
    }
  }

  private void pick(int request, String type) {
    startActivityForResult(
        new Intent(Intent.ACTION_OPEN_DOCUMENT).setType(type).addCategory(Intent.CATEGORY_OPENABLE),
        request);
  }

  @Override
  protected void onActivityResult(int request, int result, Intent data) {
    super.onActivityResult(request, result, data);
    if (result != RESULT_OK || data == null || data.getData() == null) return;
    Uri uri = data.getData();
    if (request == PHOTO) {
      try {
        BitmapFactory.Options o = new BitmapFactory.Options();
        o.inJustDecodeBounds = true;
        try (InputStream in = getContentResolver().openInputStream(uri)) {
          BitmapFactory.decodeStream(in, null, o);
        }
        o.inSampleSize = 1;
        while (Math.max(o.outWidth, o.outHeight) / o.inSampleSize > 1024) o.inSampleSize *= 2;
        o.inJustDecodeBounds = false;
        try (InputStream in = getContentResolver().openInputStream(uri)) {
          photo = BitmapFactory.decodeStream(in, null, o);
        }
        if (photo == null) throw new IOException("Could not read this photo");
        try (InputStream in = getContentResolver().openInputStream(uri)) {
          android.media.ExifInterface exif = new android.media.ExifInterface(in);
          int orientation = exif.getAttributeInt(android.media.ExifInterface.TAG_ORIENTATION, 1);
          android.graphics.Matrix transform = new android.graphics.Matrix();
          switch (orientation) {
            case 2 -> transform.setScale(-1, 1);
            case 3 -> transform.setRotate(180);
            case 4 -> transform.setScale(1, -1);
            case 5 -> {
              transform.setRotate(90);
              transform.postScale(-1, 1);
            }
            case 6 -> transform.setRotate(90);
            case 7 -> {
              transform.setRotate(270);
              transform.postScale(-1, 1);
            }
            case 8 -> transform.setRotate(270);
          }
          if (!transform.isIdentity())
            photo =
                Bitmap.createBitmap(
                    photo, 0, 0, photo.getWidth(), photo.getHeight(), transform, true);
        } catch (IOException ignored) {
          /* A valid image need not contain EXIF. */
        }
        if (preview != null)
          preview.setImageBitmap(
              FaceArtwork.preview(
                  palette[colors.getSelectedItemPosition()], rounded.isChecked(), photo));
      } catch (Exception e) {
        watch.error(e);
      }
    } else if (request == IMPORT) {
      build.execute(
          () -> {
            try (InputStream in = getContentResolver().openInputStream(uri)) {
              byte[] b = FaceFiles.read(in, WatchFace.MAX_BYTES);
              save(new WatchFace(b));
              runOnUiThread(
                  () -> {
                    fingerprint = "";
                    refresh();
                  });
            } catch (Exception e) {
              watch.error(e);
            }
          });
    } else if (request == EXPORT && exporting != null) {
      try (OutputStream out = getContentResolver().openOutputStream(uri)) {
        if (out == null) throw new IOException("Could not export face");
        out.write(read(exporting, WatchFace.MAX_BYTES));
      } catch (Exception e) {
        watch.error(e);
      }
    }
  }
}
