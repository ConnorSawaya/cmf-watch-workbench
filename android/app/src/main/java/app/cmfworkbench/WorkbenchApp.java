package app.cmfworkbench;

import android.app.Application;

public final class WorkbenchApp extends Application {
  public WatchController watch;

  @Override
  public void onCreate() {
    super.onCreate();
    watch = new WatchController(this);
  }
}
