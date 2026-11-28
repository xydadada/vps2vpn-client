package core

import (
	"net/http"
	"sync/atomic"
	"testing"
	"time"
)

func TestHandleOutboundIpTakesTheFirstUsableAnswer(t *testing.T) {
	withProbeProxies(t, "node-a")
	slow := probeServer(t, func(w http.ResponseWriter, _ *http.Request) {
		time.Sleep(400 * time.Millisecond)
		_, _ = w.Write([]byte("slow"))
	})
	empty := probeServer(t, func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusNoContent)
	})
	quick := probeServer(t, func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte("ip=8.8.4.4\nloc=US"))
	})

	result := handleOutboundIp(&OutboundIpParams{
		ProxyName: "node-a",
		Urls:      []string{slow.URL, empty.URL, quick.URL},
		Timeout:   4000,
	})

	if result.Error != "" {
		t.Fatalf("error = %q, want none", result.Error)
	}
	if result.Body != "ip=8.8.4.4\nloc=US" {
		t.Errorf("body = %q, want the quick source's", result.Body)
	}
	if result.Url != quick.URL {
		t.Errorf("url = %q, want %q", result.Url, quick.URL)
	}
}

func TestHandleOutboundIpSkipsAnAnswerWithoutAnAddress(t *testing.T) {
	withProbeProxies(t, "node-a")
	limited := probeServer(t, func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte(`{"error":"rate limited"}`))
	})
	later := probeServer(t, func(w http.ResponseWriter, _ *http.Request) {
		time.Sleep(200 * time.Millisecond)
		_, _ = w.Write([]byte(`{"ip":"2001:4860:4860::8888","country":"JP"}`))
	})

	result := handleOutboundIp(&OutboundIpParams{
		ProxyName: "node-a",
		Urls:      []string{limited.URL, later.URL},
		Timeout:   4000,
	})

	if result.Url != later.URL {
		t.Errorf("url = %q, want the source that named an address", result.Url)
	}
}

func TestMentionsIpNeedsAWholeAddress(t *testing.T) {
	cases := map[string]bool{
		"fl=12f\nip=8.8.4.4\nloc=US\nts=1700000000.1":  true,
		`{"ip":"2001:4860:4860::8888","country":"JP"}`: true,
		`{"ip":"::ffff:8.8.4.4","cc":"US"}`:            true,
		`a::after{content:""}`:                         false,
		`div::before,li::marker{color:#fff}`:           false,
		`::-webkit-scrollbar{width:0}`:                 false,
		`<a href="http://127.0.0.1/login">`:            false,
	}
	for body, want := range cases {
		if got := mentionsIp(body); got != want {
			t.Errorf("mentionsIp(%q) = %v, want %v", body, got, want)
		}
	}
}

func TestMentionsIpSkipsLocalAddresses(t *testing.T) {
	for _, body := range []string{
		"ip=192.168.1.1\nloc=US",
		`{"ip":"10.20.30.40","country":"US"}`,
		"ip=172.16.0.9\nloc=US",
		"ip=100.64.12.34\nloc=US",
		`{"ip":"fd00::1","country_code":"US"}`,
		`{"ip":"::ffff:192.168.1.1","cc":"US"}`,
	} {
		if mentionsIp(body) {
			t.Errorf("mentionsIp(%q) = true, want false", body)
		}
	}
}

func TestMentionsIpRejectsSpecialUseAddresses(t *testing.T) {
	for _, ip := range []string{
		"192.0.0.10", "192.0.2.7", "192.88.99.1", "198.18.0.7",
		"198.51.100.7", "203.0.113.7", "240.0.0.1",
		"2001:db8::7", "2001:2::7", "::ffff:203.0.113.7",
		"3fff::1", "3fff:fff:ffff:ffff:ffff:ffff:ffff:ffff",
		"100::1", "100::ffff:ffff:ffff:ffff",
		"100:0:0:1::1", "5f00::1", "5f00:ffff::1",
	} {
		if mentionsIp("ip=" + ip + "\nloc=US") {
			t.Errorf("reserved address %s was accepted as a routable exit IP", ip)
		}
	}
	for _, ip := range []string{"1.1.1.1", "8.8.4.4", "2606:4700:4700::1111"} {
		if !mentionsIp("ip=" + ip + "\nloc=US") {
			t.Errorf("public address %s was incorrectly rejected", ip)
		}
	}
}

func TestOutboundIpSkipsDocumentationAddressAndUsesLaterPublicAnswer(t *testing.T) {
	withProbeProxies(t, "node-a")
	reserved := probeServer(t, func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte("ip=203.0.113.7\nloc=US"))
	})
	public := probeServer(t, func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte("ip=8.8.8.8\nloc=US"))
	})
	result := handleOutboundIp(&OutboundIpParams{
		ProxyName: "node-a",
		Urls:      []string{reserved.URL, public.URL},
		Timeout:   4000,
	})
	if result.Error != "" || result.Url != public.URL || result.Body != "ip=8.8.8.8\nloc=US" {
		t.Fatalf("reserved address won probe race: %+v", result)
	}
}

func TestMentionsIpRejectsErrorDocumentsEvenWithPublicAddresses(t *testing.T) {
	cases := map[string]bool{
		"<html><body>Rate limit; contact 8.8.8.8</body></html>": false,
		`{"error":"blocked","help_server":"1.1.1.1"}`:           false,
		`{"error":"blocked","ip":"8.8.8.8","country":"US"}`:     false,
		`{"success":false,"ip":"8.8.8.8","country":"US"}`:       false,
		`{"status":"fail","ip":"8.8.8.8","country":"US"}`:       false,
		`{"ip":"8.8.8.8","country":42}`:                         false,
		`{"ip":"8.8.8.8","country":""}`:                         false,
		`{"ip":"8.8.8.8","help_server":"1.1.1.1"}`:              false,
		"Message: contact 8.8.8.8 or see ip=1.1.1.1":            false,
		"ip=8.8.8.8":                                        false,
		`{"ip":"8.8.8.8","country":"US"}`:                   true,
		`{"ip":"8.8.8.8","country_code":"US"}`:              true,
		`{"ip":"8.8.8.8","cc":"US"}`:                        true,
		`{"ip":"8.8.8.8","location":{"country_code":"US"}}`: true,
		"ip=8.8.8.8\nloc=US\nts=1700000000":                 true,
	}
	for input, want := range cases {
		if got := mentionsIp(input); got != want {
			t.Errorf("mentionsIp(%q) = %v, want %v", input, got, want)
		}
	}
}

func TestOutboundIpIgnoresPublicIpInHttp200ErrorPage(t *testing.T) {
	withProbeProxies(t, "node-a")
	bad := probeServer(t, func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte("<html><body>Too many requests. DNS: 8.8.8.8</body></html>"))
	})
	good := probeServer(t, func(w http.ResponseWriter, _ *http.Request) {
		time.Sleep(120 * time.Millisecond)
		_, _ = w.Write([]byte(`{"ip":"1.1.1.1","country":"US"}`))
	})
	answer := handleOutboundIp(&OutboundIpParams{
		ProxyName: "node-a",
		Urls:      []string{bad.URL, good.URL},
		Timeout:   3000,
	})
	if answer.Error != "" || answer.Url != good.URL || answer.Body != `{"ip":"1.1.1.1","country":"US"}` {
		t.Fatalf("HTTP-200 error page won probe race: %+v", answer)
	}
}

func TestOutboundIpRequiresTheSchemaOfTheWinningProvider(t *testing.T) {
	cases := []struct {
		name, source, body string
		want               bool
	}{
		{
			"geojs reject country alias", "https://get.geojs.io/v1/ip/geo.json",
			`{"ip":"1.1.1.1","country":"US"}`, false,
		},
		{
			"geojs accept country_code", "https://get.geojs.io/v1/ip/geo.json",
			`{"ip":"1.1.1.1","country_code":"US"}`, true,
		},
		{
			"ipinfo reject country_code alias", "https://ipinfo.io/json",
			`{"ip":"1.1.1.1","country_code":"US"}`, false,
		},
		{
			"ipinfo accept country", "https://ipinfo.io/json",
			`{"ip":"1.1.1.1","country":"US"}`, true,
		},
		{
			"ident reject country alias", "https://ident.me/json",
			`{"ip":"1.1.1.1","country":"US"}`, false,
		},
		{
			"ident accept cc", "https://ident.me/json",
			`{"ip":"1.1.1.1","cc":"US"}`, true,
		},
		{
			"ipquery reject flat country", "https://api.ipquery.io/?format=json",
			`{"ip":"1.1.1.1","country_code":"US"}`, false,
		},
		{
			"ipquery accept nested location", "https://api.ipquery.io/?format=json",
			`{"ip":"1.1.1.1","location":{"country_code":"US"}}`, true,
		},
		{
			"cloudflare reject JSON", "https://www.cloudflare.com/cdn-cgi/trace",
			`{"ip":"1.1.1.1","country":"US"}`, false,
		},
		{
			"cloudflare accept trace", "https://www.cloudflare.com/cdn-cgi/trace",
			"ip=1.1.1.1\nloc=US", true,
		},
		{
			"custom URLs retain generic support", "http://127.0.0.1:1234/trace",
			`{"ip":"1.1.1.1","country":"US"}`, true,
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := validOutboundIpSource(tc.source, tc.body); got != tc.want {
				t.Errorf("validOutboundIpSource(%q, %q) = %v, want %v", tc.source, tc.body, got, tc.want)
			}
		})
	}
}

func TestHandleOutboundIpCancelsTheLosers(t *testing.T) {
	withProbeProxies(t, "node-a")
	var cancelled atomic.Bool
	losing := probeServer(t, func(w http.ResponseWriter, r *http.Request) {
		select {
		case <-r.Context().Done():
			cancelled.Store(true)
		case <-time.After(3 * time.Second):
		}
	})
	winning := probeServer(t, func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte("ip=9.9.9.9\nloc=US"))
	})

	result := handleOutboundIp(&OutboundIpParams{
		ProxyName: "node-a",
		Urls:      []string{losing.URL, winning.URL},
		Timeout:   5000,
	})

	if result.Body != "ip=9.9.9.9\nloc=US" {
		t.Fatalf("body = %q, want the winning source's", result.Body)
	}
	deadline := time.Now().Add(2 * time.Second)
	for !cancelled.Load() && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}
	if !cancelled.Load() {
		t.Error("the losing request kept running, want it cancelled once the race was won")
	}
}

func TestHandleOutboundIpCancelsALookupFromAnOlderEpoch(t *testing.T) {
	recordRoutes(t)
	withProbeProxies(t, "node-a")
	reached := make(chan struct{}, 1)
	hanging := probeServer(t, func(w http.ResponseWriter, r *http.Request) {
		reached <- struct{}{}
		select {
		case <-r.Context().Done():
		case <-time.After(3 * time.Second):
		}
	})
	winning := probeServer(t, func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte("ip=9.9.9.9\nloc=US"))
	})

	stampRoute(1, 0)
	older := make(chan *OutboundIpResult, 1)
	go func() {
		older <- handleOutboundIp(&OutboundIpParams{ProxyName: "node-a", Urls: []string{hanging.URL}, Timeout: 5000})
	}()
	<-reached
	stampRoute(2, 0)
	handleOutboundIp(&OutboundIpParams{ProxyName: "node-a", Urls: []string{winning.URL}, Timeout: 5000})

	select {
	case answer := <-older:
		if answer.Error == "" || answer.CoreEpoch != 1 {
			t.Errorf("older lookup = %+v, want a failure stamped with its own epoch", answer)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("the lookup from the older epoch kept running")
	}
}

func TestHandleOutboundIpLeavesALookupFromTheSameEpoch(t *testing.T) {
	recordRoutes(t)
	withProbeProxies(t, "node-a")
	reached := make(chan struct{}, 1)
	slow := probeServer(t, func(w http.ResponseWriter, _ *http.Request) {
		reached <- struct{}{}
		time.Sleep(300 * time.Millisecond)
		_, _ = w.Write([]byte("ip=8.8.4.4\nloc=US"))
	})
	fast := probeServer(t, func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte("ip=9.9.9.9\nloc=US"))
	})

	stampRoute(1, 0)
	first := make(chan *OutboundIpResult, 1)
	go func() {
		first <- handleOutboundIp(&OutboundIpParams{ProxyName: "node-a", Urls: []string{slow.URL}, Timeout: 5000})
	}()
	<-reached
	handleOutboundIp(&OutboundIpParams{ProxyName: "node-a", Urls: []string{fast.URL}, Timeout: 5000})

	if answer := <-first; answer.Body != "ip=8.8.4.4\nloc=US" {
		t.Errorf("first lookup = %+v, want it to finish beside the second", answer)
	}
}

func TestHandleOutboundIpReportsWhenEverySourceFails(t *testing.T) {
	withProbeProxies(t, "node-a")
	broken := probeServer(t, func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
	})

	result := handleOutboundIp(&OutboundIpParams{
		ProxyName: "node-a",
		Urls:      []string{broken.URL, broken.URL},
		Timeout:   3000,
	})

	if result.Error != probeErrorFailed {
		t.Errorf("error = %q, want %q", result.Error, probeErrorFailed)
	}
}

func TestHandleOutboundIpRejectsAnEmptySourceList(t *testing.T) {
	result := handleOutboundIp(&OutboundIpParams{ProxyName: "node-a", Timeout: 1000})
	if result.Error != probeErrorFailed {
		t.Errorf("error = %q, want %q", result.Error, probeErrorFailed)
	}
}

func TestPublicEgressIpRefusesAZonedAddress(t *testing.T) {
	if publicEgressIp("2001:db8::1%eth0") || publicEgressIp("2606:4700::1%1") {
		t.Fatal("a zoned address counted as a public exit IP")
	}
	if !publicEgressIp("2606:4700::1") {
		t.Fatal("a public address was refused")
	}
}

func TestPublicEgressIpRefusesNat64AndIpv4CompatibleAddresses(t *testing.T) {
	for _, addr := range []string{"64:ff9b::808:808", "64:ff9b:1::1", "::808:808"} {
		if publicEgressIp(addr) {
			t.Errorf("%s counted as a public exit IP", addr)
		}
	}
}
