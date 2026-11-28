package com.vps2vpn.testlab;

import static org.junit.Assert.assertNotNull;

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
    private final java.util.List<String> secrets = new java.util.ArrayList<>();

    @Test
    public void importConnectBrowseDisconnect() throws Exception {
        instrumentation = InstrumentationRegistry.getInstrumentation();
        device = UiDevice.getInstance(instrumentation);
        context = instrumentation.getTargetContext();
        Bundle args = InstrumentationRegistry.getArguments();
        String hex = args.getString("sub");
        assertNotNull("no subscription argument", hex);
        String sub = new String(fromHex(hex), StandardCharsets.UTF_8);
        secrets.add(hex);
        secrets.add(sub);
        secrets.add(Uri.encode(sub));
        // The window dump is XML, so the link's & shows there as &amp;.
        secrets.add(sub.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace("\"", "&quot;").replace("'", "&apos;"));
        String host = Uri.parse(sub).getHost();
        if (host != null && !host.isEmpty()) {
            secrets.add(host);
        }
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
        check(device.wait(Until.hasObject(By.pkg(PKG).depth(0)), 30_000), "the app did not open");
        step("the app opened");
        note("first screen");

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
        sleep(4_000);
        note("after the import link");
        // The emulator run imports without any dialog; a confirmation is optional.
        step("import confirmation tapped: " + tap("(ok|confirm|add|import|确定|确认|添加|导入)", 10_000));
        sleep(10_000);
        context.startActivity(launch.setFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_REORDER_TO_FRONT));
        sleep(3_000);
        note("before connecting");

        check(tap("(connect|连接|tap to connect|点击连接|启动|start)", 20_000), "no connect button");
        tap("(ok|确定)", 3_000);
        check(waitVpn(true, 45_000), "the VPN did not come up");
        step("the VPN is up");
        note("connected");

        for (int i = 1; i <= 6; i++) {
            sleep(10_000);
            check(device.hasObject(By.pkg(PKG)) || device.getCurrentPackageName() != null, "the phone stopped answering after " + (i * 10) + " s");
            int code = status("http://connectivitycheck.gstatic.com/generate_204");
            check(code == 204, "generate_204 through the VPN at " + (i * 10) + " s answered " + code);
            step("still up and answering at " + (i * 10) + " s");
        }
        String vpnIp = fetch("https://api.ipify.org");
        check(vpnIp != null, "no public address through the VPN");
        if (directIp != null) {
            check(!directIp.equals(vpnIp), "traffic did not leave through the line");
        }
        step("traffic leaves through the line (address changed)");

        if (!tap("(disconnect|断开|断开连接|stop|停止)", 5_000)) {
            tap("(connected|已连接)", 5_000);
        }
        check(waitVpn(false, 30_000), "the VPN did not go down");
        step("the VPN is down after disconnecting");
    }

    private void check(boolean ok, String message) {
        if (!ok) {
            throw new AssertionError(message + " | screen: " + screen());
        }
    }

    private void note(String where) {
        String line = "NOTE  " + where + ": " + screen();
        Log.i(TAG, line);
        Bundle status = new Bundle();
        status.putString(android.app.Instrumentation.REPORT_KEY_STREAMRESULT, line + "\n");
        instrumentation.sendStatus(0, status);
    }

    /** The labels on screen, with the link, its host and any address blanked. */
    private String screen() {
        try {
            java.io.ByteArrayOutputStream dump = new java.io.ByteArrayOutputStream();
            device.dumpWindowHierarchy(dump);
            java.util.regex.Matcher m = Pattern.compile(" (?:text|content-desc)=\"([^\"]+)\"").matcher(dump.toString("UTF-8"));
            StringBuilder labels = new StringBuilder();
            while (m.find() && labels.length() < 1500) {
                labels.append(labels.length() == 0 ? "" : " | ").append(m.group(1).replace("&#10;", "/").replace('\n', '/'));
            }
            String text = labels.toString();
            for (String secret : secrets) {
                text = text.replace(secret, "<hidden>");
            }
            return text.replaceAll("\\b\\d{1,3}(\\.\\d{1,3}){3}\\b", "x.x.x.x")
                    .replaceAll("(?i)\\b[0-9a-f]{1,4}(:[0-9a-f]{0,4}){2,7}\\b", "x:x::x");
        } catch (Exception e) {
            return "(no dump: " + e.getClass().getSimpleName() + ")";
        }
    }

    private void step(String message) {
        Log.i(TAG, "PASS  " + message);
        Bundle status = new Bundle();
        status.putString(android.app.Instrumentation.REPORT_KEY_STREAMRESULT, "PASS  " + message + "\n");
        instrumentation.sendStatus(0, status);
    }

    private boolean tap(String regex, long timeoutMs) {
        // Flutter puts a button's words in content-desc, sometimes with a second line under them.
        Pattern pattern = Pattern.compile("^\\s*(?:" + regex + ")\\s*(?:\\n.*)?$", Pattern.CASE_INSENSITIVE | Pattern.DOTALL);
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
