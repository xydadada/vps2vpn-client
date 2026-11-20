package core

import (
	"reflect"
	"testing"

	"github.com/metacubex/mihomo/config"
)

func vpsOn(t *testing.T) {
	vpsSmartEnabled.Store(true)
	t.Cleanup(func() { vpsSmartEnabled.Store(false) })
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
	if _, err := config.ParseRawConfig(raw); err != nil {
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

func TestVps2vpnEnhancePreservesConflictingProxyNames(t *testing.T) {
	vpsOn(t)
	for _, name := range []string{vpsSmartGroup, vpsAIGroup} {
		t.Run(name, func(t *testing.T) {
			raw := vpsTestRaw("MATCH,Proxy")
			raw.Proxy[0]["name"] = name
			raw.ProxyGroup[0]["proxies"] = []any{name, "US-HY2", "SG-HY2"}
			vps2vpnEnhance(raw, 0)
			if vpsGroup(raw, name) != nil {
				t.Fatalf("group replaced existing proxy %q", name)
			}
			if _, err := config.ParseRawConfig(raw); err != nil {
				t.Fatalf("valid subscription rejected after enhancement: %v", err)
			}
		})
	}
}

func TestVps2vpnEnhanceKeepsTypedSelectorMembers(t *testing.T) {
	vpsOn(t)
	raw := vpsTestRaw("MATCH,Proxy")
	raw.ProxyGroup[0]["proxies"] = []string{"SG-REALITY", "US-HY2", "SG-HY2"}
	vps2vpnEnhance(raw, 0)
	want := []any{vpsSmartGroup, "SG-REALITY", "US-HY2", "SG-HY2"}
	if got := raw.ProxyGroup[0]["proxies"]; !reflect.DeepEqual(got, want) {
		t.Fatalf("selector members = %#v, want %#v", got, want)
	}
}
