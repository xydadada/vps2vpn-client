package core

import (
	"context"
	"encoding/json"
	"path/filepath"
	"reflect"
	"strings"
	"sync"
	"testing"

	"github.com/metacubex/mihomo/adapter/outboundgroup"
	"github.com/metacubex/mihomo/adapter/provider"
	"github.com/metacubex/mihomo/config"
	C "github.com/metacubex/mihomo/constant"
	P "github.com/metacubex/mihomo/constant/provider"
)

type localProbeAdapter struct {
	C.ProxyAdapter
	endpoint string
}

func (a *localProbeAdapter) DialContext(ctx context.Context, _ *C.Metadata) (C.Conn, error) {
	metadata, err := probeMetadata(a.endpoint)
	if err != nil {
		return nil, err
	}
	return a.ProxyAdapter.DialContext(ctx, metadata)
}

func newLocalFallback(t *testing.T, name, url string, opt outboundgroup.FallbackOption, proxies []C.Proxy) *outboundgroup.Fallback {
	t.Helper()
	hc := provider.NewHealthCheck(proxies, "", 0, 0, true, nil)
	pd, err := provider.NewCompatibleProvider(name, proxies, hc)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = pd.Close() })
	group, err := outboundgroup.NewFallback(outboundgroup.GroupCommonOption{Name: name, URL: url}, opt, namedProxy("empty"), []P.ProxyProvider{pd})
	if err != nil {
		t.Fatal(err)
	}
	return group
}

func TestSmartAIConfigurationOptsIntoIndependentHealth(t *testing.T) {
	vpsOn(t)
	raw := vpsTestRaw("MATCH,Proxy")
	vps2vpnEnhance(raw, 0)
	ai := vpsGroup(raw, vpsAIGroup)
	if ai["url"] == vpsGroup(raw, vpsSmartGroup)["url"] || ai["failure-threshold"] != 3 || ai["recovery-threshold"] != 3 {
		t.Fatalf("AI health configuration = %v", ai)
	}
	if _, err := config.ParseRawConfig(raw); err != nil {
		t.Fatal(err)
	}
}

func TestSmartBackupServerProtocolsStayTogether(t *testing.T) {
	vpsOn(t)
	raw := config.DefaultRawConfig()
	raw.Proxy = []map[string]any{
		{"name": "A-reality", "type": "vless", "server": "a.invalid", "reality-opts": map[string]any{}},
		{"name": "B-reality", "type": "vless", "server": "b.invalid", "reality-opts": map[string]any{}},
		{"name": "B-fast", "type": "hysteria2", "server": "b.invalid"},
		{"name": "C-fast", "type": "hysteria2", "server": "c.invalid"},
	}
	vps2vpnEnhance(raw, 0)
	want := []string{"A-reality", "B-fast", "B-reality", "C-fast"}
	if got := vpsGroup(raw, vpsSmartGroup)["proxies"]; !reflect.DeepEqual(got, want) {
		t.Fatalf("server order = %v, want %v", got, want)
	}
}

func TestSmartReservedNamesLeaveValidNodesAndProvidersUsable(t *testing.T) {
	for _, reserved := range []string{vpsSmartGroup, vpsAIGroup} {
		for _, kind := range []string{"node", "provider"} {
			t.Run(reserved+"/"+kind, func(t *testing.T) {
				vpsOn(t)
				raw := vpsTestRaw("MATCH,Proxy")
				if kind == "node" {
					raw.Proxy[0]["name"] = reserved
					raw.ProxyGroup[0]["proxies"] = []any{reserved, "US-HY2", "SG-HY2"}
				} else {
					raw.ProxyProvider = map[string]map[string]any{reserved: {"type": "inline", "payload": []any{map[string]any{"name": "local", "type": "socks5", "server": "127.0.0.1", "port": 1080}}}}
				}
				if _, err := config.ParseRawConfig(raw); err != nil {
					t.Fatalf("input must be valid: %v", err)
				}
				vps2vpnEnhance(raw, 0)
				if vpsGroup(raw, reserved) != nil {
					t.Fatalf("generated conflicting group %s", reserved)
				}
				if _, err := config.ParseRawConfig(raw); err != nil {
					t.Fatalf("enhancement rejected valid input: %v", err)
				}
			})
		}
	}
}

func TestSmartAIRuleDetectionUsesPayloadAndPreservesOpaqueRules(t *testing.T) {
	for _, test := range []struct {
		rule    string
		curated bool
	}{
		{"DOMAIN-SUFFIX,example.org,Claude Backup", false},
		{"DOMAIN,openai.com.example.org,Proxy", false},
		{"DOMAIN-SUFFIX,chatgpt.com,Proxy", true},
		{"DOMAIN,api.openai.com,Proxy", true},
		{"DOMAIN-KEYWORD,openai,Proxy", true},
		{"RULE-SET,ai,Proxy", true},
		{"SUB-RULE,(NETWORK,TCP),custom", true},
	} {
		t.Run(test.rule, func(t *testing.T) {
			if got := vpsRoutesAI([]string{test.rule}); got != test.curated {
				t.Fatalf("curated=%v, want %v", got, test.curated)
			}
		})
	}
	vpsOn(t)
	raw := vpsTestRaw("RULE-SET,ai,Proxy", "MATCH,Proxy")
	raw.RuleProvider = map[string]map[string]any{"ai": {"type": "inline", "behavior": "classical", "payload": []any{"DOMAIN-SUFFIX,chatgpt.com"}}}
	vps2vpnEnhance(raw, 0)
	if raw.Rule[0] != "RULE-SET,ai,Proxy" || vpsGroup(raw, vpsAIGroup) != nil {
		t.Fatalf("curated rules were overridden: %v", raw.Rule)
	}
}

func TestSmartSavedConfigurationRetainsGroupsRulesAndFingerprint(t *testing.T) {
	vpsOn(t)
	path := writeBaseProfile(t, baseProfile)
	base, err := handleGetProfileBase(PathParams{Path: path})
	if err != nil {
		t.Fatal(err)
	}
	configPath := filepath.Join(t.TempDir(), "config.yaml")
	initial, err := loadConfigWithBase(&SetupBase{Path: path, Overlay: overlayOf(t, base, []string{"DOMAIN,user.invalid,DIRECT"}, nil)}, configPath)
	if err != nil {
		t.Fatal(err)
	}
	reloaded, err := loadConfig(configPath)
	if err != nil {
		t.Fatal(err)
	}
	if initial.Proxies[vpsAIGroup] == nil || reloaded.Proxies[vpsAIGroup] == nil || !reflect.DeepEqual(ruleStrings(initial), ruleStrings(reloaded)) {
		t.Fatalf("AI policy changed after reload: %v -> %v", ruleStrings(initial), ruleStrings(reloaded))
	}
	raw, err := readRawConfig(configPath)
	if err != nil {
		t.Fatal(err)
	}
	if raw.Proxy[1]["client-fingerprint"] != "chrome" {
		t.Fatalf("fingerprint not persisted: %v", raw.Proxy[1])
	}
	if raw.Rule[0] != "DOMAIN,user.invalid,DIRECT" {
		t.Fatal("user rule lost priority")
	}
}

func TestSmartFallbackSelectionAndObservationAreConcurrentSafe(t *testing.T) {
	members := []C.Proxy{namedProxy("a"), namedProxy("b")}
	fallback := newLocalFallback(t, "concurrent", "http://local-probe.invalid/", outboundgroup.FallbackOption{}, members)
	var wg sync.WaitGroup
	wg.Add(3)
	go func() {
		defer wg.Done()
		for i := 0; i < 1000; i++ {
			if err := fallback.Set(members[i%2].Name()); err != nil {
				t.Error(err)
			}
		}
	}()
	go func() {
		defer wg.Done()
		for i := 0; i < 1000; i++ {
			_ = fallback.Now()
		}
	}()
	go func() {
		defer wg.Done()
		for i := 0; i < 1000; i++ {
			if _, err := json.Marshal(fallback); err != nil {
				t.Error(err)
			}
		}
	}()
	wg.Wait()
	fallback.ForceSet("b")
	if fallback.Now() != "b" {
		t.Fatal("final selection did not take effect")
	}
}

func TestProfileMergeRejectsRecursiveAliases(t *testing.T) {
	for _, test := range []struct{ profile, overlay string }{
		{"&self {<<: *self}", "{}"},
		{"{}", "&self {<<: *self}"},
		{"x: &self [*self]", "{}"},
	} {
		path := writeBaseProfile(t, test.profile)
		if _, err := mergeProfileBase(&SetupBase{Path: path, Overlay: test.overlay}); err == nil || !strings.Contains(err.Error(), "cyclic YAML alias") {
			t.Fatalf("recursive alias was not rejected: %v", err)
		}
	}
}

func TestProfileMergeKeepsShortIDsInExternalAnchors(t *testing.T) {
	for _, profile := range []string{
		"x-reality: &reality {public-key: placeholder, short-id: 0123}\nproxies:\n  - {name: a, type: vless, reality-opts: *reality}\n",
		"x-id: &id 0123\nproxies:\n  - {name: a, type: vless, reality-opts: {short-id: *id}}\n",
	} {
		path := writeBaseProfile(t, profile)
		document, err := mergeProfileBase(&SetupBase{Path: path, Overlay: "{}"})
		if err != nil {
			t.Fatal(err)
		}
		raw := config.DefaultRawConfig()
		if err := document.Decode(raw); err != nil {
			t.Fatal(err)
		}
		if got := raw.Proxy[0]["reality-opts"].(map[string]any)["short-id"]; got != "0123" {
			t.Fatalf("short-id changed while copying an alias: %#v", got)
		}
	}
}
