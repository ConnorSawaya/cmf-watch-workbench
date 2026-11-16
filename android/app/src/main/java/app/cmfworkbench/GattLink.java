package app.cmfworkbench;

import android.annotation.SuppressLint;
import android.bluetooth.*;
import android.content.Context;
import android.os.Build;
import app.cmfworkbench.protocol.WatchSession;
import java.io.IOException;
import java.util.*;
import java.util.concurrent.*;
import java.util.function.*;

/** All GATT requests are serialized. No protocol work blocks the UI thread. */
@SuppressLint("MissingPermission")
public final class GattLink implements WatchSession.Link, AutoCloseable {
  private final Context context;
  private final BluetoothDevice device;
  private BluetoothGatt gatt;
  private final CompletableFuture<Void> services = new CompletableFuture<>();
  private volatile CompletableFuture<Void> pending;
  private volatile BiConsumer<String, byte[]> listener = (u, b) -> {};
  private volatile boolean connected;
  private volatile int mtu = 23;
  private final Runnable disconnected;

  public GattLink(Context c, BluetoothDevice d, Runnable disconnected) {
    context = c;
    device = d;
    this.disconnected = disconnected;
  }

  public void connect() throws Exception {
    gatt = device.connectGatt(context, false, callback, BluetoothDevice.TRANSPORT_LE);
    if (gatt == null) throw new IOException("Bluetooth connection could not start");
    services.get(25, TimeUnit.SECONDS);
    if (mtu < 185)
      throw new IOException(
          "Watch did not negotiate the required Bluetooth MTU. Reconnect before transferring.");
    for (String uuid :
        new String[] {
          WatchSession.NOTIFY,
          WatchSession.SHELL_NOTIFY,
          WatchSession.BULK_NOTIFY,
          WatchSession.OTA_NOTIFY
        }) {
      BluetoothGattCharacteristic ch = find(uuid);
      if (ch == null) continue;
      BluetoothGattDescriptor descriptor =
          ch.getDescriptor(UUID.fromString("00002902-0000-1000-8000-00805f9b34fb"));
      if (descriptor == null) continue;
      if (!gatt.setCharacteristicNotification(ch, true))
        throw new IOException("Could not enable watch notifications");
      CompletableFuture<Void> completion = new CompletableFuture<>();
      pending = completion;
      byte[] value =
          (ch.getProperties() & BluetoothGattCharacteristic.PROPERTY_NOTIFY) != 0
              ? BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
              : BluetoothGattDescriptor.ENABLE_INDICATION_VALUE;
      boolean accepted;
      if (Build.VERSION.SDK_INT >= 33)
        accepted = gatt.writeDescriptor(descriptor, value) == BluetoothStatusCodes.SUCCESS;
      else {
        descriptor.setValue(value);
        accepted = gatt.writeDescriptor(descriptor);
      }
      if (!accepted) {
        pending = null;
        throw new IOException("Could not subscribe to the watch");
      }
      completion.get(10, TimeUnit.SECONDS);
      pending = null;
    }
    if (find(WatchSession.CMD) == null || find(WatchSession.SHELL) == null)
      throw new IOException("This device does not expose the Watch Pro 2 protocol");
  }

  private BluetoothGattCharacteristic find(String uuid) {
    if (gatt == null) return null;
    UUID id = UUID.fromString(uuid);
    for (BluetoothGattService s : gatt.getServices()) {
      BluetoothGattCharacteristic c = s.getCharacteristic(id);
      if (c != null) return c;
    }
    return null;
  }

  @Override
  public synchronized void write(String uuid, byte[] data) throws Exception {
    writeMode(uuid, data, BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT);
  }

  @Override
  public synchronized void writeWithoutResponse(String uuid, byte[] data) throws Exception {
    writeMode(uuid, data, BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE);
  }

  private void writeMode(String uuid, byte[] data, int mode) throws Exception {
    if (!connected) throw new IOException("Watch disconnected");
    BluetoothGattCharacteristic c = find(uuid);
    if (c == null) throw new IOException("Required watch channel is unavailable");
    if (data.length > mtu - 3) throw new IOException("Packet exceeds negotiated Bluetooth MTU");
    CompletableFuture<Void> completion = new CompletableFuture<>();
    pending = completion;
    try {
      boolean accepted;
      if (Build.VERSION.SDK_INT >= 33)
        accepted = gatt.writeCharacteristic(c, data, mode) == BluetoothStatusCodes.SUCCESS;
      else {
        c.setWriteType(mode);
        c.setValue(data);
        accepted = gatt.writeCharacteristic(c);
      }
      if (!accepted) throw new IOException("Bluetooth write could not start");
      completion.get(10, TimeUnit.SECONDS);
    } finally {
      pending = null;
    }
  }

  @Override
  public void listen(BiConsumer<String, byte[]> listener) {
    this.listener = listener;
  }

  private void complete(int status) {
    CompletableFuture<Void> p = pending;
    if (p != null) {
      if (status == BluetoothGatt.GATT_SUCCESS) p.complete(null);
      else p.completeExceptionally(new IOException("Bluetooth request failed (" + status + ")"));
    }
  }

  private final BluetoothGattCallback callback =
      new BluetoothGattCallback() {
        @Override
        public void onConnectionStateChange(BluetoothGatt g, int status, int state) {
          if (state == BluetoothProfile.STATE_CONNECTED && status == 0) {
            connected = true;
            g.requestConnectionPriority(BluetoothGatt.CONNECTION_PRIORITY_HIGH);
            if (!g.requestMtu(247)) g.discoverServices();
          } else if (state == BluetoothProfile.STATE_DISCONNECTED || status != 0) {
            connected = false;
            IOException e = new IOException("Watch disconnected");
            services.completeExceptionally(e);
            CompletableFuture<Void> p = pending;
            if (p != null) p.completeExceptionally(e);
            disconnected.run();
          }
        }

        @Override
        public void onMtuChanged(BluetoothGatt g, int value, int status) {
          if (status == 0) mtu = value;
          if (!g.discoverServices())
            services.completeExceptionally(new IOException("Could not discover watch services"));
        }

        @Override
        public void onServicesDiscovered(BluetoothGatt g, int status) {
          if (status == 0) services.complete(null);
          else services.completeExceptionally(new IOException("Watch service discovery failed"));
        }

        @Override
        public void onCharacteristicWrite(
            BluetoothGatt g, BluetoothGattCharacteristic c, int status) {
          complete(status);
        }

        @Override
        public void onDescriptorWrite(BluetoothGatt g, BluetoothGattDescriptor d, int status) {
          complete(status);
        }

        @Override
        public void onCharacteristicChanged(BluetoothGatt g, BluetoothGattCharacteristic c) {
          if (Build.VERSION.SDK_INT < 33)
            listener.accept(c.getUuid().toString(), c.getValue().clone());
        }

        @Override
        public void onCharacteristicChanged(
            BluetoothGatt g, BluetoothGattCharacteristic c, byte[] value) {
          listener.accept(c.getUuid().toString(), value.clone());
        }
      };

  @Override
  public void close() {
    connected = false;
    BluetoothGatt g = gatt;
    gatt = null;
    if (g != null) {
      g.disconnect();
      g.close();
    }
    CompletableFuture<Void> p = pending;
    if (p != null) p.completeExceptionally(new IOException("Connection closed"));
  }
}
