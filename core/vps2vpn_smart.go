package core

import (
	"fmt"
	"net/netip"
	"sort"
	"strings"
	"sync/atomic"

	"github.com/metacubex/mihomo/config"
)

const (
	vpsSmartGroup = "⚡ 智能线路"
	vpsAIGroup    = "🤖 AI 专线"
	vpsProbeURL   = "https://www.gstatic.com/generate_204"
	vpsAIProbeURL = vpsProbeURL + "#vps2vpn-ai"
)

// Set from CoreOptions.SmartLines before each config load.
var vpsSmartEnabled atomic.Bool

var vpsAIDomains = []string{
	"anthropic.com", "claude.ai", "claude.com", "claudeusercontent.com", "clau.de",
	"openai.com", "chatgpt.com", "oaistatic.com", "oaiusercontent.com", "sora.com",
	"gemini.google.com", "notebooklm.google.com", "generativelanguage.googleapis.com", "aistudio.google.com",
	"perplexity.ai", "x.ai", "grok.com",
}

var vpsNonAISets = map[string]bool{
	"cn":                      true,
	"private":                 true,
	"lan":                     true,
	"direct":                  true,
	"reject":                  true,
	"apple":                   true,
	"apple-cn":                true,
	"microsoft":               true,
	"microsoft-cn":            true,
	"steam-cn":                true,
	"cn-download":             true,
	"cn-ip":                   true,
	"private-ip":              true,
	"telegram":                true,
	"telegram-ip":             true,
	"ads":                     true,
	"category-ads-all":        true,
	"category-public-tracker": true,
	"category-pt":             true,
	"cncidr":                  true,
	"lancidr":                 true,
	"gfw":                     true,
	"tld-not-cn":              true,
	"geolocation-!cn":         true,
	"proxy":                   true,
	"google-cn":               true,
}

type vpsEnhanceResult struct {
	fingerprinted []int
	selectIndex   int
	addedGroups   int
	addedRules    int
}

// vpsLineRank: lower is tried first; -1 means not a line to the outside.
func vpsLineRank(p map[string]any) int {
	rawType, ok := p["type"].(string)
	if !ok {
		return -1
	}
	t := strings.ToLower(strings.TrimSpace(rawType))
	if t == "" {
		return -1
	}
	switch t {
	case "hysteria2", "hysteria", "tuic":
		return 0
	case "vless":
		if opts, ok := p["reality-opts"].(map[string]any); ok && opts != nil {
			return 1
		}
		return 2
	case "trojan", "anytls", "vmess", "wireguard":
		return 2
	case "ss", "ssr", "snell", "socks5", "http", "ssh":
		return 3
	case "direct", "reject", "reject-drop", "pass", "dns", "compatible":
		return -1
	}
	return 3
}

func vpsName(p map[string]any) string {
	name, _ := p["name"].(string)
	return name
}

func vpsProxyServer(p map[string]any) string {
	server, _ := p["server"].(string)
	server = strings.TrimSpace(server)
	if server == "" {
		switch peers := p["peers"].(type) {
		case []any:
			if len(peers) > 0 {
				if peer, ok := peers[0].(map[string]any); ok {
					server, _ = peer["server"].(string)
					server = strings.TrimSpace(server)
				}
			}
		case []map[string]any:
			if len(peers) > 0 {
				server, _ = peers[0]["server"].(string)
				server = strings.TrimSpace(server)
			}
		}
	}
	server = strings.ToLower(strings.TrimSpace(server))
	if strings.HasPrefix(server, "[") && strings.HasSuffix(server, "]") {
		server = strings.TrimSpace(server[1 : len(server)-1])
	}
	if server == "" {
		return ""
	}
	if addr, err := netip.ParseAddr(server); err == nil {
		return addr.Unmap().String()
	}
	return strings.TrimRight(server, ".")
}

func vpsNameTaken(raw *config.RawConfig, name string) bool {
	if _, exists := raw.ProxyProvider[name]; exists {
		return true
	}
	for _, p := range raw.Proxy {
		if vpsName(p) == name {
			return true
		}
	}
	for _, g := range raw.ProxyGroup {
		if vpsName(g) == name {
			return true
		}
	}
	return false
}

func vpsDomainMatchesAI(payload string, isSuffix bool) bool {
	payload = strings.TrimSuffix(strings.ToLower(strings.TrimSpace(payload)), ".")
	if payload == "" {
		return false
	}
	for _, domain := range vpsAIDomains {
		if payload == domain || strings.HasSuffix(payload, "."+domain) ||
			isSuffix && strings.HasSuffix(domain, "."+payload) {
			return true
		}
	}
	return false
}

func vpsWildcardMatches(pattern, text string) bool {
	if strings.HasPrefix(pattern, "+.") {
		rest := pattern[2:]
		if vpsWildcardMatches(rest, text) {
			return true
		}
		for i := 0; i < len(text); i++ {
			if text[i] == '.' && vpsWildcardMatches(rest, text[i+1:]) {
				return true
			}
		}
		return false
	}
	n, m := len(pattern), len(text)
	dp := make([]bool, m+1)
	next := make([]bool, m+1)
	dp[0] = true
	for i := 0; i < n; i++ {
		clear(next)
		ch := pattern[i]
		switch ch {
		case '*':
			for j := 0; j <= m; j++ {
				if dp[j] {
					next[j] = true
				} else if j > 0 && next[j-1] && text[j-1] != '.' {
					next[j] = true
				}
			}
		case '+':
			for j := 1; j <= m; j++ {
				if dp[j-1] || next[j-1] {
					next[j] = true
				}
			}
		case '?':
			for j := 1; j <= m; j++ {
				if dp[j-1] && text[j-1] != '.' {
					next[j] = true
				}
			}
		default:
			for j := 1; j <= m; j++ {
				if dp[j-1] && text[j-1] == ch {
					next[j] = true
				}
			}
		}
		dp, next = next, dp
	}
	return dp[m]
}

func vpsWildcardMatchesAI(pattern string) bool {
	pattern = strings.TrimSuffix(strings.ToLower(strings.TrimSpace(pattern)), ".")
	if pattern == "" {
		return false
	}
	if !strings.ContainsAny(pattern, "*+?") {
		return vpsDomainMatchesAI(pattern, false)
	}
	if strings.HasPrefix(pattern, "*.") && !strings.ContainsAny(pattern[2:], "*+?") {
		if vpsDomainMatchesAI(pattern[2:], false) {
			return true
		}
	}
	for _, domain := range vpsAIDomains {
		if vpsWildcardMatches(pattern, domain) || vpsWildcardMatches(pattern, "a."+domain) {
			return true
		}
	}
	return false
}

func vpsRuleProvider(providers map[string]map[string]any, name string) (map[string]any, bool) {
	if len(providers) == 0 {
		return nil, false
	}
	if p, ok := providers[name]; ok {
		return p, true
	}
	for key, p := range providers {
		if strings.EqualFold(key, name) {
			return p, true
		}
	}
	return nil, false
}

func vpsInlineProviderRoutesAI(provider map[string]any) bool {
	behavior := strings.ToLower(strings.TrimSpace(fmt.Sprint(provider["behavior"])))
	if behavior == "ipcidr" {
		return false
	}
	var entries []string
	switch raw := provider["payload"].(type) {
	case []any:
		entries = make([]string, 0, len(raw))
		for _, item := range raw {
			if s, ok := item.(string); ok {
				entries = append(entries, s)
			}
		}
	case []string:
		entries = raw
	default:
		return false
	}
	if behavior == "domain" {
		for _, entry := range entries {
			entry = strings.TrimSuffix(strings.ToLower(strings.TrimSpace(entry)), ".")
			if entry == "" {
				continue
			}
			if strings.HasPrefix(entry, "+.") || strings.HasPrefix(entry, ".") {
				suffix := strings.TrimPrefix(strings.TrimPrefix(entry, "+."), ".")
				if vpsDomainMatchesAI(suffix, true) {
					return true
				}
				continue
			}
			if strings.ContainsAny(entry, "*+?") {
				if vpsWildcardMatchesAI(entry) {
					return true
				}
				continue
			}
			if vpsDomainMatchesAI(entry, false) {
				return true
			}
		}
		return false
	}
	return vpsRoutesAIWithProviders(entries, nil)
}

func vpsRoutesAI(rules []string) bool {
	return vpsRoutesAIWithProviders(rules, nil)
}

func vpsRoutesAIWithProviders(rules []string, ruleProviders map[string]map[string]any) bool {
	for _, rule := range rules {
		fields := strings.SplitN(rule, ",", 3)
		if len(fields) < 2 {
			continue
		}
		kind := strings.ToUpper(strings.TrimSpace(fields[0]))
		rawPayload := strings.TrimSpace(fields[1])
		payload := strings.ToLower(rawPayload)
		switch kind {
		case "RULE-SET":
			if provider, ok := vpsRuleProvider(ruleProviders, rawPayload); ok &&
				strings.EqualFold(strings.TrimSpace(fmt.Sprint(provider["type"])), "inline") {
				if vpsInlineProviderRoutesAI(provider) {
					return true
				}
				continue
			}
			if !vpsNonAISets[payload] {
				return true
			}
		case "GEOSITE":
			if !vpsNonAISets[payload] {
				return true
			}
		case "SUB-RULE", "DOMAIN-REGEX", "AND", "OR", "NOT":
			return true
		case "DOMAIN", "DOMAIN-SUFFIX":
			if vpsDomainMatchesAI(payload, kind == "DOMAIN-SUFFIX") {
				return true
			}
		case "DOMAIN-WILDCARD":
			if vpsWildcardMatchesAI(payload) {
				return true
			}
		case "DOMAIN-KEYWORD":
			if len(payload) < 3 {
				continue
			}
			for _, domain := range vpsAIDomains {
				if strings.Contains(domain, payload) {
					return true
				}
			}
		}
	}
	return false
}

// vps2vpnEnhance adds the smart groups to raw in place. The AI rules go
// after the first userRules rules (the user's own); a negative userRules
// leaves the rules alone.
func vps2vpnEnhance(raw *config.RawConfig, userRules int) {
	_ = vps2vpnEnhanceResult(raw, userRules)
}

func vps2vpnEnhanceResult(raw *config.RawConfig, userRules int) vpsEnhanceResult {
	result := vpsEnhanceResult{selectIndex: -1}
	if !vpsSmartEnabled.Load() {
		return result
	}
	type line struct {
		name   string
		server int
		rank   int
	}
	var lines []line
	servers := map[string]int{}
	for i, p := range raw.Proxy {
		rank := vpsLineRank(p)
		name := vpsName(p)
		if rank < 0 || name == "" {
			continue
		}
		if rank == 1 {
			if fp, _ := p["client-fingerprint"].(string); fp == "" {
				p["client-fingerprint"] = "chrome"
				result.fingerprinted = append(result.fingerprinted, i)
			}
		}
		server := vpsProxyServer(p)
		if server == "" {
			server = "\x00" + name
		}
		order, exists := servers[server]
		if !exists {
			order = len(servers)
			servers[server] = order
		}
		lines = append(lines, line{name: name, server: order, rank: rank})
	}
	// One line has nothing to fall back to; a second protocol is what makes this useful.
	if len(lines) < 2 || vpsNameTaken(raw, vpsSmartGroup) {
		return result
	}
	sort.SliceStable(lines, func(i, j int) bool {
		if lines[i].server != lines[j].server {
			return lines[i].server < lines[j].server
		}
		return lines[i].rank < lines[j].rank
	})
	smart := make([]string, len(lines))
	for i, l := range lines {
		smart[i] = l.name
	}
	groupCount := len(raw.ProxyGroup)
	raw.ProxyGroup = append(raw.ProxyGroup, map[string]any{
		"name":             vpsSmartGroup,
		"type":             "fallback",
		"proxies":          smart,
		"url":              vpsProbeURL,
		"interval":         60,
		"timeout":          2500,
		"max-failed-times": 2,
		"lazy":             false,
	})
	result.addedGroups++
	// Offer it first in the main selector.
	for i, g := range raw.ProxyGroup[:groupCount] {
		if strings.ToLower(fmt.Sprint(g["type"])) != "select" {
			continue
		}
		switch members := g["proxies"].(type) {
		case nil:
			g["proxies"] = []string{vpsSmartGroup}
		case []any:
			g["proxies"] = append([]any{vpsSmartGroup}, members...)
		case []string:
			g["proxies"] = append([]string{vpsSmartGroup}, members...)
		default:
			continue
		}
		result.selectIndex = i
		break
	}

	if userRules < 0 {
		return result
	}
	subStart := min(userRules, len(raw.Rule))
	if vpsRoutesAIWithProviders(raw.Rule[subStart:], raw.RuleProvider) || vpsNameTaken(raw, vpsAIGroup) {
		return result
	}
	aiNames := append([]string(nil), smart...)
	raw.ProxyGroup = append(raw.ProxyGroup, map[string]any{
		"name":               vpsAIGroup,
		"type":               "fallback",
		"proxies":            aiNames,
		"url":                vpsAIProbeURL,
		"interval":           120,
		"timeout":            4000,
		"max-failed-times":   3,
		"failure-threshold":  3,
		"recovery-threshold": 3,
		"lazy":               true,
	})
	result.addedGroups++
	rules := make([]string, 0, len(vpsAIDomains)+len(raw.Rule))
	rules = append(rules, raw.Rule[:subStart]...)
	for _, d := range vpsAIDomains {
		rules = append(rules, "DOMAIN-SUFFIX,"+d+","+vpsAIGroup)
	}
	raw.Rule = append(rules, raw.Rule[subStart:]...)
	result.addedRules = len(vpsAIDomains)
	return result
}
