package com.vps2vpn.probe;

import android.content.Intent;
import android.net.IpPrefix;
import android.net.VpnService;
import android.os.Build;
import android.os.ParcelFileDescriptor;
import android.util.Log;
import java.io.FileInputStream;
import java.net.InetAddress;

/** The app's tunnel shape (address, DNS, MTU, routes) with nothing behind it: packets are read and dropped. */
public class Tun extends VpnService {
    private ParcelFileDescriptor tun;

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        int mtu = intent == null ? 9000 : intent.getIntExtra("mtu", 9000);
        try {
            Builder builder = new Builder()
                .setSession("vpn probe")
                .setMtu(mtu)
                .addAddress("198.18.0.1", 30)
                .addDnsServer("198.18.0.2")
                .addRoute("0.0.0.0", 0);
            if (Build.VERSION.SDK_INT >= 33) {
                builder.excludeRoute(new IpPrefix(InetAddress.getByName("10.0.0.0"), 8));
            }
            tun = builder.establish();
        } catch (Exception error) {
            Log.e("vpnprobe", "establish failed", error);
            return START_NOT_STICKY;
        }
        Log.i("vpnprobe", "up mtu=" + mtu);
        final ParcelFileDescriptor fd = tun;
        new Thread(() -> {
            byte[] packet = new byte[65536];
            long count = 0;
            long empty = 0;
            try (FileInputStream in = new FileInputStream(fd.getFileDescriptor())) {
                for (int n; (n = in.read(packet)) >= 0; ) {
                    if (n == 0) {
                        if (++empty % 100000 == 1) Log.i("vpnprobe", "empty reads " + empty);
                        Thread.sleep(5);
                        continue;
                    }
                    if (++count % 100 == 1) Log.i("vpnprobe", "packets " + count + " last " + n + " bytes");
                }
            } catch (Exception error) {
                Log.i("vpnprobe", "reader stopped after " + count, error);
            }
        }).start();
        return START_STICKY;
    }
}
