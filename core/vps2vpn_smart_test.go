package core

import (
	"slices"
	"testing"

	"github.com/metacubex/mihomo/config"
)

func vpsOn(t *testing.T) {
	vpsSmartEnabled.Store(true)
	t.Cleanup(func() { vpsSmartEnabled.Store(false) })
}

// vpsParse validates raw the way the Core does. Parsing rewrites resolver
// settings, so it waits for lookups left by earlier tests first.
func vpsParse(t *testing.T, raw *config.RawConfig) (*config.Config, error) {
	t.Helper()
	waitResolverIdle(t)
	return config.ParseRawConfig(raw)
}

func vpsTestRaw(rules ...string) *config.RawConfig {
	raw := config.DefaultRawConfig()
	raw.Proxy = []map[string]any{
		{"name": "SG-REALITY", "type": "vless", "server": "1.2.3.4", "port": 443, "uuid": "11111111-2222-3333-4444-555555555555",
			"tls": true, "servername": "www.example.com", "reality-opts": map[string]any{"public-key": "Z84J2IelR9ch3k8VtlVhhs5ycBUlXA7wHBWcBrjqnAw"}},
		{"name": "US-HY2", "type": "hysteria2", "server": "5.6.7.8", "port": 443, "password": "p"},
		{"name": "SG-HY2", "type": "hysteria2", "server": "1.2.3.4", "port": 443, "password": "p"},
	}
	raw.ProxyGroup = []map[string]any{
		{"name": "Proxy", "type": "select", "proxies": []any{"SG-REALITY", "US-HY2", "SG-HY2"}},
	}
	raw.Rule = rules
	return raw
}

func vpsGroup(raw *config.RawConfig, name string) map[string]any {
	for _, g := range raw.ProxyGroup {
		if g["name"] == name {
			return g
		}
	}
	return nil
}

func TestVps2vpnEnhanceAddsSmartAndAI(t *testing.T) {
	vpsOn(t)
	raw := vpsTestRaw("MATCH,Proxy")
	vps2vpnEnhance(raw, 0)

	smart := vpsGroup(raw, vpsSmartGroup)
	if smart == nil {
		t.Fatal("no smart group")
	}
	// One member per server, the fastest wins: SG's protocols back each
	// other up in one hidden group (fast first), so switching protocol never
	// changes the exit IP. The US server has one line, listed as it is.
	if got := smart["proxies"].([]string); !slices.Equal(got, []string{"SG", "US-HY2"}) {
		t.Fatalf("smart members %v", got)
	}
	if got := vpsGroup(raw, "SG")["proxies"].([]string); !slices.Equal(got, []string{"SG-HY2", "SG-REALITY"}) {
		t.Fatalf("SG lines %v", got)
	}
	if first := vpsGroup(raw, "Proxy")["proxies"].([]any)[0]; first != vpsSmartGroup {
		t.Fatalf("selector first = %v", first)
	}
	ai := vpsGroup(raw, vpsAIGroup)["proxies"].([]string)
	// Same order for AI: one exit IP unless the whole primary server is down.
	if ai[0] != "SG-HY2" || ai[1] != "SG-REALITY" || ai[2] != "US-HY2" {
		t.Fatalf("ai order %v", ai)
	}
	if raw.Rule[0] != "DOMAIN-SUFFIX,anthropic.com,"+vpsAIGroup || raw.Rule[len(raw.Rule)-1] != "MATCH,Proxy" {
		t.Fatalf("rules %v", raw.Rule)
	}
	if fp := raw.Proxy[0]["client-fingerprint"]; fp != "chrome" {
		t.Fatalf("fingerprint %v", fp)
	}
	if _, err := vpsParse(t, raw); err != nil {
		t.Fatalf("parse: %v", err)
	}
}

func TestVps2vpnEnhanceKeepsCuratedAIRules(t *testing.T) {
	vpsOn(t)
	raw := vpsTestRaw("DOMAIN-SUFFIX,openai.com,Proxy", "MATCH,Proxy")
	vps2vpnEnhance(raw, 0)
	if vpsGroup(raw, vpsAIGroup) != nil {
		t.Fatal("AI group added over curated rules")
	}
	if raw.Rule[0] != "DOMAIN-SUFFIX,openai.com,Proxy" {
		t.Fatalf("rules changed: %v", raw.Rule)
	}
	if vpsGroup(raw, vpsSmartGroup) == nil {
		t.Fatal("smart group missing")
	}
}

func TestVps2vpnEnhancePreservesDeepWildcardAIRules(t *testing.T) {
	vpsOn(t)
	cases := []struct {
		pattern string
		sample  string
	}{
		{"*.*.claude.ai", "a.b.claude.ai"},
		{"api.*.openai.com", "api.sub.openai.com"},
		{"*.*.gemini.google.com", "x.y.gemini.google.com"},
	}
	for _, tt := range cases {
		t.Run(tt.pattern, func(t *testing.T) {
			if !vpsWildcardMatches(tt.pattern, tt.sample) {
				t.Fatalf("%q should match %q", tt.pattern, tt.sample)
			}
			if !vpsWildcardMatchesAI(tt.pattern) {
				t.Fatalf("%q was not detected as covering an AI subdomain", tt.pattern)
			}
			rule := "DOMAIN-WILDCARD," + tt.pattern + ",Proxy"
			raw := vpsTestRaw(rule, "MATCH,Proxy")
			vps2vpnEnhance(raw, 0)
			if vpsGroup(raw, vpsAIGroup) != nil {
				t.Fatal("injected AI group would override existing wildcard rule")
			}
			if raw.Rule[0] != rule {
				t.Fatalf("curated rule was displaced: %v", raw.Rule[:2])
			}
		})
	}
	if vpsWildcardMatchesAI("*.*.example.org") {
		t.Fatal("unrelated wildcard must not be treated as an AI domain rule")
	}
	inline := map[string]any{"behavior": "domain", "payload": []any{"*.*.claude.ai"}}
	if !vpsInlineProviderRoutesAI(inline) {
		t.Fatal("inline domain rule provider with deep wildcard was missed")
	}
}

func TestVps2vpnEnhanceSingleLineUntouched(t *testing.T) {
	vpsOn(t)
	raw := config.DefaultRawConfig()
	raw.Proxy = []map[string]any{{"name": "only", "type": "hysteria2", "server": "1.1.1.1"}}
	vps2vpnEnhance(raw, 0)
	if len(raw.ProxyGroup) != 0 || len(raw.Rule) != 0 {
		t.Fatal("single line config changed")
	}
}

func TestVps2vpnEnhanceIdempotent(t *testing.T) {
	vpsOn(t)
	raw := vpsTestRaw("MATCH,Proxy")
	vps2vpnEnhance(raw, 0)
	n, r := len(raw.ProxyGroup), len(raw.Rule)
	vps2vpnEnhance(raw, 0)
	if len(raw.ProxyGroup) != n || len(raw.Rule) != r {
		t.Fatal("second pass changed config")
	}
}

func TestVps2vpnEnhanceKeepsUserRulesFirst(t *testing.T) {
	vpsOn(t)
	raw := vpsTestRaw("DOMAIN,mine.test,DIRECT", "MATCH,Proxy")
	vps2vpnEnhance(raw, 1)
	if raw.Rule[0] != "DOMAIN,mine.test,DIRECT" || raw.Rule[1] != "DOMAIN-SUFFIX,anthropic.com,"+vpsAIGroup {
		t.Fatalf("rules %v", raw.Rule[:2])
	}
}

func TestVps2vpnEnhanceOffByDefault(t *testing.T) {
	raw := vpsTestRaw("MATCH,Proxy")
	vps2vpnEnhance(raw, 0)
	if len(raw.ProxyGroup) != 1 {
		t.Fatal("changed while switched off")
	}
}

// A "domestic" group listed first (DIRECT, then the proxy) is no main
// selector: offering the smart line first there would send that traffic out.
func TestVps2vpnEnhanceSkipsADirectFirstSelectGroup(t *testing.T) {
	vpsOn(t)
	raw := vpsTestRaw("GEOIP,CN,Domestic", "MATCH,Proxy")
	raw.ProxyGroup = append([]map[string]any{
		{"name": "Domestic", "type": "select", "proxies": []any{"DIRECT", "Proxy"}},
	}, raw.ProxyGroup...)
	vps2vpnEnhance(raw, 0)

	domestic := vpsGroup(raw, "Domestic")["proxies"].([]any)
	if len(domestic) != 2 || domestic[0] != "DIRECT" {
		t.Fatalf("domestic group = %v, want it untouched", domestic)
	}
	proxy := vpsGroup(raw, "Proxy")["proxies"].([]any)
	if len(proxy) == 0 || proxy[0] != vpsSmartGroup {
		t.Fatalf("main selector = %v, want the smart line first", proxy)
	}
}

func TestVps2vpnEnhanceFollowsTheSubscriptionsTCPFirst(t *testing.T) {
	for _, tc := range []struct {
		name     string
		fallback []any
		want     []string
	}{
		{"tcp_first on", []any{"SG-REALITY", "SG-HY2", "US-HY2"}, []string{"SG-REALITY", "SG-HY2", "US-HY2"}},
		{"tcp_first off", []any{"SG-HY2", "SG-REALITY", "US-HY2"}, []string{"SG-HY2", "SG-REALITY", "US-HY2"}},
		{"no fallback group", nil, []string{"SG-HY2", "SG-REALITY", "US-HY2"}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			vpsOn(t)
			raw := vpsTestRaw("MATCH,Proxy")
			if tc.fallback != nil {
				raw.ProxyGroup = append(raw.ProxyGroup, map[string]any{
					"name": "auto", "type": "fallback", "proxies": tc.fallback,
				})
			}
			vps2vpnEnhance(raw, 0)
			if got := vpsGroup(raw, vpsAIGroup)["proxies"].([]string); !slices.Equal(got, tc.want) {
				t.Fatalf("AI = %v, want %v", got, tc.want)
			}
			if got := vpsGroup(raw, "SG")["proxies"].([]string); !slices.Equal(got, tc.want[:2]) {
				t.Fatalf("SG = %v, want %v", got, tc.want[:2])
			}
			// Only the Reality line gets a fingerprint, whichever order won.
			if fp := raw.Proxy[0]["client-fingerprint"]; fp != "chrome" {
				t.Fatalf("Reality fingerprint = %v, want chrome", fp)
			}
			for _, p := range raw.Proxy[1:] {
				if _, has := p["client-fingerprint"]; has {
					t.Fatalf("%v got a fingerprint", p["name"])
				}
			}
		})
	}
}

func TestVpsLineStem(t *testing.T) {
	for name, want := range map[string]string{
		"🇺🇸 美国1 · 1.0x · Reality":      "🇺🇸 美国1 · 1.0x",
		"🇺🇸 美国1 · 1.0x · TUIC-v5-IPv6": "🇺🇸 美国1 · 1.0x",
		"🇺🇸 美国1 · 1.0x · HY2-IPv6":     "🇺🇸 美国1 · 1.0x",
		"SG | Hysteria2":               "SG",
		"Tokyo - VLESS - IPv6":         "Tokyo",
		"US-HY2":                       "US-HY2",
		"🇸🇬 新加坡 · 2.0x":                "🇸🇬 新加坡 · 2.0x",
	} {
		if got := vpsLineStem(name); got != want {
			t.Errorf("stem(%q) = %q, want %q", name, got, want)
		}
	}
}

func vpsReality(name, server string) map[string]any {
	return map[string]any{"name": name, "type": "vless", "server": server, "port": 443,
		"uuid": "11111111-2222-3333-4444-555555555555", "tls": true, "servername": "www.example.com",
		"reality-opts": map[string]any{"public-key": "Z84J2IelR9ch3k8VtlVhhs5ycBUlXA7wHBWcBrjqnAw"}}
}

func vpsHy2(name, server string) map[string]any {
	return map[string]any{"name": name, "type": "hysteria2", "server": server, "port": 443, "password": "p"}
}

// Two servers: the smart line picks the faster server, with a tolerance so
// it stays put on small changes, and each server's protocols (its IPv6 lines
// too) back each other up inside one hidden group, so the exit IP only
// changes when the whole server goes down or another is clearly faster.
func TestVps2vpnSmartPicksTheFastestServer(t *testing.T) {
	vpsOn(t)
	raw := config.DefaultRawConfig()
	raw.Proxy = []map[string]any{
		vpsReality("US · Reality", "192.0.2.1"),
		vpsHy2("US · Hysteria2", "192.0.2.1"),
		vpsHy2("US · HY2-IPv6", "2001:db8::1"),
		vpsReality("SG · Reality", "192.0.2.2"),
		vpsHy2("SG · Hysteria2", "192.0.2.2"),
	}
	raw.ProxyGroup = []map[string]any{
		{"name": "Proxy", "type": "select", "proxies": []any{"US · Reality", "SG · Reality"}},
	}
	raw.Rule = []string{"MATCH,Proxy"}
	vps2vpnEnhance(raw, 0)

	smart := vpsGroup(raw, vpsSmartGroup)
	if smart["type"] != "url-test" || smart["tolerance"] != vpsSmartTolerance {
		t.Fatalf("smart = %v, want a url-test with a tolerance", smart)
	}
	if got := smart["proxies"].([]string); !slices.Equal(got, []string{"US", "SG"}) {
		t.Fatalf("smart members = %v, want one per server", got)
	}
	us := vpsGroup(raw, "US")
	if us["type"] != "fallback" || us["hidden"] != true {
		t.Fatalf("US group = %v, want a hidden fallback", us)
	}
	if got := us["proxies"].([]string); !slices.Equal(got, []string{"US · Hysteria2", "US · HY2-IPv6", "US · Reality"}) {
		t.Fatalf("US lines = %v", got)
	}
	// AI keeps one fixed order of lines, the first server's first.
	if got := vpsGroup(raw, vpsAIGroup)["proxies"].([]string); got[0] != "US · Hysteria2" || len(got) != 5 {
		t.Fatalf("ai = %v", got)
	}
	if _, err := vpsParse(t, raw); err != nil {
		t.Fatalf("parse: %v", err)
	}
}

// A subscription that already has a fallback group per server lends it to
// the smart line instead of a copy, and a name it uses is never taken over.
func TestVps2vpnSmartReusesTheSubscriptionsServerGroups(t *testing.T) {
	vpsOn(t)
	raw := config.DefaultRawConfig()
	raw.Proxy = []map[string]any{
		vpsReality("US · Reality", "192.0.2.1"),
		vpsHy2("US · Hysteria2", "192.0.2.1"),
		vpsReality("SG · Reality", "192.0.2.2"),
		vpsHy2("SG · Hysteria2", "192.0.2.2"),
	}
	raw.ProxyGroup = []map[string]any{
		{"name": "Proxy", "type": "select", "proxies": []any{"US server", "SG"}},
		{"name": "US server", "type": "fallback", "proxies": []any{"US · Reality", "US · Hysteria2"}},
		{"name": "SG", "type": "select", "proxies": []any{"SG · Reality", "SG · Hysteria2"}},
	}
	raw.Rule = []string{"MATCH,Proxy"}
	vps2vpnEnhance(raw, 0)

	got := vpsGroup(raw, vpsSmartGroup)["proxies"].([]string)
	if !slices.Equal(got, []string{"US server", "⚡ SG"}) {
		t.Fatalf("smart members = %v", got)
	}
	if vpsGroup(raw, "SG")["type"] != "select" {
		t.Fatal("the subscription's own SG group was replaced")
	}
	if _, err := vpsParse(t, raw); err != nil {
		t.Fatalf("parse: %v", err)
	}
}
