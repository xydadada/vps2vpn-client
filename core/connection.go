package core

import (
	"github.com/metacubex/mihomo/component/resolver"
	"github.com/metacubex/mihomo/constant"
	cp "github.com/metacubex/mihomo/constant/provider"
	"github.com/metacubex/mihomo/dns"
	"github.com/metacubex/mihomo/tunnel"
	"github.com/metacubex/mihomo/tunnel/statistic"
)

func handleGetTraffic(params TrafficParams) Traffic {
	up, down := statistic.DefaultManager.NowTraffic(params.OnlyProxy)
	return Traffic{Up: up, Down: down}
}

func handleGetTotalTraffic(params TrafficParams) Traffic {
	up, down := statistic.DefaultManager.TotalTraffic(params.OnlyProxy)
	return Traffic{Up: up, Down: down}
}

func handleResetTraffic() {
	statistic.DefaultManager.ResetStatistic()
}

func handleGetConnections() *statistic.Snapshot {
	return statistic.DefaultManager.Snapshot()
}

func handleGetConnectionCount() int {
	count := 0
	statistic.DefaultManager.Range(func(statistic.Tracker) bool {
		count++
		return true
	})
	return count
}

func handleCloseConnections() {
	statistic.DefaultManager.Range(func(c statistic.Tracker) bool {
		_ = c.Close()
		return true
	})
}

func handleResetConnections() {
	resolver.ResetConnection()
}

// A network change clears rather than waits out the TTLs: mihomo serves an
// expired entry once more before it refreshes it.
func handleClearDnsCache() {
	configMu.Lock()
	defer configMu.Unlock()
	dns.ClearAll()
}

// handleNetworkChanged is how the desktop host reports a new network, which
// Android's NetworkObserver reports through handleResetNetwork. The epoch
// moves so the probes left on the old network, which hang or were just
// closed, give up their slots and their answers.
func handleNetworkChanged() {
	handleClearDnsCache()
	bumpRouteEpoch()
}

// A connection that went out over a network the device has left hangs until
// TCP gives up on it, and so do the DNS clients' pooled connections and the
// socket or QUIC connection a WireGuard, Hysteria2 or TUIC outbound shares.
func handleResetNetwork() {
	handleCloseConnections()
	resetOutbounds()
	handleNetworkChanged()
}

// handleHostNetworkChanged is a new network on the same adapter, such as a
// laptop moving from one Wi-Fi to a phone's hotspot: the smart groups check
// their lines at once, as after a reset, instead of up to two minutes later.
func handleHostNetworkChanged() {
	handleNetworkChanged()
	checkSmartGroups()
}

// handleNetworkReset is the desktop's handleResetNetwork, which the host sends
// after a wake or a move of the default network. The smart groups check their
// lines at once rather than at their next interval, so a line the new network
// cannot reach is left before the traffic piles onto it.
func handleNetworkReset() {
	handleResetNetwork()
	checkSmartGroups()
}

type providerGroup interface {
	Providers() []cp.ProxyProvider
}

func checkSmartGroups() {
	proxies := tunnel.Proxies()
	for _, name := range []string{vpsSmartGroup, vpsAIGroup} {
		proxy, ok := proxies[name]
		if !ok {
			continue
		}
		group, ok := proxy.Adapter().(providerGroup)
		if !ok {
			continue
		}
		for _, pd := range group.Providers() {
			safeGo("health check "+name, pd.HealthCheck)
		}
	}
}

type networkResetter interface{ ResetNetwork() }

// AllProxies keeps one proxy per name; providers may each hold one by that name.
func resetOutbounds() {
	reset := make(map[networkResetter]struct{})
	visit := func(proxy constant.Proxy) {
		outbound, ok := proxy.Adapter().(networkResetter)
		if !ok {
			return
		}
		if _, done := reset[outbound]; done {
			return
		}
		reset[outbound] = struct{}{}
		outbound.ResetNetwork()
	}
	for _, proxy := range tunnel.AllProxies() {
		visit(proxy)
	}
	for _, provider := range tunnel.ProvidersSnapshot() {
		for _, proxy := range provider.Proxies() {
			visit(proxy)
		}
	}
}

// A connection that is already gone is closed as far as the host is concerned.
func handleCloseConnection(params IDParams) error {
	if c := statistic.DefaultManager.Get(params.ID); c != nil {
		_ = c.Close()
	}
	return nil
}
