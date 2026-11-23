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
	got := smart["proxies"].([]string)
	// The primary server (the subscription's first line, SG) keeps every
	// protocol ahead of any other server, fast first: switching protocol
	// never changes the exit IP. The US server is the last resort.
	want := []string{"SG-HY2", "SG-REALITY", "US-HY2"}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("smart order %v, want %v", got, want)
		}
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
			for _, group := range []string{vpsSmartGroup, vpsAIGroup} {
				got := vpsGroup(raw, group)["proxies"].([]string)
				if !slices.Equal(got, tc.want) {
					t.Fatalf("%s = %v, want %v", group, got, tc.want)
				}
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
