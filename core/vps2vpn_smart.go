package core

import (
	"fmt"
	"net/netip"
	"regexp"
	"slices"
	"sort"
	"strings"
	"sync/atomic"
	"unicode/utf8"

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

// vpsIsReality reports a VLESS line with Reality, which wants a TLS fingerprint.
func vpsIsReality(p map[string]any) bool {
	rawType, _ := p["type"].(string)
	if strings.ToLower(strings.TrimSpace(rawType)) != "vless" {
		return false
	}
	opts, ok := p["reality-opts"].(map[string]any)
	return ok && opts != nil
}

// vpsIsUDPLine reports a QUIC line (Hysteria, TUIC), the ones UDP throttling hurts.
func vpsIsUDPLine(p map[string]any) bool {
	rawType, _ := p["type"].(string)
	switch strings.ToLower(strings.TrimSpace(rawType)) {
	case "hysteria2", "hysteria", "tuic":
		return true
	}
	return false
}

// vpsLineRank: lower is tried first; -1 means not a line to the outside.
// tcpFirst puts Reality ahead of the QUIC lines, as the panel's tcp_first does.
func vpsLineRank(p map[string]any, tcpFirst bool) int {
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
		if tcpFirst {
			return 1
		}
		return 0
	case "vless":
		if vpsIsReality(p) {
			if tcpFirst {
				return 0
			}
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

// vpsSubscriptionTCPFirst reads the order the subscription itself chose: the
// first fallback group that holds a Reality and a QUIC line of one server
// decides, by which of the two it lists first. A vps2vpn panel with tcp_first
// on lists Reality first; without such a group the QUIC lines lead.
func vpsSubscriptionTCPFirst(raw *config.RawConfig) bool {
	byName := make(map[string]map[string]any, len(raw.Proxy))
	for _, p := range raw.Proxy {
		if name := vpsName(p); name != "" {
			byName[name] = p
		}
	}
	for _, g := range raw.ProxyGroup {
		if strings.ToLower(strings.TrimSpace(fmt.Sprint(g["type"]))) != "fallback" {
			continue
		}
		var names []string
		switch values := g["proxies"].(type) {
		case []any:
			for _, v := range values {
				if name, ok := v.(string); ok {
					names = append(names, name)
				}
			}
		case []string:
			names = values
		}
		reality := map[string]bool{}
		udp := map[string]bool{}
		for _, name := range names {
			p, ok := byName[name]
			if !ok {
				continue
			}
			server := vpsProxyServer(p)
			if server == "" {
				continue
			}
			switch {
			case vpsIsReality(p):
				if udp[server] {
					return false
				}
				reality[server] = true
			case vpsIsUDPLine(p):
				if reality[server] {
					return true
				}
				udp[server] = true
			}
		}
	}
	return false
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
		// A literal AI-domain tail can have arbitrarily many leading labels.
		// Checking just the root and "a."+domain misses rules such as
		// *.*.claude.ai or api.*.openai.com that match deeper subdomains.
		if strings.HasSuffix(pattern, "."+domain) ||
			vpsWildcardMatches(pattern, domain) || vpsWildcardMatches(pattern, "a."+domain) {
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
	tcpFirst := vpsSubscriptionTCPFirst(raw)
	for i, p := range raw.Proxy {
		rank := vpsLineRank(p, tcpFirst)
		name := vpsName(p)
		if rank < 0 || name == "" {
			continue
		}
		if vpsIsReality(p) {
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
	// A server's IPv6 lines have their own address; the same name with the
	// protocol taken off puts them with the server's other lines.
	merged := map[string]int{}
	for i := range lines {
		stem := vpsLineStem(lines[i].name)
		if stem == lines[i].name {
			continue
		}
		if order, ok := merged[stem]; ok {
			lines[i].server = order
		} else {
			merged[stem] = lines[i].server
		}
	}
	sort.SliceStable(lines, func(i, j int) bool {
		if lines[i].server != lines[j].server {
			return lines[i].server < lines[j].server
		}
		return lines[i].rank < lines[j].rank
	})
	smart := make([]string, len(lines))
	var perServer [][]string
	for i, l := range lines {
		smart[i] = l.name
		if i == 0 || l.server != lines[i-1].server {
			perServer = append(perServer, nil)
		}
		perServer[len(perServer)-1] = append(perServer[len(perServer)-1], l.name)
	}
	groupCount := len(raw.ProxyGroup)
	if len(perServer) == 1 {
		// One server: its protocols in order, the exit IP never changes.
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
	} else {
		// Several servers: the fastest server, each one's protocols backing
		// each other up (one server, one exit IP). The tolerance keeps it on
		// the server it is on until another is clearly faster or it goes
		// down, so the exit IP does not hop on every small change in delay.
		members := make([]string, 0, len(perServer))
		for _, names := range perServer {
			members = append(members, vpsServerGroup(raw, names))
		}
		raw.ProxyGroup = append(raw.ProxyGroup, map[string]any{
			"name":             vpsSmartGroup,
			"type":             "url-test",
			"proxies":          members,
			"url":              vpsProbeURL,
			"interval":         120,
			"tolerance":        vpsSmartTolerance,
			"timeout":          2500,
			"max-failed-times": 2,
			"lazy":             false,
		})
	}
	result.addedGroups++
	// Offer it first in the main selector: the first select group whose own
	// first choice is a proxy. One that starts with DIRECT or REJECT (a
	// "domestic" or "ads" group) would otherwise send that traffic out.
	for i, g := range raw.ProxyGroup[:groupCount] {
		if strings.ToLower(fmt.Sprint(g["type"])) != "select" {
			continue
		}
		var members []any
		switch values := g["proxies"].(type) {
		case nil:
		case []any:
			members = values
		case []string:
			for _, name := range values {
				members = append(members, name)
			}
		default:
			continue
		}
		if len(members) > 0 && vpsBuiltinOutbound(fmt.Sprint(members[0])) {
			continue
		}
		g["proxies"] = append([]any{vpsSmartGroup}, members...)
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

// How much faster (ms) another server has to answer before the smart line
// moves to it while the one it is on still works.
const vpsSmartTolerance = 150

var vpsStemSplit = regexp.MustCompile(`^(.*?\S)(?:\s*[·|｜]\s*|\s+[-–—/]\s+)([^·|｜]+)$`)

var vpsProtocolWords = []string{
	"reality", "vless", "vmess", "trojan", "anytls", "hysteria", "hy2", "tuic",
	"shadowsocks", "wireguard", "ipv4", "ipv6",
}

// vpsLineStem is a line's name without the protocol parts at its end:
// "US1 · 1.0x · TUIC-v5-IPv6" → "US1 · 1.0x". A name with none comes back whole.
func vpsLineStem(name string) string {
	stem := strings.TrimSpace(name)
	for {
		m := vpsStemSplit.FindStringSubmatch(stem)
		if m == nil {
			return stem
		}
		tail := strings.ToLower(strings.TrimSpace(m[2]))
		protocol := tail == "ss" || tail == "wg" || tail == "v4" || tail == "v6"
		for _, word := range vpsProtocolWords {
			protocol = protocol || strings.Contains(tail, word)
		}
		if !protocol {
			return stem
		}
		stem = m[1]
	}
}

// vpsServerGroup is what the smart line lists for one server's lines (best
// protocol first): the line itself when it is the only one, a fallback group
// of the subscription's that holds exactly these lines, or else a new hidden
// fallback group of them.
func vpsServerGroup(raw *config.RawConfig, names []string) string {
	if len(names) == 1 {
		return names[0]
	}
	want := slices.Clone(names)
	slices.Sort(want)
	for _, g := range raw.ProxyGroup {
		if strings.ToLower(strings.TrimSpace(fmt.Sprint(g["type"]))) != "fallback" {
			continue
		}
		var have []string
		switch values := g["proxies"].(type) {
		case []any:
			for _, v := range values {
				name, _ := v.(string)
				have = append(have, name)
			}
		case []string:
			have = slices.Clone(values)
		}
		slices.Sort(have)
		if _, hasUse := g["use"]; !hasUse && slices.Equal(have, want) && vpsName(g) != "" {
			return vpsName(g)
		}
	}
	stem := vpsLineStem(names[0])
	if stem == names[0] {
		// No protocol part to take off: what the names share ("SG-HY2",
		// "SG-REALITY" → "SG").
		prefix := names[0]
		for _, n := range names[1:] {
			for !strings.HasPrefix(n, prefix) {
				_, size := utf8.DecodeLastRuneInString(prefix)
				prefix = prefix[:len(prefix)-size]
			}
		}
		if prefix = strings.TrimRight(prefix, " -_·|/"); prefix != "" {
			stem = prefix
		}
	}
	name := stem
	for i := 1; vpsNameTaken(raw, name); i++ {
		name = "⚡ " + stem
		if i > 1 {
			name = fmt.Sprintf("⚡ %s (%d)", stem, i)
		}
	}
	raw.ProxyGroup = append(raw.ProxyGroup, map[string]any{
		"name":             name,
		"type":             "fallback",
		"proxies":          slices.Clone(names),
		"url":              vpsProbeURL,
		"interval":         60,
		"timeout":          2500,
		"max-failed-times": 2,
		"lazy":             false,
		"hidden":           true,
	})
	return name
}

// mihomo's built-in outbounds, which are no proxy line.
func vpsBuiltinOutbound(name string) bool {
	switch strings.ToUpper(strings.TrimSpace(name)) {
	case "DIRECT", "REJECT", "REJECT-DROP", "PASS", "COMPATIBLE":
		return true
	}
	return false
}
