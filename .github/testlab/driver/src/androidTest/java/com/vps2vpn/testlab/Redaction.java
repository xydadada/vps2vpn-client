package com.vps2vpn.testlab;

import java.util.List;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

final class Redaction {
    private static final Pattern ENTITY = Pattern.compile("&(#x[0-9a-fA-F]+|#[0-9]+|amp|lt|gt|quot|apos);");

    private Redaction() {}

    static String scrub(String text, List<String> secrets) {
        text = decodeEntities(text);
        for (String secret : secrets) {
            text = text.replace(secret, "<hidden>").replace(decodeEntities(secret), "<hidden>");
        }
        return text.replaceAll("\\b\\d{1,3}(\\.\\d{1,3}){3}\\b", "x.x.x.x")
                .replaceAll("(?i)\\b[0-9a-f]{1,4}(:[0-9a-f]{0,4}){2,7}\\b", "x:x::x");
    }

    private static String decodeEntities(String text) {
        Matcher match = ENTITY.matcher(text);
        StringBuffer decoded = new StringBuffer();
        while (match.find()) {
            String entity = match.group(1);
            String value;
            switch (entity) {
                case "amp": value = "&"; break;
                case "lt": value = "<"; break;
                case "gt": value = ">"; break;
                case "quot": value = "\""; break;
                case "apos": value = "'"; break;
                default:
                    value = match.group();
                    try {
                        boolean hex = entity.startsWith("#x");
                        int point = Integer.parseInt(entity.substring(hex ? 2 : 1), hex ? 16 : 10);
                        if (Character.isValidCodePoint(point) && !(point >= 0xd800 && point <= 0xdfff)) {
                            value = new String(Character.toChars(point));
                        }
                    } catch (NumberFormatException ignored) {
                    }
            }
            match.appendReplacement(decoded, Matcher.quoteReplacement(value));
        }
        match.appendTail(decoded);
        return decoded.toString();
    }
}
