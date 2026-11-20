package core

import (
	"context"
	"net/http"
	"testing"
	"time"
)

func TestProbeBodyTimeoutIsNotAnAvailableAnswer(t *testing.T) {
	server := probeServer(t, func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Length", "1000")
		_, _ = w.Write([]byte("ip=203.0.113.7"))
		w.(http.Flusher).Flush()
		<-r.Context().Done()
	})
	withProbeProxies(t, "local")
	for _, scan := range []bool{false, true} {
		request := probeRequest{url: server.URL, proxyName: "local", timeout: 100 * time.Millisecond, maxBody: 1024}
		if scan {
			request.until = func(string) bool { return false }
		}
		result := runProbe(context.Background(), request)
		if result == nil || result.Error != probeErrorTimeout || itemFrom(result).Status != serviceTimeout {
			t.Fatalf("scan=%v: incomplete body was accepted: %+v", scan, result)
		}
	}
}

func TestPrimeVideoRestrictionUsesTheBooleanValue(t *testing.T) {
	for _, test := range []struct{ body, status, region string }{
		{`{"isServiceRestricted":false,"currentTerritory":"JP"}`, serviceAvailable, "JP"},
		{`{"isServiceRestricted" : true,"currentTerritory":"JP"}`, serviceUnsupportedRegion, ""},
		{`{"currentTerritory" : "US"}`, serviceAvailable, "US"},
		{`{"isServiceRestricted":false}`, serviceFailed, ""},
	} {
		item := primeVideoResult(&ProbeResult{StatusCode: http.StatusOK, Body: test.body})
		if item.Status != test.status || item.Region != test.region {
			t.Fatalf("%s: %+v, want %s/%s", test.body, item, test.status, test.region)
		}
	}
}
