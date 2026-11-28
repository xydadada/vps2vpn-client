package core

import (
	"context"
	"testing"
	"time"

	"github.com/metacubex/mihomo/adapter"
	"github.com/metacubex/mihomo/adapter/outboundgroup"
	"github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/tunnel"
	"github.com/metacubex/mihomo/tunnel/statistic"
)

type fakeLineConn struct {
	chains []string
	closed int
}

func (c *fakeLineConn) chain() []string { return c.chains }

func (c *fakeLineConn) Close() error {
	c.closed++
	return nil
}

type fakeClock struct{ at time.Time }

func (c *fakeClock) now() time.Time { return c.at }

func (c *fakeClock) advance(d time.Duration) { c.at = c.at.Add(d) }

func newTestLineWatch() (*lineWatch, *fakeClock) {
	clock := &fakeClock{at: time.Unix(1_700_000_000, 0)}
	return newLineWatch(lineWatchCooldown, clock.now), clock
}

func smartGroupAt(id any, now string, dead ...string) lineGroup {
	down := map[string]bool{}
	for _, line := range dead {
		down[line] = true
	}
	return lineGroup{
		name:  vpsSmartGroup,
		id:    id,
		now:   now,
		alive: func(line string) bool { return !down[line] },
	}
}

func TestLineWatchClosesOnlyTheConnectionsOnTheLineThatWentDown(t *testing.T) {
	watch, _ := newTestLineWatch()
	group := new(int)
	if moves := watch.observe([]lineGroup{smartGroupAt(group, "hy2")}); len(moves) != 0 {
		t.Fatalf("first sight moved: %v", moves)
	}
	moves := watch.observe([]lineGroup{smartGroupAt(group, "reality", "hy2")})
	if len(moves) != 1 || moves[0] != (lineMove{group: vpsSmartGroup, from: "hy2", to: "reality"}) {
		t.Fatalf("moves = %v", moves)
	}

	viaSmart := &fakeLineConn{chains: []string{"hy2", vpsSmartGroup, "Proxy"}}
	viaAI := &fakeLineConn{chains: []string{"hy2", vpsAIGroup}}
	pickedDirectly := &fakeLineConn{chains: []string{"hy2", "Proxy"}}
	onNewLine := &fakeLineConn{chains: []string{"reality", vpsSmartGroup, "Proxy"}}
	direct := &fakeLineConn{chains: []string{"DIRECT"}}
	conns := []lineConn{viaSmart, viaAI, pickedDirectly, onNewLine, direct}

	if closed := closeOnMovedLines(conns, moves); closed != 1 {
		t.Fatalf("closed %d connections, want 1", closed)
	}
	if viaSmart.closed != 1 {
		t.Fatal("the connection the smart group sent over the dead line stayed open")
	}
	for _, conn := range []*fakeLineConn{viaAI, pickedDirectly, onNewLine, direct} {
		if conn.closed != 0 {
			t.Fatalf("closed %v, which the move does not touch", conn.chains)
		}
	}
}

func TestLineWatchLeavesAWorkingLineAloneWhenTheGroupMovesBack(t *testing.T) {
	watch, _ := newTestLineWatch()
	group := new(int)
	watch.observe([]lineGroup{smartGroupAt(group, "reality", "hy2")})
	// hy2 recovered; the group goes back to it while reality still works.
	if moves := watch.observe([]lineGroup{smartGroupAt(group, "hy2")}); len(moves) != 0 {
		t.Fatalf("moving off a working line closed its connections: %v", moves)
	}
}

func TestLineWatchClosesOncePerCooldownForAFlappingLine(t *testing.T) {
	watch, clock := newTestLineWatch()
	group := new(int)
	watch.observe([]lineGroup{smartGroupAt(group, "hy2")})
	if moves := watch.observe([]lineGroup{smartGroupAt(group, "reality", "hy2")}); len(moves) != 1 {
		t.Fatalf("first drop: %v", moves)
	}
	clock.advance(lineWatchInterval)
	watch.observe([]lineGroup{smartGroupAt(group, "hy2")})
	clock.advance(lineWatchInterval)
	if moves := watch.observe([]lineGroup{smartGroupAt(group, "reality", "hy2")}); len(moves) != 0 {
		t.Fatalf("a flap inside the cooldown closed again: %v", moves)
	}
	clock.advance(lineWatchCooldown)
	watch.observe([]lineGroup{smartGroupAt(group, "hy2")})
	if moves := watch.observe([]lineGroup{smartGroupAt(group, "reality", "hy2")}); len(moves) != 1 {
		t.Fatalf("a drop after the cooldown was ignored: %v", moves)
	}
}

// Connections opened on hy2 while it was briefly back are closed once the
// cooldown ends, instead of being left on it after the group moved on.
func TestLineWatchClosesAHeldBackMoveWhenTheCooldownEnds(t *testing.T) {
	watch, clock := newTestLineWatch()
	group := new(int)
	watch.observe([]lineGroup{smartGroupAt(group, "hy2")})
	watch.observe([]lineGroup{smartGroupAt(group, "reality", "hy2")})
	clock.advance(lineWatchInterval)
	watch.observe([]lineGroup{smartGroupAt(group, "hy2")})
	clock.advance(lineWatchInterval)
	if moves := watch.observe([]lineGroup{smartGroupAt(group, "reality", "hy2")}); len(moves) != 0 {
		t.Fatalf("a flap inside the cooldown closed again: %v", moves)
	}
	clock.advance(lineWatchInterval)
	if moves := watch.observe([]lineGroup{smartGroupAt(group, "reality", "hy2")}); len(moves) != 0 {
		t.Fatalf("closed before the cooldown ended: %v", moves)
	}
	clock.advance(lineWatchCooldown)
	moves := watch.observe([]lineGroup{smartGroupAt(group, "reality", "hy2")})
	if len(moves) != 1 || moves[0] != (lineMove{group: vpsSmartGroup, from: "hy2", to: "reality"}) {
		t.Fatalf("the held-back move = %v", moves)
	}
	clock.advance(lineWatchCooldown)
	if moves := watch.observe([]lineGroup{smartGroupAt(group, "reality", "hy2")}); len(moves) != 0 {
		t.Fatalf("a held-back move was closed twice: %v", moves)
	}
}

func TestLineWatchDropsAHeldBackMoveOnceTheLineWorks(t *testing.T) {
	watch, clock := newTestLineWatch()
	group := new(int)
	watch.observe([]lineGroup{smartGroupAt(group, "hy2")})
	watch.observe([]lineGroup{smartGroupAt(group, "reality", "hy2")})
	watch.observe([]lineGroup{smartGroupAt(group, "hy2")})
	watch.observe([]lineGroup{smartGroupAt(group, "reality", "hy2")})
	clock.advance(lineWatchCooldown)
	if moves := watch.observe([]lineGroup{smartGroupAt(group, "reality")}); len(moves) != 0 {
		t.Fatalf("closed connections on a line that works again: %v", moves)
	}
}

func TestLineWatchCooldownIsPerLine(t *testing.T) {
	watch, clock := newTestLineWatch()
	group := new(int)
	watch.observe([]lineGroup{smartGroupAt(group, "hy2")})
	watch.observe([]lineGroup{smartGroupAt(group, "reality", "hy2")})
	clock.advance(lineWatchInterval)
	moves := watch.observe([]lineGroup{smartGroupAt(group, "trojan", "hy2", "reality")})
	if len(moves) != 1 || moves[0].from != "reality" {
		t.Fatalf("the second line going down was held back by the first: %v", moves)
	}
}

func TestLineWatchTakesAReloadAsAFreshStart(t *testing.T) {
	watch, _ := newTestLineWatch()
	watch.observe([]lineGroup{smartGroupAt(new(int), "hy2")})
	if moves := watch.observe([]lineGroup{smartGroupAt(new(int), "reality", "hy2")}); len(moves) != 0 {
		t.Fatalf("a rebuilt group was taken for a failover: %v", moves)
	}
}

func TestLineWatchForgetsAGroupThatIsGone(t *testing.T) {
	watch, _ := newTestLineWatch()
	group := new(int)
	watch.observe([]lineGroup{smartGroupAt(group, "hy2")})
	watch.observe(nil)
	if moves := watch.observe([]lineGroup{smartGroupAt(group, "reality", "hy2")}); len(moves) != 0 {
		t.Fatalf("a group seen again after it was gone moved: %v", moves)
	}
}

func TestLineWatchReloadResetsCooldownForNewFallbackInstance(t *testing.T) {
	watch, clock := newTestLineWatch()
	oldGroup := new(int)
	newGroup := new(int)
	watch.observe([]lineGroup{smartGroupAt(oldGroup, "hy2")})
	if moves := watch.observe([]lineGroup{smartGroupAt(oldGroup, "reality", "hy2")}); len(moves) != 1 {
		t.Fatalf("original group did not fail over: %v", moves)
	}
	clock.advance(lineWatchInterval)
	// The rebuilt Fallback has a different identity and can open fresh
	// connections on the same line the former instance already left.
	if moves := watch.observe([]lineGroup{smartGroupAt(newGroup, "hy2")}); len(moves) != 0 {
		t.Fatalf("reload was mistaken for a line move: %v", moves)
	}
	moves := watch.observe([]lineGroup{smartGroupAt(newGroup, "reality", "hy2")})
	if len(moves) != 1 || moves[0].from != "hy2" || moves[0].to != "reality" {
		t.Fatalf("new group's failed line was suppressed by prior cooldown: %v", moves)
	}
}

func TestLineWatchStopAndRestartResetsCooldown(t *testing.T) {
	watch, clock := newTestLineWatch()
	group := new(int)
	watch.observe([]lineGroup{smartGroupAt(group, "hy2")})
	if moves := watch.observe([]lineGroup{smartGroupAt(group, "reality", "hy2")}); len(moves) != 1 {
		t.Fatalf("original line failover = %v", moves)
	}
	clock.advance(lineWatchInterval)
	watch.observe(nil)
	watch.observe([]lineGroup{smartGroupAt(group, "hy2")})
	if moves := watch.observe([]lineGroup{smartGroupAt(group, "reality", "hy2")}); len(moves) != 1 {
		t.Fatalf("cooldown leaked from before the stop: %v", moves)
	}
}

func TestLineWatchLetsGoOfTheGroupsOnceStopped(t *testing.T) {
	watch, _ := newTestLineWatch()
	isRunning.Store(false)
	vpsOn(t)
	watch.observe([]lineGroup{smartGroupAt(new(int), "hy2")})
	checkLineMoves(watch)
	if len(watch.seen) != 0 {
		t.Fatalf("a stopped core still holds %d groups", len(watch.seen))
	}
}

func TestLineWatchLetsGoOfTheGroupsOnceSmartLinesAreOff(t *testing.T) {
	watch, _ := newTestLineWatch()
	isRunning.Store(true)
	t.Cleanup(func() { isRunning.Store(false) })
	vpsSmartEnabled.Store(false)
	watch.observe([]lineGroup{smartGroupAt(new(int), "hy2")})
	checkLineMoves(watch)
	if len(watch.seen) != 0 {
		t.Fatalf("smart lines off, the watch still holds %d groups", len(watch.seen))
	}
}

func TestLineCheckSurvivesAPanic(t *testing.T) {
	runLineCheck(func() { panic("boom") })
	ran := false
	runLineCheck(func() { ran = true })
	if !ran {
		t.Fatal("the check after a panic did not run")
	}
}

// Against mihomo's own Fallback: the line it leaves is judged by the group's
// test URL, and a group that is not a Fallback is not watched.
func TestLineWatchFollowsARealFallbackOffADeadLine(t *testing.T) {
	const url = "http://line-watch.invalid/generate_204"
	members := []constant.Proxy{namedProxy("hy2"), namedProxy("reality")}
	fallback := newLocalFallback(t, vpsSmartGroup, url, outboundgroup.FallbackOption{}, members)
	tunnel.UpdateProxies(map[string]constant.Proxy{
		vpsSmartGroup: adapter.NewProxy(fallback),
		vpsAIGroup:    selectorGroup(t, vpsAIGroup, "hy2"),
	}, nil)
	t.Cleanup(func() { tunnel.UpdateProxies(nil, nil) })

	watch, _ := newTestLineWatch()
	groups := currentLineGroups()
	if len(groups) != 1 || groups[0].name != vpsSmartGroup || groups[0].now != "hy2" {
		t.Fatalf("groups = %+v, want the smart group on hy2 alone", groups)
	}
	watch.observe(groups)

	// A probe that fails marks hy2 down for the group's URL only.
	dead, cancel := context.WithCancel(context.Background())
	cancel()
	_, _ = members[0].URLTest(dead, url, nil)
	if members[0].AliveForTestUrl(url) {
		t.Fatal("the failed probe left hy2 up")
	}

	moves := watch.observe(currentLineGroups())
	if len(moves) != 1 || moves[0] != (lineMove{group: vpsSmartGroup, from: "hy2", to: "reality"}) {
		t.Fatalf("moves = %v", moves)
	}
	if groups[0].alive("gone") != true {
		t.Fatal("a line the group no longer has was taken for a dead one")
	}
}

// A vps2vpn panel with several servers routes AI sites through a select group
// whose choice is one server's own fallback group, and the app adds no AI
// group then. That server losing a protocol must not leave an AI stream on it.
func TestLineWatchFollowsAPanelServerGroupTheAIRouteUses(t *testing.T) {
	const url = "http://line-watch.invalid/server"
	const server = "Tokyo"
	members := []constant.Proxy{namedProxy("tokyo-hy2"), namedProxy("tokyo-reality")}
	fallback := newLocalFallback(t, server, url, outboundgroup.FallbackOption{}, members)
	tunnel.UpdateProxies(map[string]constant.Proxy{
		server:      adapter.NewProxy(fallback),
		"AI":        selectorGroup(t, "AI", server),
		"tokyo-hy2": members[0],
	}, nil)
	t.Cleanup(func() { tunnel.UpdateProxies(nil, nil) })

	watch, _ := newTestLineWatch()
	groups := currentLineGroups()
	if len(groups) != 1 || groups[0].name != server || groups[0].now != "tokyo-hy2" {
		t.Fatalf("groups = %+v, want the server group on tokyo-hy2", groups)
	}
	watch.observe(groups)

	dead, cancel := context.WithCancel(context.Background())
	cancel()
	_, _ = members[0].URLTest(dead, url, nil)
	moves := watch.observe(currentLineGroups())
	if len(moves) != 1 || moves[0] != (lineMove{group: server, from: "tokyo-hy2", to: "tokyo-reality"}) {
		t.Fatalf("moves = %v", moves)
	}
	stream := &fakeLineConn{chains: []string{"tokyo-hy2", server, "AI"}}
	other := &fakeLineConn{chains: []string{"tokyo-reality", server, "AI"}}
	if closed := closeOnMovedLines([]lineConn{stream, other}, moves); closed != 1 || stream.closed != 1 {
		t.Fatalf("closed %d, stream closed %d times", closed, stream.closed)
	}
}

func TestChainLeavesNeedsTheLineRightBeforeTheGroup(t *testing.T) {
	cases := []struct {
		chain []string
		want  bool
	}{
		{[]string{"hy2", vpsSmartGroup}, true},
		{[]string{"hy2", vpsSmartGroup, "Proxy", "GLOBAL"}, true},
		{[]string{"hy2", "Other", vpsSmartGroup}, false},
		{[]string{vpsSmartGroup, "hy2"}, false},
		{[]string{"hy2"}, false},
		{nil, false},
	}
	for _, tc := range cases {
		if got := chainLeaves(tc.chain, vpsSmartGroup, "hy2"); got != tc.want {
			t.Errorf("chainLeaves(%v) = %v, want %v", tc.chain, got, tc.want)
		}
	}
}

func TestCloseOnMovedLinesClosesAConnectionOnce(t *testing.T) {
	conn := &fakeLineConn{chains: []string{"hy2", vpsAIGroup, "hy2", vpsSmartGroup}}
	moves := []lineMove{
		{group: vpsSmartGroup, from: "hy2", to: "reality"},
		{group: vpsAIGroup, from: "hy2", to: "reality"},
	}
	if closed := closeOnMovedLines([]lineConn{conn}, moves); closed != 1 || conn.closed != 1 {
		t.Fatalf("closed = %d, conn closed %d times", closed, conn.closed)
	}
}

type graphLineTracker struct {
	statistic.Tracker
	id      string
	info    statistic.TrackerInfo
	closed  bool
	onClose func()
}

func (c *graphLineTracker) ID() string                   { return c.id }
func (c *graphLineTracker) Info() *statistic.TrackerInfo { return &c.info }
func (c *graphLineTracker) Close() error {
	c.closed = true
	statistic.DefaultManager.Leave(c)
	if c.onClose != nil {
		c.onClose()
	}
	return nil
}

func TestLineWatchDiscardsMovesFromReplacedGraph(t *testing.T) {
	for _, restoreOriginalNames := range []bool{false, true} {
		t.Run(map[bool]string{false: "replacement", true: "switch-back"}[restoreOriginalNames], func(t *testing.T) {
			keepTunnel(t)
			vpsOn(t)
			running := isRunning.Swap(true)
			t.Cleanup(func() { isRunning.Store(running) })
			const groupName = "server"
			const probeURL = "http://example.invalid/generate_204"
			members := []constant.Proxy{namedProxy("hy2"), namedProxy("reality")}
			oldGroup := newLocalFallback(t, groupName, probeURL, outboundgroup.FallbackOption{}, members)
			tunnel.UpdateProxies(map[string]constant.Proxy{groupName: adapter.NewProxy(oldGroup)}, nil)
			watch, _ := newTestLineWatch()
			watch.observe(currentLineGroups())
			dead, cancel := context.WithCancel(context.Background())
			cancel()
			_, _ = members[0].URLTest(dead, probeURL, nil)

			tracker := &graphLineTracker{
				id:   "new-profile-stream",
				info: statistic.TrackerInfo{Chain: constant.Chain{"hy2", groupName}},
			}
			t.Cleanup(func() { statistic.DefaultManager.Leave(tracker) })
			watch.clock = func() time.Time {
				if restoreOriginalNames {
					tunnel.UpdateProxies(map[string]constant.Proxy{"other-profile": namedProxy("other-profile")}, nil)
				}
				replacement := newLocalFallback(t, groupName, probeURL, outboundgroup.FallbackOption{},
					[]constant.Proxy{namedProxy("hy2"), namedProxy("reality")})
				tunnel.UpdateProxies(map[string]constant.Proxy{groupName: adapter.NewProxy(replacement)}, nil)
				statistic.DefaultManager.Join(tracker)
				return time.Unix(1_700_000_001, 0)
			}
			checkLineMoves(watch)
			if tracker.closed {
				t.Fatal("a stale failover closed the replacement profile's healthy same-name stream")
			}
		})
	}
}

func TestLineWatchClosesCurrentGraphBeforeNewConnectionsJoin(t *testing.T) {
	keepTunnel(t)
	vpsOn(t)
	running := isRunning.Swap(true)
	t.Cleanup(func() { isRunning.Store(running) })
	const groupName = "server"
	const probeURL = "http://example.invalid/generate_204"
	members := []constant.Proxy{namedProxy("hy2"), namedProxy("reality")}
	group := newLocalFallback(t, groupName, probeURL, outboundgroup.FallbackOption{}, members)
	tunnel.UpdateProxies(map[string]constant.Proxy{groupName: adapter.NewProxy(group)}, nil)
	watch, _ := newTestLineWatch()
	watch.observe(currentLineGroups())
	dead, cancel := context.WithCancel(context.Background())
	cancel()
	_, _ = members[0].URLTest(dead, probeURL, nil)
	fresh := &graphLineTracker{id: "late-profile-stream", info: statistic.TrackerInfo{Chain: constant.Chain{"hy2", groupName}}}
	old := &graphLineTracker{id: "failed-profile-stream", info: statistic.TrackerInfo{Chain: constant.Chain{"hy2", groupName}}}
	t.Cleanup(func() {
		statistic.DefaultManager.Leave(old)
		statistic.DefaultManager.Leave(fresh)
	})
	old.onClose = func() {
		if !configMu.TryLock() {
			t.Error("connection close retained the config lock")
			return
		}
		defer configMu.Unlock()
		replacement := newLocalFallback(t, groupName, probeURL, outboundgroup.FallbackOption{},
			[]constant.Proxy{namedProxy("hy2"), namedProxy("reality")})
		tunnel.UpdateProxies(map[string]constant.Proxy{groupName: adapter.NewProxy(replacement)}, nil)
		_ = currentLineGroups()
		statistic.DefaultManager.Join(fresh)
	}
	statistic.DefaultManager.Join(old)
	checkLineMoves(watch)
	if !old.closed || fresh.closed {
		t.Fatalf("old closed = %v, new closed = %v; want only the failed stream closed", old.closed, fresh.closed)
	}
}
