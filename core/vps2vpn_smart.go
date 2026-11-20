package core

// vps2vpn smart lines: added on top of whatever the subscription brings,
// never replacing it.
//
//   - "⚡ 智能线路" (fallback): every protocol of the primary server (the
//     subscription's first line) fast-first (Hysteria2/TUIC, then REALITY,
//     then the rest), and only after them the other servers. When the ISP
//     throttles UDP and the fast line stops answering, traffic moves to
//     REALITY on the same machine within about a minute, so the exit IP does
//     not change; it comes back on its own once the fast line answers again.
//     Another server (another IP) is used only when the whole primary server
//     is unreachable. It becomes the first choice of the subscription's first
//     selector, so new users get it without doing anything; a choice the user
//     made is kept.
//   - "🤖 AI 专线" (fallback): the same order, but slower to give up on a
//     line, so AI sites keep seeing one exit IP (a changing IP is what makes
//     them ask for verification or flag the account). Only added, with its
//     rules, when the subscription does not route AI sites itself: curated
//     rules always win.
//   - REALITY lines without a client fingerprint get "chrome", so the TLS
//     handshake looks like a browser's.

import (
	"fmt"
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

// vpsLineRank: lower is tried first; -1 means not a line to the outside.
func vpsLineRank(p map[string]any) int {
	t := strings.ToLower(fmt.Sprint(p["type"]))
	switch t {
	case "hysteria2", "hysteria", "tuic":
		return 0
	case "vless":
		if _, ok := p["reality-opts"]; ok {
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

func vpsHasGroup(raw *config.RawConfig, name string) bool {
	for _, g := range raw.ProxyGroup {
		if vpsName(g) == name {
			return true
		}
	}
	return false
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

func vpsRoutesAI(rules []string) bool {
	for _, rule := range rules {
		fields := strings.SplitN(rule, ",", 3)
		if len(fields) < 2 {
			continue
		}
		kind := strings.ToUpper(strings.TrimSpace(fields[0]))
		payload := strings.ToLower(strings.TrimSpace(fields[1]))
		switch kind {
		case "RULE-SET", "SUB-RULE", "GEOSITE", "DOMAIN-REGEX", "AND", "OR", "NOT":
			return true
		case "DOMAIN", "DOMAIN-SUFFIX":
			payload = strings.TrimSuffix(payload, ".")
			for _, domain := range vpsAIDomains {
				if payload == domain || strings.HasSuffix(payload, "."+domain) ||
					kind == "DOMAIN-SUFFIX" && strings.HasSuffix(domain, "."+payload) {
					return true
				}
			}
		case "DOMAIN-KEYWORD":
			for _, domain := range vpsAIDomains {
				if payload != "" && strings.Contains(domain, payload) {
					return true
				}
			}
		}
	}
	return false
}

type vpsEnhancement struct {
	fingerprints []int
	selector     int
	groups       int
	ruleOffset   int
	rules        int
}

// vps2vpnEnhance adds the smart groups to raw in place. The AI rules go
// after the first userRules rules (the user's own); a negative userRules
// leaves the rules alone.
func vps2vpnEnhance(raw *config.RawConfig, userRules int) vpsEnhancement {
	change := vpsEnhancement{selector: -1}
	if !vpsSmartEnabled.Load() {
		return change
	}
	type line struct {
		name   string
		server string
		rank   int
	}
	var lines []line
	serverOrder := make(map[string]int)
	for i, p := range raw.Proxy {
		rank := vpsLineRank(p)
		name := vpsName(p)
		if rank < 0 || name == "" {
			continue
		}
		if rank == 1 {
			if fp, _ := p["client-fingerprint"].(string); fp == "" {
				p["client-fingerprint"] = "chrome"
				change.fingerprints = append(change.fingerprints, i)
			}
		}
		server, _ := p["server"].(string)
		if server == "" {
			server = "\x00" + name
		}
		if _, exists := serverOrder[server]; !exists {
			serverOrder[server] = len(serverOrder)
		}
		lines = append(lines, line{name: name, server: server, rank: rank})
	}
	// One line has nothing to fall back to; a second protocol is what makes this useful.
	if len(lines) < 2 || vpsNameTaken(raw, vpsSmartGroup) {
		return change
	}
	sort.SliceStable(lines, func(i, j int) bool {
		si, sj := serverOrder[lines[i].server], serverOrder[lines[j].server]
		if si != sj {
			return si < sj
		}
		return lines[i].rank < lines[j].rank
	})
	smart := make([]string, len(lines))
	for i, l := range lines {
		smart[i] = l.name
	}
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
	change.groups++
	for i, g := range raw.ProxyGroup {
		if strings.ToLower(fmt.Sprint(g["type"])) != "select" {
			continue
		}
		switch members := g["proxies"].(type) {
		case []string:
			g["proxies"] = append([]string{vpsSmartGroup}, members...)
		case []any:
			g["proxies"] = append([]any{vpsSmartGroup}, members...)
		case nil:
			g["proxies"] = []string{vpsSmartGroup}
		default:
			continue
		}
		change.selector = i
		break
	}

	if userRules < 0 || vpsRoutesAI(raw.Rule[min(userRules, len(raw.Rule)):]) || vpsNameTaken(raw, vpsAIGroup) {
		return change
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
		"lazy":               false,
	})
	change.groups++
	userRules = min(userRules, len(raw.Rule))
	change.ruleOffset = userRules
	change.rules = len(vpsAIDomains)
	rules := make([]string, 0, len(vpsAIDomains)+len(raw.Rule))
	rules = append(rules, raw.Rule[:userRules]...)
	for _, d := range vpsAIDomains {
		rules = append(rules, "DOMAIN-SUFFIX,"+d+","+vpsAIGroup)
	}
	raw.Rule = append(rules, raw.Rule[userRules:]...)
	return change
}
