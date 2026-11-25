package core

import (
	"errors"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync"

	"github.com/metacubex/mihomo/adapter"
	"github.com/metacubex/mihomo/adapter/inbound"
	"github.com/metacubex/mihomo/adapter/provider"
	"github.com/metacubex/mihomo/component/age"
	"github.com/metacubex/mihomo/component/auth"
	"github.com/metacubex/mihomo/component/dialer"
	"github.com/metacubex/mihomo/component/resolver"
	"github.com/metacubex/mihomo/config"
	"github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/hub"
	"github.com/metacubex/mihomo/hub/route"
	authStore "github.com/metacubex/mihomo/listener/auth"
	LC "github.com/metacubex/mihomo/listener/config"
	"github.com/metacubex/mihomo/log"
	"github.com/metacubex/mihomo/tunnel"
)

var (
	configMu      sync.Mutex
	currentConfig *config.Config

	errConfigNotApplied = errors.New("config is not applied")
	errNotInitialized   = errors.New("not initialized")
)

var setupConfig = applyConfig

func handleSetupConfig(params *SetupParams) error {
	if !isInit.Load() {
		return errNotInitialized
	}
	return setupConfig(params)
}

func handleReadConfig(params PathParams) (*config.RawConfig, error) {
	return readRawConfig(params.Path)
}

func readRawConfig(path string) (*config.RawConfig, error) {
	defer scheduleLoadMemoryRelease()
	buf, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	return unmarshalRawConfig(buf)
}

type proxyDefinitionCache struct {
	path      string
	proxies   map[string]map[string]any
	providers map[string]map[string]any
}

var (
	proxyDefsMu    sync.RWMutex
	proxyDefsCache *proxyDefinitionCache
)

func setProxyDefinitionCache(path string, raw *config.RawConfig) {
	if raw == nil {
		clearProxyDefinitionCache()
		return
	}
	proxies := make(map[string]map[string]any, len(raw.Proxy))
	for _, mapping := range raw.Proxy {
		if name, ok := mapping["name"].(string); ok && name != "" {
			if _, exists := proxies[name]; !exists {
				proxies[name] = mapping
			}
		}
	}
	providers := make(map[string]map[string]any, len(raw.ProxyProvider))
	for name, mapping := range raw.ProxyProvider {
		providers[name] = mapping
	}
	proxyDefsMu.Lock()
	proxyDefsCache = &proxyDefinitionCache{
		path:      path,
		proxies:   proxies,
		providers: providers,
	}
	proxyDefsMu.Unlock()
}

func clearProxyDefinitionCache() {
	proxyDefsMu.Lock()
	proxyDefsCache = nil
	proxyDefsMu.Unlock()
}

func handleGetProxyDefinition(params NameParams) (map[string]any, error) {
	name := params.Name
	path := runningConfigPath()
	proxyDefsMu.RLock()
	cache := proxyDefsCache
	proxyDefsMu.RUnlock()

	var proxies map[string]map[string]any
	var providers map[string]map[string]any
	if cache != nil && cache.path == path {
		proxies = cache.proxies
		providers = cache.providers
	} else {
		raw, err := readRawConfig(path)
		if err != nil {
			return nil, err
		}
		proxies = make(map[string]map[string]any, len(raw.Proxy))
		for _, mapping := range raw.Proxy {
			if proxyName, ok := mapping["name"].(string); ok && proxyName != "" {
				if _, exists := proxies[proxyName]; !exists {
					proxies[proxyName] = mapping
				}
			}
		}
		providers = raw.ProxyProvider
	}
	if proxy := lookupProxy(name); proxy != nil {
		if pdName := proxy.ProxyInfo().ProviderName; pdName != "" {
			pd, running := tunnel.ProvidersSnapshot()[pdName]
			mapping, declared := providers[pdName]
			if !running || !declared {
				return nil, nil
			}
			return provider.ProxyMapping(pd, mapping, name)
		}
	}
	return proxies[name], nil
}

func handleValidateConfig(params PathParams) *string {
	if _, err := readRawConfig(params.Path); err != nil {
		message := err.Error()
		return &message
	}
	return nil
}

func handleDecryptConfig(params DecryptConfigParams) (string, error) {
	buf, err := os.ReadFile(params.Path)
	if err != nil {
		return "", err
	}
	buf, err = age.DecryptBytes(buf, params.AgeSecretKey)
	if err != nil {
		return "", err
	}
	return string(buf), nil
}

// mihomo writes the NTP time with settimeofday, which Android's app seccomp
// policy answers by killing the process rather than with EPERM.
var systemTimeWritable = runtime.GOOS != "android"

func loadConfig(path string) (*config.Config, error) {
	cfg, _, err := loadConfigRaw(path)
	return cfg, err
}

func loadConfigRaw(path string) (*config.Config, *config.RawConfig, error) {
	buf, err := os.ReadFile(path)
	if err != nil {
		return nil, nil, err
	}
	raw, err := unmarshalRawConfig(buf)
	if err != nil {
		return nil, nil, err
	}
	// Custom and scripted profiles: the user wrote the rules, so no AI rules.
	vps2vpnEnhance(raw, -1)
	cfg, err := config.ParseRawConfig(raw)
	if err != nil {
		return nil, nil, err
	}
	return withPlatformLimits(cfg), raw, nil
}

func withPlatformLimits(cfg *config.Config) *config.Config {
	if cfg.NTP.WriteToSystem && !systemTimeWritable {
		log.Warnln("ntp write-to-system ignored: Android does not let apps set the system time")
		cfg.NTP.WriteToSystem = false
	}
	return cfg
}

func runningConfigPath() string {
	return filepath.Join(constant.Path.HomeDir(), "config.yaml")
}

func loadSetupConfig(params *SetupParams) (*config.Config, error) {
	cfg, _, err := loadSetupConfigWithRaw(params)
	return cfg, err
}

func loadSetupConfigWithRaw(params *SetupParams) (*config.Config, *config.RawConfig, error) {
	path := runningConfigPath()
	if params.Base != nil {
		return loadConfigWithBaseRaw(params.Base, path)
	}
	return loadConfigRaw(path)
}

func applyConfig(params *SetupParams) error {
	runtime.GC()
	configMu.Lock()
	defer configMu.Unlock()

	// SmartLines participates in profile parsing. Other global options must
	// only become active after the replacement config has passed validation.
	previousSmart := vpsSmartEnabled.Load()
	previousHighRate := vpsSmartHighRate.Load()
	vpsSmartEnabled.Store(params.Options.SmartLines)
	vpsSmartHighRate.Store(params.Options.SmartHighRate)
	previousStatus := vpsStoreLineStatus(params.Options.DownLines, params.Options.BusyLines)
	cfg, raw, err := loadSetupConfigWithRaw(params)
	if err != nil {
		vpsSmartEnabled.Store(previousSmart)
		vpsSmartHighRate.Store(previousHighRate)
		vpsLineStatus.Store(previousStatus)
		if currentConfig != nil {
			// An invalid replacement must not discard the last working route
			// graph or change the active TLS verification and probe options.
			logError("config apply rejected; retaining the running proxy graph: %v", err)
			return &MethodError{Code: "config_rejected", Message: err.Error()}
		}
		// A first startup has no working route graph to retain.
		logError("initial config apply rejected; loading the built-in default with no proxies: %v", err)
		defaultRaw := config.DefaultRawConfig()
		fallback, fallbackErr := config.ParseRawConfig(defaultRaw)
		if fallbackErr != nil {
			return err
		}
		cfg = fallback
		raw = defaultRaw
	}

	applyOptions(params.Options)
	currentConfig = cfg
	setProxyDefinitionCache(runningConfigPath(), raw)
	hub.ApplyConfig(cfg)
	patchSelectGroup(params.SelectedMap)
	startLineWatch()
	updateListeners(cfg)
	// After the listeners: a probe sent while the TUN is rebuilt carries the
	// older epoch, and its failure goes with it.
	bumpRouteEpoch()
	reconcileGeoUpdater()
	scheduleLoadMemoryRelease()
	if err != nil {
		// The host tells this apart from a call that failed: the default config runs.
		return &MethodError{Code: "config_rejected", Message: err.Error()}
	}
	return nil
}

func updateConfig(params *UpdateParams) error {
	configMu.Lock()
	defer configMu.Unlock()
	if currentConfig == nil {
		return errConfigNotApplied
	}

	general := currentConfig.General
	if params.MixedPort != nil {
		general.MixedPort = *params.MixedPort
	}
	if params.AllowLan != nil {
		general.AllowLan = *params.AllowLan
	}
	if params.FindProcessMode != nil {
		general.FindProcessMode = *params.FindProcessMode
		tunnel.SetFindProcessMode(general.FindProcessMode)
	}
	if params.TCPConcurrent != nil {
		general.TCPConcurrent = *params.TCPConcurrent
		dialer.SetTcpConcurrent(general.TCPConcurrent)
	}
	if params.UnifiedDelay != nil {
		general.UnifiedDelay = *params.UnifiedDelay
		adapter.UnifiedDelay.Store(general.UnifiedDelay)
	}
	routeChange := routeUnchanged
	if params.Mode != nil {
		if general.Mode != *params.Mode {
			routeChange = routeMoved
		}
		general.Mode = *params.Mode
		tunnel.SetMode(general.Mode)
	}
	if params.LogLevel != nil {
		general.LogLevel = *params.LogLevel
		log.SetLevel(general.LogLevel)
	}
	// Turning IPv6 on moves a direct dial to another exit address while the
	// route it takes stays the same.
	if params.IPv6 != nil {
		if general.IPv6 != *params.IPv6 {
			routeChange = routeReset
			general.IPv6 = *params.IPv6
			resolver.DisableIPv6 = !general.IPv6
		}
	}
	if params.Tun != nil {
		patchTun(&general.Tun, params.Tun)
	}
	patchController(params)
	if params.Authentication != nil {
		applyAuthentication(currentConfig, *params.Authentication)
	}
	if params.Options != nil {
		applyOptions(*params.Options)
	}

	updateListeners(currentConfig)
	for geoType, link := range params.GeoXUrl {
		setGeoResourceUrl(geoType, link)
	}
	syncGeoUpdater(params.GeoAutoUpdate, params.GeoUpdateInterval)
	if routeChange != routeUnchanged {
		changeRoute(routeChange)
	}
	return nil
}

func applyOptions(options CoreOptions) {
	setTestURL(options.TestURL)
	provider.SetDefaultTestTimeout(timeoutFromMillis(options.DelayTestTimeout, 0))
	skipCertVerify.Store(options.SkipCertVerify)
	vpsSmartEnabled.Store(options.SmartLines)
	vpsSmartHighRate.Store(options.SmartHighRate)
	vpsStoreLineStatus(options.DownLines, options.BusyLines)
}

func patchTun(target *LC.Tun, params *tunSchema) {
	target.Enable = params.Enable
	if params.AutoRoute != nil {
		target.AutoRoute = *params.AutoRoute
	}
	if params.Device != nil {
		target.Device = *params.Device
	}
	if params.Stack != nil {
		target.Stack = *params.Stack
	}
}

func routeConfig(cfg *config.Config) *route.Config {
	controller := cfg.Controller
	routeCfg := &route.Config{
		// No TLS, unix or pipe controller: mihomo serves the last two without
		// the secret, and the app uses none of them.
		Addr:        controller.ExternalController,
		RoutingMark: controller.ExternalControllerRoutingMark,
		Secret:      controller.Secret,
		DohServer:   controller.ExternalDohServer,
		IsDebug:     cfg.General.LogLevel == log.DEBUG,
		Cors: route.Cors{
			AllowOrigins:        controller.Cors.AllowOrigins,
			AllowPrivateNetwork: controller.Cors.AllowPrivateNetwork,
		},
	}
	if cfg.TLS != nil {
		routeCfg.Certificate = cfg.TLS.Certificate
		routeCfg.PrivateKey = cfg.TLS.PrivateKey
		routeCfg.ClientAuthType = cfg.TLS.ClientAuthType
		routeCfg.ClientAuthCert = cfg.TLS.ClientAuthCert
		routeCfg.EchKey = cfg.TLS.EchKey
	}
	return routeCfg
}

func patchController(params *UpdateParams) {
	controller := currentConfig.Controller
	address, secret := controller.ExternalController, controller.Secret
	if params.ExternalController != nil {
		address = *params.ExternalController
	}
	if params.Secret != nil {
		secret = *params.Secret
	}
	if address == controller.ExternalController && secret == controller.Secret {
		return
	}
	controller.ExternalController, controller.Secret = address, secret
	route.ReCreateServer(routeConfig(currentConfig))
}

func applyAuthentication(cfg *config.Config, authentication []string) {
	users := make([]auth.AuthUser, 0, len(authentication))
	for _, line := range authentication {
		if user, pass, found := strings.Cut(line, ":"); found {
			users = append(users, auth.AuthUser{User: user, Pass: pass})
		}
	}
	cfg.General.Authentication = authentication
	cfg.Users = users
	authStore.Default.SetAuthenticator(auth.NewAuthenticator(users))
	if len(users) > 0 {
		// A loopback exemption would let any local app bypass the credentials.
		cfg.General.SkipAuthPrefixes = nil
		inbound.SetSkipAuthPrefixes(nil)
	}
}
