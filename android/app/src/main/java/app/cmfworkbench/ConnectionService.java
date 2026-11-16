package app.cmfworkbench;

import android.app.*;
import android.content.*;
import android.os.IBinder;

public final class ConnectionService extends Service {
  private static final String CHANNEL = "watch-connection";

  @Override
  public void onCreate() {
    super.onCreate();
    NotificationManager manager = getSystemService(NotificationManager.class);
    manager.createNotificationChannel(
        new NotificationChannel(CHANNEL, "Watch connection", NotificationManager.IMPORTANCE_LOW));
  }

  @Override
  public int onStartCommand(Intent intent, int flags, int id) {
    if (intent != null && "disconnect".equals(intent.getAction())) {
      ((WorkbenchApp) getApplication()).watch.disconnect();
      stopSelf();
      return START_NOT_STICKY;
    }
    show("Connecting to watch");
    return START_NOT_STICKY;
  }

  void show(String status) {
    Intent open = new Intent(this, MainActivity.class);
    PendingIntent tap =
        PendingIntent.getActivity(
            this, 0, open, PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT);
    PendingIntent stop =
        PendingIntent.getService(
            this,
            1,
            new Intent(this, ConnectionService.class).setAction("disconnect"),
            PendingIntent.FLAG_IMMUTABLE);
    Notification n =
        new Notification.Builder(this, CHANNEL)
            .setContentTitle("CMF Workbench")
            .setContentText(status)
            .setSmallIcon(android.R.drawable.stat_sys_data_bluetooth)
            .setContentIntent(tap)
            .addAction(new Notification.Action.Builder(null, "Disconnect", stop).build())
            .setOngoing(true)
            .build();
    startForeground(7, n);
  }

  @Override
  public IBinder onBind(Intent intent) {
    return null;
  }
}
