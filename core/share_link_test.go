package core

import (
	"fmt"
	"strings"
	"testing"

	"github.com/metacubex/mihomo/common/convert"
)

func lookupField(proxy map[string]any, path string) any {
	var value any = proxy
	for _, key := range strings.Split(path, ".") {
		mapping, ok := value.(map[string]any)
		if !ok {
			return nil
		}
		value = mapping[key]
	}
	return value
}

func TestShareLinksReadBackThroughTheConverter(t *testing.T) {
	cases := []struct {
		proxy  map[string]any
		prefix string
		want   map[string]string
	}{
		{
			proxy: map[string]any{
				"name": "ss node", "type": "ss", "server": "a.example", "port": 8388,
				"cipher": "aes-256-gcm", "password": "p@ss:word", "udp-over-tcp": true,
				"plugin": "obfs", "plugin-opts": map[string]any{"mode": "tls", "host": "cdn.example"},
			},
			prefix: "ss://aes-256-gcm:p%40ss%3Aword@a.example:8388",
			want: map[string]string{
				"name": "ss node", "server": "a.example", "port": "8388",
				"cipher": "aes-256-gcm", "password": "p@ss:word", "udp-over-tcp": "true",
				"plugin": "obfs", "plugin-opts.mode": "tls", "plugin-opts.host": "cdn.example",
			},
		},
		{
			proxy: map[string]any{
				"name": "ss 2022", "type": "ss", "server": "2001:db8::1", "port": 443,
				"cipher": "2022-blake3-aes-128-gcm", "password": "AAAAAAAAAAAAAAAAAAAAAA==",
			},
			want: map[string]string{
				"server": "2001:db8::1", "cipher": "2022-blake3-aes-128-gcm",
				"password": "AAAAAAAAAAAAAAAAAAAAAA==",
			},
		},
		{
			proxy: map[string]any{
				"name": "ssr", "type": "ssr", "server": "b.example", "port": 443,
				"cipher": "chacha20-ietf", "password": "secret", "obfs": "tls1.2_ticket_auth",
				"protocol": "auth_aes128_md5", "obfs-param": "obfs.example", "protocol-param": "1:p",
			},
			want: map[string]string{
				"name": "ssr", "server": "b.example", "port": "443", "cipher": "chacha20-ietf",
				"password": "secret", "obfs": "tls1.2_ticket_auth", "protocol": "auth_aes128_md5",
				"obfs-param": "obfs.example", "protocol-param": "1:p",
			},
		},
		{
			proxy: map[string]any{
				"name": "vmess ws", "type": "vmess", "server": "c.example", "port": 443,
				"uuid": "b831381d-6324-4d53-ad4f-8cda48b30811", "alterId": 64, "cipher": "auto",
				"tls": true, "servername": "sni.example", "network": "ws",
				"ws-opts": map[string]any{
					"path": "/ray", "headers": map[string]any{"Host": "host.example"},
					"max-early-data": 2048,
				},
			},
			prefix: "vmess://eyJ",
			want: map[string]string{
				"name": "vmess ws", "server": "c.example", "port": "443",
				"uuid": "b831381d-6324-4d53-ad4f-8cda48b30811", "alterId": "64", "cipher": "auto",
				"tls": "true", "servername": "sni.example", "network": "ws",
				"ws-opts.path": "/ray", "ws-opts.headers.Host": "host.example",
				"ws-opts.max-early-data": "2048",
			},
		},
		{
			proxy: map[string]any{
				"name": "vmess grpc", "type": "vmess", "server": "c.example", "port": "443",
				"uuid": "u", "cipher": "aes-128-gcm", "network": "grpc",
				"grpc-opts": map[string]any{"grpc-service-name": "svc"},
			},
			prefix: "vmess://u@c.example:443?",
			want: map[string]string{
				"network": "grpc", "grpc-opts.grpc-service-name": "svc", "tls": "<nil>",
				"alterId": "0", "cipher": "aes-128-gcm",
			},
		},
		{
			proxy: map[string]any{
				"name": "vmess aead ws", "type": "vmess", "server": "c.example", "port": 443,
				"uuid": "u", "alterId": 0, "cipher": "auto", "tls": true,
				"servername": "sni.example", "client-fingerprint": "chrome", "network": "ws",
				"ws-opts": map[string]any{
					"path": "/ray", "headers": map[string]any{"Host": "host.example"},
				},
			},
			prefix: "vmess://u@c.example:443?",
			want: map[string]string{
				"name": "vmess aead ws", "cipher": "auto", "tls": "true",
				"servername": "sni.example", "client-fingerprint": "chrome", "network": "ws",
				"ws-opts.path": "/ray", "ws-opts.headers.Host": "host.example",
			},
		},
		{
			proxy: map[string]any{
				"name": "vmess httpupgrade", "type": "vmess", "server": "c.example", "port": 443,
				"uuid": "u", "alterId": 64, "cipher": "auto", "network": "ws",
				"ws-opts": map[string]any{
					"path": "/up", "headers": map[string]any{"Host": "host.example"},
					"v2ray-http-upgrade": true, "v2ray-http-upgrade-fast-open": true,
				},
			},
			prefix: "vmess://eyJ",
			want: map[string]string{
				"network": "ws", "ws-opts.path": "/up", "ws-opts.headers.Host": "host.example",
				"ws-opts.v2ray-http-upgrade": "true", "ws-opts.v2ray-http-upgrade-fast-open": "true",
			},
		},
		{
			proxy: map[string]any{
				"name": "vless httpupgrade", "type": "vless", "server": "d.example", "port": 443,
				"uuid": "u", "tls": true, "network": "ws",
				"ws-opts": map[string]any{
					"path": "/up", "headers": map[string]any{"Host": "host.example"},
					"v2ray-http-upgrade": true, "v2ray-http-upgrade-fast-open": true,
				},
			},
			prefix: "vless://u@d.example:443?",
			want: map[string]string{
				"network": "ws", "ws-opts.path": "/up", "ws-opts.headers.Host": "host.example",
				"ws-opts.v2ray-http-upgrade": "true", "ws-opts.v2ray-http-upgrade-fast-open": "true",
				"ws-opts.max-early-data": "<nil>",
			},
		},
		{
			proxy: map[string]any{
				"name": "vless reality", "type": "vless", "server": "d.example", "port": 443,
				"uuid": "u-1", "flow": "xtls-rprx-vision", "tls": true, "servername": "www.example",
				"client-fingerprint": "firefox", "network": "tcp",
				"reality-opts": map[string]any{"public-key": "pk", "short-id": "ab"},
			},
			want: map[string]string{
				"name": "vless reality", "uuid": "u-1", "flow": "xtls-rprx-vision", "tls": "true",
				"servername": "www.example", "client-fingerprint": "firefox", "network": "tcp",
				"reality-opts.public-key": "pk", "reality-opts.short-id": "ab", "xudp": "<nil>",
			},
		},
		{
			proxy: map[string]any{
				"name": "vless h2", "type": "vless", "server": "d.example", "port": 443,
				"uuid": "u-2", "xudp": true, "network": "h2",
				"h2-opts": map[string]any{"path": "/h2", "host": []any{"h2.example"}},
			},
			want: map[string]string{
				"network": "h2", "h2-opts.path": "/h2", "h2-opts.host": "[h2.example]", "xudp": "true",
			},
		},
		{
			proxy: map[string]any{
				"name": "trojan", "type": "trojan", "server": "e.example", "port": 443,
				"password": "pass word", "sni": "sni.example", "skip-cert-verify": true,
				"alpn": []any{"h2", "http/1.1"}, "network": "grpc",
				"grpc-opts": map[string]any{"grpc-service-name": "g"},
			},
			want: map[string]string{
				"name": "trojan", "password": "pass word", "sni": "sni.example",
				"skip-cert-verify": "true", "alpn": "[h2 http/1.1]", "network": "grpc",
				"grpc-opts.grpc-service-name": "g",
			},
		},
		{
			proxy: map[string]any{
				"name": "trojan ws", "type": "trojan", "server": "e.example", "port": 443,
				"password": "p", "network": "ws", "ws-opts": map[string]any{"path": "/ws"},
			},
			want: map[string]string{"network": "ws", "ws-opts.path": "/ws"},
		},
		{
			proxy: map[string]any{
				"name": "trojan httpupgrade", "type": "trojan", "server": "e.example", "port": 443,
				"password": "p", "network": "ws",
				"ws-opts": map[string]any{"path": "/up", "v2ray-http-upgrade": true},
			},
			want: map[string]string{
				"network": "ws", "ws-opts.path": "/up", "ws-opts.v2ray-http-upgrade": "true",
			},
		},
		{
			proxy: map[string]any{
				"name": "hy", "type": "hysteria", "server": "f.example", "port": 443,
				"auth-str": "token", "up": "30 Mbps", "down": "200 Mbps", "sni": "hy.example",
				"protocol": "udp", "obfs": "o",
			},
			want: map[string]string{
				"auth_str": "token", "up": "30 Mbps", "down": "200 Mbps", "sni": "hy.example",
				"protocol": "udp", "obfs": "o",
			},
		},
		{
			proxy: map[string]any{
				"name": "hy2", "type": "hysteria2", "server": "g.example", "port": 443,
				"ports": "443,20000-30000", "password": "pw", "obfs": "salamander",
				"obfs-password": "op", "sni": "hy2.example", "skip-cert-verify": true,
			},
			want: map[string]string{
				"name": "hy2", "port": "443", "ports": "443,20000-30000", "password": "pw",
				"obfs": "salamander", "obfs-password": "op", "sni": "hy2.example",
				"skip-cert-verify": "true",
			},
		},
		{
			proxy: map[string]any{
				"name": "hy2 userpass", "type": "hysteria2", "server": "g.example", "port": 443,
				"password": "u1:secret",
			},
			prefix: "hysteria2://u1:secret@g.example:443",
			want:   map[string]string{"password": "u1:secret"},
		},
		{
			proxy: map[string]any{
				"name": "tuic", "type": "tuic", "server": "h.example", "port": 443,
				"uuid": "u-3", "password": "pw", "congestion-controller": "bbr",
				"udp-relay-mode": "quic", "alpn": []string{"h3"},
			},
			want: map[string]string{
				"uuid": "u-3", "password": "pw", "congestion-controller": "bbr",
				"udp-relay-mode": "quic", "alpn": "[h3]",
			},
		},
		{
			proxy: map[string]any{
				"name": "socks", "type": "socks5", "server": "i.example", "port": 1080,
				"username": "me", "password": "secret",
			},
			want: map[string]string{
				"name": "socks", "type": "socks5", "username": "me", "password": "secret",
			},
		},
		{
			proxy: map[string]any{
				"name": "https", "type": "http", "server": "j.example", "port": 443,
				"username": "test", "tls": true, "skip-cert-verify": true,
			},
			want: map[string]string{
				"type": "http", "username": "test", "password": "", "tls": "true",
				"skip-cert-verify": "true",
			},
		},
		{
			proxy: map[string]any{
				"name": "anytls", "type": "anytls", "server": "k.example", "port": 443,
				"password": "pw", "sni": "a.example", "skip-cert-verify": true,
			},
			want: map[string]string{
				"name": "anytls", "password": "pw", "sni": "a.example", "skip-cert-verify": "true",
			},
		},
		{
			proxy: map[string]any{
				"name": "mieru", "type": "mieru", "server": "l.example", "port": 2999,
				"transport": "TCP", "username": "u", "password": "p", "multiplexing": "MULTIPLEXING_LOW",
			},
			want: map[string]string{
				"name": "mieru:2999/TCP", "port": "2999", "transport": "TCP", "username": "u",
				"password": "p", "multiplexing": "MULTIPLEXING_LOW",
			},
		},
	}

	for _, tc := range cases {
		name, _ := tc.proxy["name"].(string)
		t.Run(name, func(t *testing.T) {
			links := handleEncodeShareLinks(ProxiesParams{Proxies: []map[string]any{tc.proxy}})
			if !strings.HasPrefix(links[0], tc.prefix) {
				t.Errorf("link %q does not start with %q", links[0], tc.prefix)
			}
			proxies, err := convert.ConvertsV2Ray([]byte(links[0]))
			if err != nil || len(proxies) != 1 {
				t.Fatalf("link %q read back as %v, %v", links[0], proxies, err)
			}
			for path, want := range tc.want {
				if got := fmt.Sprint(lookupField(proxies[0], path)); got != want {
					t.Errorf("%s from %q = %q, want %q", path, links[0], got, want)
				}
			}
		})
	}
}

func TestShareLinksLeaveOutWhatNoLinkCarries(t *testing.T) {
	links := handleEncodeShareLinks(ProxiesParams{Proxies: []map[string]any{
		{"name": "wg", "type": "wireguard", "server": "a.example", "port": 51820},
		{"name": "no server", "type": "ss", "cipher": "aes-128-gcm", "password": "p"},
		{"name": "ssr v6", "type": "ssr", "server": "2001:db8::1", "port": 443},
		{
			"name": "realm", "type": "hysteria2", "server": "a.example", "port": 443,
			"realm-opts": map[string]any{"enable": true},
		},
		{
			"name": "shadow-tls", "type": "ss", "server": "a.example", "port": 443,
			"cipher": "aes-128-gcm", "password": "p", "plugin": "shadow-tls",
			"plugin-opts": map[string]any{"host": "cdn.example", "password": "x"},
		},
		{
			"name": "trojan ws host", "type": "trojan", "server": "a.example", "port": 443,
			"password": "p", "network": "ws",
			"ws-opts": map[string]any{"path": "/ws", "headers": map[string]any{"Host": "cdn.example"}},
		},
		{
			"name": "trojan httpupgrade fast open", "type": "trojan", "server": "a.example",
			"port": 443, "password": "p", "network": "ws",
			"ws-opts": map[string]any{
				"path": "/up", "v2ray-http-upgrade": true, "v2ray-http-upgrade-fast-open": true,
			},
		},
	}})
	for i, link := range links {
		if link != "" {
			t.Errorf("mapping %d encoded to %q", i, link)
		}
	}
}

// The pinned Mihomo TUIC link decoder cannot carry TLS identity policies.
// A link that silently removes a cert pin or client certificate is not a
// faithful representation of the source proxy and must not be exported.
func TestVShareLinksRejectTLSModesThePinnedDecoderWouldDrop(t *testing.T) {
	cases := []struct {
		name  string
		proxy map[string]any
	}{
		{
			"vless TLS allows invalid certificates",
			map[string]any{"name": "vless", "type": "vless", "server": "node.example",
				"port": 443, "uuid": "u", "tls": true, "skip-cert-verify": true},
		},
		{
			"VMess AEAD TLS allows invalid certificates",
			map[string]any{"name": "vmess aead", "type": "vmess", "server": "node.example",
				"port": 443, "uuid": "u", "alterId": 0, "tls": true,
				"skip-cert-verify": true},
		},
		{
			"VMess legacy TLS allows invalid certificates",
			map[string]any{"name": "vmess legacy", "type": "vmess", "server": "node.example",
				"port": 443, "uuid": "u", "alterId": 64, "tls": true,
				"skip-cert-verify": true},
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := encodeShareLink(proxyFields(tc.proxy)); got != "" {
				t.Fatalf("export lost the source TLS trust policy: %q", got)
			}
			tc.proxy["skip-cert-verify"] = false
			if got := encodeShareLink(proxyFields(tc.proxy)); got == "" {
				t.Fatal("normal TLS proxy should still export")
			}
		})
	}
}

func TestVShareLinksDoNotLoseCertificatesOrPins(t *testing.T) {
	templates := []struct {
		name, typ string
		alterID   int
	}{
		{"VLESS", "vless", 0},
		{"VMess Xray AEAD", "vmess", 0},
		{"VMess legacy v2rayN", "vmess", 64},
	}
	for _, item := range templates {
		t.Run(item.name, func(t *testing.T) {
			base := map[string]any{
				"name": item.name, "type": item.typ, "server": "node.example",
				"port": 443, "uuid": "u", "alterId": item.alterID, "tls": true,
			}
			if link := encodeShareLink(proxyFields(base)); link == "" {
				t.Fatal("normal TLS proxy must remain exportable")
			}
			for _, unsupported := range []struct {
				key, value string
			}{
				{"name-cert-verify", "cert.example"},
				{"certificate", "-----BEGIN CERTIFICATE-----"},
				{"private-key", "-----BEGIN PRIVATE KEY-----"},
			} {
				attrs := make(map[string]any, len(base)+1)
				for k, v := range base {
					attrs[k] = v
				}
				attrs[unsupported.key] = unsupported.value
				if link := encodeShareLink(proxyFields(attrs)); link != "" {
					t.Errorf("%s lost %s on export: %q", item.name, unsupported.key, link)
				}
			}
			pinned := make(map[string]any, len(base)+1)
			for k, v := range base {
				pinned[k] = v
			}
			pinned["fingerprint"] = "sha256/pinned-cert-value"
			link := encodeShareLink(proxyFields(pinned))
			if item.alterID > 0 {
				if link != "" {
					t.Errorf("legacy VMess JSON silently lost pinned cert: %q", link)
				}
				return
			}
			if link == "" {
				t.Fatal("Xray-style link can represent pcs=fingerprint")
			}
			decoded := handleDecodeShareLinks(LinesParams{Lines: []string{link}})
			if len(decoded) != 1 || len(decoded[0]) != 1 ||
				decoded[0][0]["fingerprint"] != "sha256/pinned-cert-value" {
				t.Errorf("certificate pin failed round-trip: %+v", decoded)
			}
		})
	}
}

func TestTuicShareLinksFailClosedForUnrepresentableTLSOptions(t *testing.T) {
	base := map[string]any{
		"name": "secure tuic", "type": "tuic", "server": "node.example",
		"port": 443, "uuid": "user", "password": "pass", "alpn": []string{"h3"},
	}
	if got := encodeShareLink(proxyFields(base)); got == "" {
		t.Fatal("ordinary TUIC link should remain exportable")
	}
	cases := []struct {
		name  string
		key   string
		value any
	}{
		{"skip certificate verification", "skip-cert-verify", true},
		{"pinned certificate fingerprint", "fingerprint", "sha256/pinned-hash"},
		{"custom certificate name", "name-cert-verify", "vpn.example"},
		{"mutual TLS certificate", "certificate", "-----BEGIN CERTIFICATE-----"},
		{"mutual TLS private key", "private-key", "-----BEGIN PRIVATE KEY-----"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			attrs := make(map[string]any, len(base)+1)
			for key, value := range base {
				attrs[key] = value
			}
			attrs[tc.key] = tc.value
			if got := encodeShareLink(proxyFields(attrs)); got != "" {
				t.Fatalf("TUIC %s was exported without its TLS policy: %s", tc.key, got)
			}
		})
	}
}

func TestDecodeShareLinksAnswersEveryLine(t *testing.T) {
	results := handleDecodeShareLinks(LinesParams{Lines: []string{
		"trojan://pw@a.example:443#one",
		"not a link",
		"socks5://b.example:1080#two",
	}})
	if len(results) != 3 || len(results[0]) != 1 || len(results[1]) != 0 || len(results[2]) != 1 {
		t.Fatalf("results = %v", results)
	}
	if results[0][0]["name"] != "one" || results[2][0]["name"] != "two" {
		t.Errorf("names = %v, %v", results[0][0]["name"], results[2][0]["name"])
	}
}

func TestShareLinksRejectAdditionalUnencodedTLSIdentity(t *testing.T) {
	for _, kind := range []string{"trojan", "hysteria", "hysteria2", "anytls", "http"} {
		for _, key := range []string{"name-cert-verify", "certificate", "private-key"} {
			t.Run(kind+"/"+key, func(t *testing.T) {
				fields := proxyFields{
					"name": kind, "type": kind, "server": "node.example", "port": 443,
					"password": "test-password", "auth-str": "test-auth", "tls": true,
					"skip-cert-verify": true,
				}
				if encodeShareLink(fields) == "" {
					t.Fatal("the plain supported TLS form should remain exportable")
				}
				fields[key] = "test-identity"
				if encodeShareLink(fields) != "" {
					t.Fatal("export would drop the TLS identity policy")
				}
			})
		}
	}
}

func TestShareLinksRejectTLSModesTheDecoderChanges(t *testing.T) {
	for _, fields := range []proxyFields{
		{"type": "socks5", "tls": true},
		{"type": "http", "tls": true},
		{"type": "http", "tls": true, "skip-cert-verify": false},
		{"type": "http", "tls": true, "skip-cert-verify": true, "sni": "tls.example"},
		{"type": "http", "tls": true, "skip-cert-verify": true, "fingerprint": "test-pin"},
		{"type": "hysteria", "fingerprint": "test-pin"},
	} {
		fields["name"], fields["server"], fields["port"] = "test", "node.example", 443
		fields["username"], fields["password"] = "test-user", "test-password"
		if link := encodeShareLink(fields); link != "" {
			decoded := handleDecodeShareLinks(LinesParams{Lines: []string{link}})
			t.Errorf("TLS policy lost: source=%v decoded=%v", fields, decoded)
		}
	}
}

func TestShareLinksKeepSupportedCertificatePolicies(t *testing.T) {
	for _, kind := range []string{"trojan", "hysteria2", "anytls"} {
		t.Run(kind, func(t *testing.T) {
			fields := proxyFields{
				"name": kind, "type": kind, "server": "node.example", "port": 443,
				"password": "test-password", "sni": "tls.example",
				"fingerprint": "test-pin", "skip-cert-verify": true,
			}
			link := encodeShareLink(fields)
			decoded := handleDecodeShareLinks(LinesParams{Lines: []string{link}})
			if len(decoded) != 1 || len(decoded[0]) != 1 {
				t.Fatalf("supported TLS policy no longer round trips: %v", decoded)
			}
			for _, key := range []string{"sni", "fingerprint", "skip-cert-verify"} {
				if decoded[0][0][key] != fields[key] {
					t.Errorf("%s changed: got %v, want %v", key, decoded[0][0][key], fields[key])
				}
			}
		})
	}
}
