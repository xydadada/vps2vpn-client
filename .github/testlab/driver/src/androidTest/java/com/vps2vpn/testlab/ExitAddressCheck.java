package com.vps2vpn.testlab;

final class ExitAddressCheck {
    private ExitAddressCheck() {}

    static boolean available(String address) {
        if (address == null) {
            return false;
        }
        String value = address.trim();
        if (!value.matches("(?:0|[1-9][0-9]{0,2})(?:\\.(?:0|[1-9][0-9]{0,2})){3}")) {
            return false;
        }
        for (String octet : value.split("\\.")) {
            if (Integer.parseInt(octet) > 255) {
                return false;
            }
        }
        return true;
    }

    static boolean changed(String direct, String tunneled) {
        return available(direct) && available(tunneled)
                && !direct.trim().equals(tunneled.trim());
    }
}
