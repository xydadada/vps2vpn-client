package com.vps2vpn.probe;

import android.app.Activity;
import android.content.Intent;
import android.net.VpnService;
import android.os.Bundle;

public class Main extends Activity {
    @Override
    protected void onCreate(Bundle state) {
        super.onCreate(state);
        Intent consent = VpnService.prepare(this);
        if (consent != null) {
            startActivityForResult(consent, 1);
        } else {
            start();
        }
    }

    @Override
    protected void onActivityResult(int request, int result, Intent data) {
        start();
    }

    private void start() {
        startService(new Intent(this, Tun.class).putExtras(getIntent()));
        finish();
    }
}
