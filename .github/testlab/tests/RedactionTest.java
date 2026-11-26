package com.vps2vpn.testlab;

import java.util.Arrays;
import java.util.List;

public final class RedactionTest {
    public static void main(String[] args) {
        String subscription = "https://subscription.example.invalid/s/synthetic-token?format=clash&client=fixture";
        List<String> secrets = Arrays.asList(subscription, "subscription.example.invalid");
        for (String input : Arrays.asList(
                subscription,
                subscription.replace("&", "&amp;"),
                subscription.replace("&", "&#38;"),
                subscription.replace("&", "&#x26;"),
                subscription.replace("s", "&#115;"))) {
            String actual = Redaction.scrub("NOTE  " + input, secrets);
            if (!actual.equals("NOTE  <hidden>")) {
                throw new AssertionError("subscription must be hidden after XML entity decoding");
            }
        }
        String label = Redaction.scrub("Connected &amp; ready", secrets);
        if (!label.equals("Connected & ready")) {
            throw new AssertionError("ordinary labels should remain readable");
        }
        String malformed = "literal &#not-a-number; &#x110000; &#999999999999;";
        if (!Redaction.scrub(malformed, secrets).equals(malformed)) {
            throw new AssertionError("invalid entities should remain literal");
        }
        String literal = subscription + "&note=&amp;";
        for (String input : Arrays.asList(literal, literal.replace("&", "&amp;"))) {
            if (!Redaction.scrub(input, Arrays.asList(literal)).equals("<hidden>")) {
                throw new AssertionError("subscriptions containing literal entities must remain hidden");
            }
        }
        System.out.println("9 redaction cases passed");
    }
}
