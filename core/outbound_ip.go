package core

import (
	"context"
	"encoding/json"
	"net/netip"
	"strings"
	"sync"
	"time"

	"github.com/metacubex/http"
)

const (
	// Racing every source at once would take every probe slot.
	outboundIpConcurrency = 3
	outboundIpStagger     = 800 * time.Millisecond

	outboundIpMaxBody = 4096

	// Kept in step with browserUa in lib/common/constant.dart.
	browserUserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
)

type OutboundIpParams struct {
	ProxyName string   `json:"proxy-name"`
	Urls      []string `json:"urls"`
	Timeout   int64    `json:"timeout"`
}

type OutboundIpResult struct {
	Url          string     `json:"url"`
	Body         string     `json:"body"`
	Delay        int64      `json:"delay"`
	Chains       []string   `json:"chains"`
	Error        string     `json:"error,omitempty"`
	CoreEpoch    uint64     `json:"core-epoch"`
	RouteVersion uint64     `json:"route-version"`
	Hits         []RouteHit `json:"hits"`
	NodeHits     []RouteHit `json:"node-hits,omitempty"`
}

// handleOutboundIp takes the first usable answer and cancels the losers so they
// stop occupying probe slots. Url is the source that was asked, not where it
// redirected, and Body is raw: Dart owns the sources and their parsers.
func handleOutboundIp(params *OutboundIpParams) *OutboundIpResult {
	epoch, version := routeStamp()
	hits := &hitRecorder{}
	failure := func(kind string) *OutboundIpResult {
		return &OutboundIpResult{Error: kind, CoreEpoch: epoch, RouteVersion: version, Hits: hits.list()}
	}
	if len(params.Urls) == 0 {
		return failure(probeErrorFailed)
	}

	timeout := timeoutFromMillis(params.Timeout, defaultProbeTimeout)
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	defer claimOutboundIp(epoch, cancel)()

	answers := make(chan *OutboundIpResult, len(params.Urls))
	next := 0
	inFlight := 0
	start := func() {
		if next >= len(params.Urls) || inFlight >= outboundIpConcurrency {
			return
		}
		url := params.Urls[next]
		next++
		inFlight++
		go func() {
			answers <- probeOutboundIpSource(ctx, url, params.ProxyName, timeout, hits)
		}()
	}

	start()

	stagger := time.NewTicker(outboundIpStagger)
	defer stagger.Stop()
	for inFlight > 0 {
		select {
		case answer := <-answers:
			inFlight--
			if answer != nil {
				return answer
			}
			start()
		case <-stagger.C:
			start()
		case <-ctx.Done():
			return failure(probeErrorKind(ctx.Err()))
		}
	}
	return failure(probeErrorFailed)
}

var (
	outboundIpClaimsMu sync.Mutex
	outboundIpClaims   = map[*context.CancelFunc]uint64{}
)

// Only an older epoch's lookup is stale; two targets of one epoch can share a request.
func claimOutboundIp(epoch uint64, cancel context.CancelFunc) func() {
	claim := &cancel
	outboundIpClaimsMu.Lock()
	for other, otherEpoch := range outboundIpClaims {
		if otherEpoch < epoch {
			(*other)()
			delete(outboundIpClaims, other)
		}
	}
	outboundIpClaims[claim] = epoch
	outboundIpClaimsMu.Unlock()
	return func() {
		outboundIpClaimsMu.Lock()
		delete(outboundIpClaims, claim)
		outboundIpClaimsMu.Unlock()
	}
}

func probeOutboundIpSource(ctx context.Context, url string, proxyName string, timeout time.Duration, hits *hitRecorder) *OutboundIpResult {
	result := runProbe(ctx, probeRequest{
		method:    http.MethodGet,
		url:       url,
		proxyName: proxyName,
		headers:   map[string]string{"User-Agent": browserUserAgent},
		timeout:   timeout,
		maxBody:   outboundIpMaxBody,
		recorder:  hits,
	})
	if result == nil || result.Error != "" || result.StatusCode != http.StatusOK || !validOutboundIpSource(url, result.Body) {
		return nil
	}
	return &OutboundIpResult{
		Url:          url,
		Body:         result.Body,
		Delay:        result.Delay,
		Chains:       result.Chains,
		CoreEpoch:    result.CoreEpoch,
		RouteVersion: result.RouteVersion,
		Hits:         result.hits,
		NodeHits:     nodeHits(result.Chains, proxyName, result.hits),
	}
}

// The hits as if the node the answer left through had been asked for: a load
// balancer above it is the exit of the target, never of the node.
func nodeHits(chains []string, proxyName string, hits []RouteHit) []RouteHit {
	if len(chains) == 0 || chains[0] == proxyName {
		return nil
	}
	node := chains[0]
	var through []RouteHit
	for _, hit := range hits {
		through = withHit(through, RouteHit{Host: hit.Host, Proxy: node, Exit: resolveExit(hit.Host, node)})
	}
	return through
}

// IsGlobalUnicast means the address has unicast *syntax*, not that it is
// globally routable. Documentation, benchmarking and protocol-assignment
// prefixes must never count as a successful exit-IP probe. Unmap IPv4-mapped
// IPv6 addresses before checking these prefixes.
var nonPublicProbePrefixes = []netip.Prefix{
	// RFC 6598 shared address space.
	netip.MustParsePrefix("100.64.0.0/10"),
	// IANA special purpose, RFC 5737 TEST-NET, RFC 2544 benchmarking.
	netip.MustParsePrefix("192.0.0.0/24"),
	netip.MustParsePrefix("192.0.2.0/24"),
	netip.MustParsePrefix("192.88.99.0/24"),
	netip.MustParsePrefix("198.18.0.0/15"),
	netip.MustParsePrefix("198.51.100.0/24"),
	netip.MustParsePrefix("203.0.113.0/24"),
	netip.MustParsePrefix("240.0.0.0/4"),
	// IANA IPv6 documentation, benchmarking, discard, dummy and SRv6 space.
	netip.MustParsePrefix("2001:db8::/32"),
	netip.MustParsePrefix("2001:2::/48"),
	netip.MustParsePrefix("3fff::/20"),
	netip.MustParsePrefix("100::/64"),
	netip.MustParsePrefix("100:0:0:1::/64"),
	netip.MustParsePrefix("5f00::/16"),
	// RFC 6052 and RFC 8215 NAT64 translation prefixes and the deprecated
	// IPv4-compatible ::/96: an IPv4 address in IPv6 form, never an exit.
	netip.MustParsePrefix("64:ff9b::/96"),
	netip.MustParsePrefix("64:ff9b:1::/48"),
	netip.MustParsePrefix("::/96"),
}

// HTTP status and a random public-IP token are not enough. The Dart side
// accepts a Cloudflare trace or JSON with a known IP/country schema, not an
// arbitrary HTML page, help link, or error document mentioning a public IP.
// Accept the same envelope here BEFORE a competing probe wins the race.
func mentionsIp(body string) bool {
	text := strings.TrimSpace(body)
	if text == "" {
		return false
	}
	if strings.HasPrefix(text, "{") {
		var doc map[string]json.RawMessage
		if err := json.Unmarshal([]byte(text), &doc); err != nil || doc == nil {
			return false
		}
		if e := doc["error"]; len(e) > 0 && string(e) != "null" &&
			string(e) != "false" && string(e) != `""` {
			return false
		}
		if string(doc["success"]) == "false" {
			return false
		}
		switch strings.ToLower(jsonString(doc["status"])) {
		case "fail", "failed", "error", "denied", "blocked":
			return false
		}
		ip := jsonString(doc["ip"])
		if ip == "" {
			return false
		}
		// Mirrors the actual source parsers in lib/models/common.dart:
		// ipinfo.io / country.is: country
		// ip.sb / ipwho.is / geojs: country_code
		// ident.me: cc
		// ipquery: location.country_code
		country := jsonString(doc["country"])
		if country == "" {
			country = jsonString(doc["country_code"])
		}
		if country == "" {
			country = jsonString(doc["cc"])
		}
		if country == "" && len(doc["location"]) > 0 {
			var location map[string]json.RawMessage
			if json.Unmarshal(doc["location"], &location) == nil {
				country = jsonString(location["country_code"])
			}
		}
		return country != "" && publicEgressIp(ip)
	}
	// Cloudflare /cdn-cgi/trace uses full key=value lines, with both
	// ip and loc required by the matching Dart parser.
	if strings.HasPrefix(text, "<") || strings.HasPrefix(text, "[") {
		return false
	}
	var ip, country string
	for _, line := range strings.Split(text, "\n") {
		key, value, ok := strings.Cut(strings.TrimSpace(line), "=")
		if !ok {
			continue
		}
		switch key {
		case "ip":
			ip = strings.TrimSpace(value)
		case "loc":
			country = strings.TrimSpace(value)
		}
	}
	return country != "" && publicEgressIp(ip)
}

// The Dart consumer chooses a different parser for each of its named sources.
// A valid union-of-sources JSON object can still fail its *specific* parser and
// prematurely cancel other probes. Keep these URL/field pairs in sync with
// lib/common/service_probe.dart and lib/models/common.dart.
func validOutboundIpSource(url string, body string) bool {
	if !mentionsIp(body) {
		return false
	}
	switch url {
	case "https://www.cloudflare.com/cdn-cgi/trace":
		// The Dart Cloudflare parser accepts key=value trace lines, never JSON.
		return !strings.HasPrefix(strings.TrimSpace(body), "{")
	case "https://ipinfo.io/json", "https://api.country.is":
		return jsonHasCountryField(body, "country")
	case "https://api.ip.sb/geoip", "https://ipwho.is",
		"https://get.geojs.io/v1/ip/geo.json":
		return jsonHasCountryField(body, "country_code")
	case "https://ident.me/json":
		return jsonHasCountryField(body, "cc")
	case "https://api.ipquery.io/?format=json":
		return jsonHasCountryField(body, "location.country_code")
	}
	// The core API also permits custom URLs; preserve generic envelope support.
	return true
}

func jsonHasCountryField(body string, field string) bool {
	var doc map[string]json.RawMessage
	if json.Unmarshal([]byte(body), &doc) != nil || doc == nil {
		return false
	}
	if field == "location.country_code" {
		var location map[string]json.RawMessage
		if json.Unmarshal(doc["location"], &location) != nil {
			return false
		}
		return jsonString(location["country_code"]) != ""
	}
	return jsonString(doc[field]) != ""
}

func jsonString(raw json.RawMessage) string {
	var value string
	if err := json.Unmarshal(raw, &value); err != nil {
		return ""
	}
	return strings.TrimSpace(value)
}

func publicEgressIp(s string) bool {
	addr, err := netip.ParseAddr(s)
	if err != nil {
		return false
	}
	addr = addr.Unmap()
	// A zone names a local interface, and netip.Prefix.Contains is false for
	// any zoned address, so one would slip past the prefixes below.
	if addr.Zone() != "" || !addr.IsGlobalUnicast() || addr.IsPrivate() {
		return false
	}
	for _, prefix := range nonPublicProbePrefixes {
		if prefix.Contains(addr) {
			return false
		}
	}
	return true
}
