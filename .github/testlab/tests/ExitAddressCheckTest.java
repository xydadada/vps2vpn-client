package com.vps2vpn.testlab;

public final class ExitAddressCheckTest {
    public static void main(String[] args) {
        String direct = "198.51.100.1";
        String tunneled = "203.0.113.1";
        int checked = 0;
        for (String missing : new String[]{null, "", " \n", "<html>unavailable</html>",
                "rate limited", "256.1.2.3", "198.051.100.1", "198.51.100",
                "198.51.100.1.2", "ip.example.invalid", "2001:db8::1"}) {
            if (ExitAddressCheck.available(missing)
                    || ExitAddressCheck.changed(missing, tunneled)
                    || ExitAddressCheck.changed(direct, missing)) {
                throw new AssertionError("missing or malformed IPv4 evidence must never confirm an exit change");
            }
            checked += 3;
        }
        for (String same : new String[]{direct, " \n" + direct + "\n"}) {
            if (ExitAddressCheck.changed(direct, same)) {
                throw new AssertionError("an unchanged exit must not pass");
            }
            checked++;
        }
        if (!ExitAddressCheck.changed(direct, tunneled)) {
            throw new AssertionError("two observed distinct addresses must pass");
        }
        checked++;
        System.out.println(checked + " exit evidence checks passed");
    }
}
