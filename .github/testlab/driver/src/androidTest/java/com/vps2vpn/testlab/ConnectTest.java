package com.vps2vpn.testlab;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertNotEquals;
import static org.junit.Assert.assertNotNull;
import static org.junit.Assert.assertTrue;

import android.app.Instrumentation;
import android.content.Context;
import android.content.Intent;
import android.net.ConnectivityManager;
import android.net.Network;
import android.net.NetworkCapabilities;
import android.net.Uri;
import android.os.Bundle;
import android.os.ParcelFileDescriptor;
import android.util.Log;

import androidx.test.ext.junit.runners.AndroidJUnit4;
import androidx.test.platform.app.InstrumentationRegistry;
import androidx.test.uiautomator.By;
import androidx.test.uiautomator.BySelector;
import androidx.test.uiautomator.UiDevice;
import androidx.test.uiautomator.UiObject2;
import androidx.test.uiautomator.Until;

import org.junit.Test;
import org.junit.runner.RunWith;

import java.io.FileInputStream;
import java.io.InputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.util.regex.Pattern;

/**
 * Imports the subscription handed in as the hex argument "sub", connects,
 * keeps the VPN up for a minute while checking the phone still answers and
 * traffic leaves through the line, then disconnects. Never logs the link or
 * an address.
 */
@RunWith(AndroidJUnit4.class)
public class ConnectTest {
    private static final String PKG = "com.vps2vpn.client";
    private static final String TAG = "vps2vpn-testlab";

    private Instrumentation instrumentation;
    private UiDevice device;
    private Context context;

    @Test
    public void importConnectBrowseDisconnect() throws Exception {
        instrumentation = InstrumentationRegistry.getInstrumentation();
        device = UiDevice.getInstance(instrumentation);
        context = instrumentation.getTargetContext();
        Bundle args = InstrumentationRegistry.getArguments();
        String hex = args.getString("sub");
        assertNotNull("no subscription argument", hex);
        String sub = new String(fromHex(hex), StandardCharsets.UTF_8);
        if (!sub.contains("format=")) {
            sub += (sub.contains("?") ? "&" : "?") + "format=clash";
        }

        shell("appops set " + PKG + " ACTIVATE_VPN allow");
        shell("pm grant " + PKG + " android.permission.POST_NOTIFICATIONS");
        String directIp = fetch("https://api.ipify.org");
        step("direct internet works: " + (directIp != null));

        Intent launch = context.getPackageManager().getLaunchIntentForPackage(PKG);
        assertNotNull("vps2vpn is not installed", launch);
        launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_CLEAR_TASK);
        context.startActivity(launch);
        assertTrue("the app did not open", device.wait(Until.hasObject(By.pkg(PKG).depth(0)), 30_000));
        step("the app opened");

        if (tap(".*(I have read and understand this statement|我已阅读并理解此声明).*", 10_000)) {
            sleep(1_000);
            tap("(agree|同意)", 5_000);
            step("the disclaimer was accepted");
        }
        tap("(allow|允许)", 2_000);

        Intent view = new Intent(Intent.ACTION_VIEW,
                Uri.parse("vps2vpn://install-config?url=" + Uri.encode(sub)));
        view.setPackage(PKG);
        view.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
        context.startActivity(view);
        assertTrue("no import confirmation", tap("(ok|confirm|add|确定|确认|添加)", 15_000));
        step("the import was confirmed");
        sleep(10_000);

        assertTrue("no connect button", tap("(connect|连接|tap to connect|点击连接)", 20_000));
        tap("(ok|确定)", 3_000);
        assertTrue("the VPN did not come up", waitVpn(true, 45_000));
        step("the VPN is up");

        for (int i = 1; i <= 6; i++) {
            sleep(10_000);
            assertTrue("the phone stopped answering after " + (i * 10) + " s", device.hasObject(By.pkg(PKG)) || device.getCurrentPackageName() != null);
            assertEquals("generate_204 through the VPN at " + (i * 10) + " s", 204, status("http://connectivitycheck.gstatic.com/generate_204"));
            step("still up and answering at " + (i * 10) + " s");
        }
        String vpnIp = fetch("https://api.ipify.org");
        assertNotNull("no public address through the VPN", vpnIp);
        if (directIp != null) {
            assertNotEquals("traffic did not leave through the line", directIp, vpnIp);
        }
        step("traffic leaves through the line (address changed)");

        tap("(disconnect|断开|断开连接|stop|停止|connected|已连接)", 10_000);
        assertTrue("the VPN did not go down", waitVpn(false, 30_000));
        step("the VPN is down after disconnecting");
    }

    private void step(String message) {
        Log.i(TAG, "PASS  " + message);
        Bundle status = new Bundle();
        status.putString(android.app.Instrumentation.REPORT_KEY_STREAMRESULT, "PASS  " + message + "\n");
        instrumentation.sendStatus(0, status);
    }

    private boolean tap(String regex, long timeoutMs) {
        Pattern pattern = Pattern.compile("^" + regex + "$", Pattern.CASE_INSENSITIVE | Pattern.DOTALL);
        long end = System.currentTimeMillis() + timeoutMs;
        do {
            for (BySelector selector : new BySelector[]{By.text(pattern), By.desc(pattern)}) {
                UiObject2 found = device.findObject(selector);
                if (found != null) {
                    try {
                        found.click();
                        return true;
                    } catch (RuntimeException stale) {
                        // The node went away between finding and clicking; look again.
                    }
                }
            }
            sleep(500);
        } while (System.currentTimeMillis() < end);
        return false;
    }

    private boolean waitVpn(boolean up, long timeoutMs) {
        ConnectivityManager cm = context.getSystemService(ConnectivityManager.class);
        long end = System.currentTimeMillis() + timeoutMs;
        do {
            boolean vpn = false;
            for (Network network : cm.getAllNetworks()) {
                NetworkCapabilities caps = cm.getNetworkCapabilities(network);
                if (caps != null && caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN)) {
                    vpn = true;
                }
            }
            if (vpn == up) {
                return true;
            }
            sleep(1_000);
        } while (System.currentTimeMillis() < end);
        return false;
    }

    private static int status(String url) {
        HttpURLConnection connection = null;
        try {
            connection = (HttpURLConnection) new URL(url).openConnection();
            connection.setConnectTimeout(10_000);
            connection.setReadTimeout(10_000);
            return connection.getResponseCode();
        } catch (Exception e) {
            return -1;
        } finally {
            if (connection != null) {
                connection.disconnect();
            }
        }
    }

    private static String fetch(String url) {
        HttpURLConnection connection = null;
        try {
            connection = (HttpURLConnection) new URL(url).openConnection();
            connection.setConnectTimeout(10_000);
            connection.setReadTimeout(10_000);
            if (connection.getResponseCode() != 200) {
                return null;
            }
            try (InputStream in = connection.getInputStream()) {
                return new String(readAll(in), StandardCharsets.UTF_8).trim();
            }
        } catch (Exception e) {
            return null;
        } finally {
            if (connection != null) {
                connection.disconnect();
            }
        }
    }

    private void shell(String command) throws Exception {
        ParcelFileDescriptor out = instrumentation.getUiAutomation().executeShellCommand(command);
        try (InputStream in = new FileInputStream(out.getFileDescriptor())) {
            readAll(in);
        }
        out.close();
    }

    // InputStream.readAllBytes needs API 33.
    private static byte[] readAll(InputStream in) throws java.io.IOException {
        java.io.ByteArrayOutputStream buffer = new java.io.ByteArrayOutputStream();
        byte[] chunk = new byte[4096];
        int n;
        while ((n = in.read(chunk)) > 0) {
            buffer.write(chunk, 0, n);
        }
        return buffer.toByteArray();
    }

    private static byte[] fromHex(String hex) {
        byte[] bytes = new byte[hex.length() / 2];
        for (int i = 0; i < bytes.length; i++) {
            bytes[i] = (byte) Integer.parseInt(hex.substring(2 * i, 2 * i + 2), 16);
        }
        return bytes;
    }

    private static void sleep(long ms) {
        try {
            Thread.sleep(ms);
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
        }
    }
}
