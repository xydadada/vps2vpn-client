package core

import (
	"maps"
	"testing"
)

func TestShareLinksRejectUnrepresentableTLSIdentity(t *testing.T) {
	for _, kind := range []string{"trojan", "hysteria", "hysteria2", "anytls", "http"} {
		for _, key := range []string{"name-cert-verify", "certificate", "private-key"} {
			t.Run(kind+"/"+key, func(t *testing.T) {
				fields := proxyFields{
					"name": "test", "type": kind, "server": "node.example", "port": 443,
					"password": "test-password", "auth-str": "test-auth", "tls": true,
					"skip-cert-verify": true,
				}
				if link := encodeShareLink(fields); link == "" {
					t.Fatal("supported TLS settings should remain exportable")
				}
				fields[key] = "test-identity"
				if link := encodeShareLink(fields); link != "" {
					t.Fatal("share link would discard the configured TLS identity")
				}
			})
		}
	}
}

func TestShareLinksRejectChangedTLSRequirements(t *testing.T) {
	cases := map[string]proxyFields{
		"TLS SOCKS":         {"type": "socks5", "tls": true},
		"default HTTPS":     {"type": "http", "tls": true},
		"verified HTTPS":    {"type": "http", "tls": true, "skip-cert-verify": false},
		"HTTPS SNI":         {"type": "http", "tls": true, "skip-cert-verify": true, "sni": "tls.example"},
		"HTTPS cert pin":    {"type": "http", "tls": true, "skip-cert-verify": true, "fingerprint": "test-pin"},
		"Hysteria cert pin": {"type": "hysteria", "fingerprint": "test-pin"},
	}
	for name, fields := range cases {
		t.Run(name, func(t *testing.T) {
			fields["name"], fields["server"], fields["port"] = "test", "node.example", 443
			fields["username"], fields["password"] = "test-user", "test-password"
			if link := encodeShareLink(fields); link != "" {
				decoded := handleDecodeShareLinks(LinesParams{Lines: []string{link}})
				t.Fatalf("share link changed TLS requirements: source=%v decoded=%v", fields, decoded)
			}
		})
	}
}

func TestShareLinksRoundTripSupportedTLSPolicies(t *testing.T) {
	for _, kind := range []string{"trojan", "hysteria2", "anytls"} {
		for _, insecure := range []bool{false, true} {
			fields := proxyFields{
				"name": kind, "type": kind, "server": "node.example", "port": 443,
				"password": "test-password", "sni": "tls.example",
				"fingerprint": "test-pin", "skip-cert-verify": insecure,
			}
			decoded := decodeOneShareLink(t, fields)
			for _, key := range []string{"sni", "fingerprint", "skip-cert-verify"} {
				if decoded[key] != fields[key] {
					t.Errorf("%s %s changed: got %v, want %v", kind, key, decoded[key], fields[key])
				}
			}
		}
	}
}

func TestShareLinksRoundTripHttpAndSocksCredentials(t *testing.T) {
	protocols := map[string]proxyFields{
		"http":   {"type": "http"},
		"https":  {"type": "http", "tls": true, "skip-cert-verify": true},
		"socks5": {"type": "socks5"},
	}
	credentials := map[string][2]string{
		"plain":           {"test-user", "test-password"},
		"URL punctuation": {"user@name", "p@ss%word"},
		"empty user":      {"", "p@ss"},
		"empty password":  {"user name", ""},
		"Unicode":         {"user", "口令"},
	}
	for kind, protocol := range protocols {
		for name, pair := range credentials {
			t.Run(kind+"/"+name, func(t *testing.T) {
				fields := maps.Clone(protocol)
				fields["name"], fields["server"], fields["port"] = "test", "node.example", 443
				fields["username"], fields["password"] = pair[0], pair[1]
				decoded := decodeOneShareLink(t, fields)
				for _, key := range []string{"username", "password"} {
					if decoded[key] != fields[key] {
						t.Errorf("%s changed after export and import", key)
					}
				}
			})
		}
	}
}

func TestShareLinksRejectUnrepresentableCredentials(t *testing.T) {
	cases := map[string]proxyFields{
		"SOCKS username colon": {"type": "socks5", "username": "user:alias", "password": "pass"},
		"HTTP password colon":  {"type": "http", "username": "user", "password": "pass:word"},
		"escaped base64":       {"type": "socks5", "username": "???", "password": "???"},
		"Hysteria2 password":   {"type": "hysteria2", "password": "p@ss"},
		"Hysteria2 userpass":   {"type": "hysteria2", "password": "user:p@ss"},
		"Hysteria2 two colons": {"type": "hysteria2", "password": "user:pass:word"},
	}
	for name, fields := range cases {
		t.Run(name, func(t *testing.T) {
			fields["name"], fields["server"], fields["port"] = "test", "node.example", 443
			if link := encodeShareLink(fields); link != "" {
				t.Fatal("share link would change authentication credentials")
			}
		})
	}
}

func decodeOneShareLink(t *testing.T, fields proxyFields) map[string]any {
	t.Helper()
	link := encodeShareLink(fields)
	decoded := handleDecodeShareLinks(LinesParams{Lines: []string{link}})
	if len(decoded) != 1 || len(decoded[0]) != 1 {
		t.Fatalf("supported proxy did not round trip: %v", decoded)
	}
	return decoded[0][0]
}
