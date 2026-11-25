package com.vps2vpn.thirdparty;

import static org.junit.Assert.assertNotNull;
import static org.junit.Assume.assumeTrue;

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

import org.junit.FixMethodOrder;
import org.junit.Test;
import org.junit.runner.RunWith;
import org.junit.runners.MethodSorters;

import java.io.FileInputStream;
import java.io.InputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.List;
import java.util.regex.Pattern;

/**
 * vps2vpn server logic review C-5: does the subscription (sing-box format, chosen by the app's User-Agent)
 * import and connect in Hiddify and Karing on a real phone? For each app: get past its first-run screens,
 * import the link handed in as the hex argument "sub" through the app's own import link, connect, check that
 * traffic leaves through the line for 30 seconds, stop the app. Arguments: sub (hex), pkg_hiddify,
 * pkg_karing (an app without its package is skipped), probe=1 (stop after the import: for virtual phones,
 * where only the screens are wanted). Never logs the link, its host or an address.
 */
@RunWith(AndroidJUnit4.class)
@FixMethodOrder(MethodSorters.NAME_ASCENDING)
public class ThirdPartyTest {
    private static final String TAG = "vps2vpn-thirdparty";
    // Words on first-run screens that move on; tried in this order, one tap per round.
    private static final String ONBOARD = "(start|get started|开始|开始使用|accept & continue|continue|继续|next|下一步|agree|i agree|同意|"
            + "accept|接受|同意并继续|ok|okay|确定|好的|allow|允许|skip|跳过|done|完成|got it|知道了|confirm|确认|"
            + "not now|以后再说|later|稍后)";
    private static final String CONFIRM_IMPORT = "(ok|add|import|install|save|confirm|yes|确定|添加|导入|安装|保存|确认|是)";
    private static final String CONNECT = "(connect|tap to connect|点击连接|连接|start|启动|disconnected|未连接|已断开)";

    private Instrumentation instrumentation;
    private UiDevice device;
    private Context context;
    private String sub;
    private boolean probe;
    private final List<String> secrets = new ArrayList<>();

    @Test
    public void a_hiddify() throws Exception {
        String pkg = setUp("pkg_hiddify");
        // https://hiddify.com/app/URL-Scheme/ : hiddify://import/<link>#<name>
        run("hiddify", pkg, "hiddify://import/" + sub + "#testlab");
    }

    @Test
    public void b_karing() throws Exception {
        String pkg = setUp("pkg_karing");
        // karing://install-config?url=<encoded link>&name=<name>
        run("karing", pkg, "karing://install-config?url=" + Uri.encode(sub) + "&name=testlab");
    }

    private String setUp(String pkgArg) {
        instrumentation = InstrumentationRegistry.getInstrumentation();
        device = UiDevice.getInstance(instrumentation);
        context = instrumentation.getTargetContext();
        Bundle args = InstrumentationRegistry.getArguments();
        String pkg = args.getString(pkgArg);
        assumeTrue(pkgArg + " not given: skipped", pkg != null && !pkg.isEmpty());
        String hex = args.getString("sub");
        assertNotNull("no subscription argument", hex);
        sub = new String(fromHex(hex), StandardCharsets.UTF_8);
        probe = "1".equals(args.getString("probe"));
        secrets.add(hex);
        secrets.add(sub);
        secrets.add(Uri.encode(sub));
        String host = Uri.parse(sub).getHost();
        if (host != null && !host.isEmpty()) {
            secrets.add(host);
        }
        return pkg;
    }

    private void run(String name, String pkg, String importLink) throws Exception {
        step(name + ": start");
        shell("appops set " + pkg + " ACTIVATE_VPN allow");
        shell("pm grant " + pkg + " android.permission.POST_NOTIFICATIONS");
        String directIp = fetch("https://api.ipify.org");
        step(name + ": direct internet works: " + (directIp != null));

        Intent launch = context.getPackageManager().getLaunchIntentForPackage(pkg);
        assertNotNull(name + " is not installed", launch);
        launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_CLEAR_TASK);
        context.startActivity(launch);
        check(device.wait(Until.hasObject(By.pkg(pkg).depth(0)), 40_000), name + " did not open");
        sleep(6_000);
        note(name + " first screen");
        onboard(name, 8);

        sleep(8_000);
        // Hiddify's core may still be starting ("Couldn't connect, Tap to try again"): give it a nudge first.
        if (tap("(tap to try again)", 2_000)) {
            sleep(10_000);
            note(name + " after retrying its core");
        }
        for (int attempt = 1; attempt <= 3; attempt++) {
            Intent view = new Intent(Intent.ACTION_VIEW, Uri.parse(importLink));
            view.setPackage(pkg);
            view.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
            context.startActivity(view);
            sleep(5_000);
            note(name + " after the import link (" + attempt + ")");
            step(name + ": import confirmation tapped: " + tap(CONFIRM_IMPORT, 8_000));
            sleep(12_000);                                // it downloads the subscription
            String seen = screen();
            report("NOTE  " + name + " after the import (" + attempt + "): " + seen);
            if (!seen.matches("(?is).*(failed|error|失败|错误).*")) {
                break;
            }
            tap("(ok|确定)", 3_000);
            sleep(15_000);
        }
        onboard(name, 4);
        if (probe) {
            context.startActivity(launch.setFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_REORDER_TO_FRONT));
            sleep(4_000);
            note(name + " home (probe: not connecting)");
            stop(pkg);
            return;
        }

        context.startActivity(launch.setFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_REORDER_TO_FRONT));
        sleep(4_000);
        note(name + " before connecting");
        boolean tapped = tap(CONNECT, 15_000);
        if (!tapped) {                                    // a bare switch or round button without words
            UiObject2 sw = device.findObject(By.pkg(pkg).checkable(true));
            if (sw != null) {
                sw.click();
                tapped = true;
            }
        }
        check(tapped, name + ": no connect button");
        tap("(ok|确定|allow|允许)", 3_000);
        check(waitVpn(true, 60_000), name + ": the VPN did not come up");
        step(name + ": the VPN is up");
        sleep(5_000);
        note(name + " connected");

        for (int i = 1; i <= 3; i++) {
            sleep(10_000);
            int code = status("http://connectivitycheck.gstatic.com/generate_204");
            check(code == 204, name + ": generate_204 through the VPN at " + (i * 10) + " s answered " + code);
            step(name + ": still up and answering at " + (i * 10) + " s");
        }
        String vpnIp = fetch("https://api.ipify.org");
        check(vpnIp != null, name + ": no public address through the VPN");
        if (directIp != null) {
            check(!directIp.equals(vpnIp), name + ": traffic did not leave through the line");
        }
        step(name + ": traffic leaves through the line (address changed)");
        stop(pkg);
        check(waitVpn(false, 30_000), name + ": the VPN did not go down after stopping the app");
        step(name + ": done");
    }

    private void onboard(String name, int rounds) {
        for (int i = 0; i < rounds; i++) {
            if (!tap(ONBOARD, 3_000)) {
                return;
            }
            sleep(2_000);
            note(name + " onboarding " + (i + 1));
        }
    }

    private void stop(String pkg) throws Exception {
        shell("am force-stop " + pkg);
        sleep(3_000);
    }

    private void check(boolean ok, String message) {
        if (!ok) {
            throw new AssertionError(message + " | screen: " + screen());
        }
    }

    private void note(String where) {
        report("NOTE  " + where + ": " + screen());
    }

    private void step(String message) {
        report("PASS  " + message);
    }

    private void report(String line) {
        Log.i(TAG, line);
        Bundle status = new Bundle();
        status.putString(Instrumentation.REPORT_KEY_STREAMRESULT, line + "\n");
        instrumentation.sendStatus(0, status);
    }

    /** The labels on screen (and which ones are clickable or checkable), with the link and addresses blanked. */
    private String screen() {
        try {
            java.io.ByteArrayOutputStream dump = new java.io.ByteArrayOutputStream();
            device.dumpWindowHierarchy(dump);
            java.util.regex.Matcher m = Pattern.compile("<node [^>]*?(?: text=\"([^\"]*)\")[^>]*?(?: content-desc=\"([^\"]*)\")[^>]*?"
                    + "checkable=\"(true|false)\"[^>]*?clickable=\"(true|false)\"").matcher(dump.toString("UTF-8"));
            StringBuilder labels = new StringBuilder();
            while (m.find() && labels.length() < 2500) {
                String text = (m.group(1) + " " + m.group(2)).trim();
                boolean checkable = "true".equals(m.group(3));
                boolean clickable = "true".equals(m.group(4));
                if (text.isEmpty() && !checkable) {
                    continue;
                }
                labels.append(labels.length() == 0 ? "" : " | ")
                        .append(text.replace("&#10;", "/").replace('\n', '/'))
                        .append(checkable ? " [switch]" : clickable ? " [btn]" : "");
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

    private boolean tap(String regex, long timeoutMs) {
        // Flutter puts a button's words in content-desc, sometimes with a second line under them.
        // Karing's language page reads "Language\nNext", so one line above the words is allowed too.
        Pattern pattern = Pattern.compile("^(?:[^\\n]*\\n)?\\s*(?:" + regex + ")\\s*(?:\\n.*)?$", Pattern.CASE_INSENSITIVE | Pattern.DOTALL);
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
