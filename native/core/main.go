package main

/*
#include <stdlib.h>
*/
import "C"

import (
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/netip"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"time"
	"unsafe"

	mihomoHTTP "github.com/metacubex/http"
	"github.com/metacubex/mihomo/adapter"
	"github.com/metacubex/mihomo/component/process"
	"github.com/metacubex/mihomo/component/resolver"
	"github.com/metacubex/mihomo/component/updater"
	"github.com/metacubex/mihomo/config"
	"github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/hub/executor"
	"github.com/metacubex/mihomo/hub/route"
	LC "github.com/metacubex/mihomo/listener/config"
	"github.com/metacubex/mihomo/listener/sing_tun"
	"github.com/metacubex/mihomo/tunnel"
	"github.com/metacubex/mihomo/tunnel/statistic"
)

const controllerAddress = "127.0.0.1:9090"
const coreRevision = "8597778c7df410ebe88c57e59eaab32d203156df"

var lifecycleMu sync.Mutex
var tunListener *sing_tun.Listener
var currentConfig *config.Config
var controller *embeddedController

type embeddedController struct {
	server      *mihomoHTTP.Server
	done        chan struct{}
	connections sync.Map
}

// Every returned string belongs to the caller, including the empty success string.
//
//export HongFlowFree
func HongFlowFree(pointer unsafe.Pointer) { C.free(pointer) }

//export HongFlowVersion
func HongFlowVersion() *C.char {
	return C.CString("Mihomo / FlClash v0.8.99 / " + coreRevision[:12])
}

//export HongFlowValidate
func HongFlowValidate(content *C.char) *C.char {
	lifecycleMu.Lock()
	defer lifecycleMu.Unlock()
	summary, err := validateProfile([]byte(C.GoString(content)))
	if err != nil {
		return jsonString(map[string]any{"valid": false, "error": err.Error()})
	}
	return jsonString(summary)
}

func jsonString(value any) *C.char {
	encoded, _ := json.Marshal(value)
	return C.CString(string(encoded))
}

func validateProfile(content []byte) (map[string]any, error) {
	if len(content) == 0 {
		return nil, errors.New("配置内容为空")
	}
	raw, err := config.UnmarshalRawConfig(content)
	if err != nil {
		return nil, err
	}
	if len(raw.Proxy) == 0 && len(raw.ProxyProvider) == 0 {
		return nil, errors.New("配置未包含代理节点或代理提供者；请使用 Clash/Mihomo YAML 订阅")
	}
	// Check static names and routing references before replacing the saved YAML.
	// Full parsing is reserved for startup because it mutates globals and loads resources.
	if err := config.ValidateProfileReferences(raw); err != nil {
		return nil, err
	}
	for _, mapping := range raw.Proxy {
		// Validation must not overwrite a live peer resolver registered by these adapters.
		if mapping["type"] == "tailscale" || mapping["type"] == "easytier" {
			continue
		}
		proxy, parseErr := adapter.ParseProxy(mapping)
		if parseErr != nil {
			return nil, parseErr
		}
		_ = proxy.Close()
	}
	return map[string]any{
		"valid":     true,
		"proxies":   len(raw.Proxy),
		"groups":    len(raw.ProxyGroup),
		"rules":     len(raw.Rule),
		"providers": len(raw.ProxyProvider),
		"mode":      raw.Mode.String(),
	}, nil
}

// Start duplicates tunFd; the system VPN connection remains the owner's responsibility.
// All sockets must be excluded from VPN routing via protectProcessNet before this call.
//
//export HongFlowStart
func HongFlowStart(path, home *C.char, tunFd C.int, secret *C.char) *C.char {
	lifecycleMu.Lock()
	defer lifecycleMu.Unlock()
	return errorString(startCore(C.GoString(path), C.GoString(home), int(tunFd), C.GoString(secret)))
}

func errorString(err error) *C.char {
	if err == nil {
		return C.CString("")
	}
	return C.CString(err.Error())
}

func startCore(path, home string, tunFd int, secret string) error {
	if tunListener != nil {
		return errors.New("VPN 内核已启动")
	}
	if tunFd < 0 {
		return errors.New("系统 VPN 文件描述符无效")
	}
	if len(secret) < 24 {
		return errors.New("控制接口密钥长度不足")
	}
	if home == "" {
		return errors.New("内核数据目录为空")
	}
	if err := os.MkdirAll(home, 0700); err != nil {
		return err
	}
	constant.SetHomeDir(home)
	constant.SetConfig(path)
	content, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	raw, err := config.UnmarshalRawConfig(content)
	if err != nil {
		return err
	}

	// A subscription controls routing rules, not local listening sockets or privileged routes.
	raw.ExternalController = controllerAddress
	raw.Secret = secret
	raw.ExternalControllerTLS = ""
	raw.ExternalControllerUnix = ""
	raw.ExternalControllerPipe = ""
	raw.ExternalControllerRoutingMark = 0
	raw.ExternalUI = ""
	raw.ExternalUIURL = ""
	raw.ExternalDohServer = ""
	raw.ExternalControllerCors = config.RawCors{AllowOrigins: []string{}}
	raw.Interface = ""
	raw.RoutingMark = 0
	raw.FindProcessMode = process.FindProcessOff
	raw.AllowLan = false
	raw.BindAddress = "127.0.0.1"
	raw.Port = 0
	raw.SocksPort = 0
	raw.RedirPort = 0
	raw.TProxyPort = 0
	raw.MixedPort = 0
	raw.ShadowSocksConfig = ""
	raw.VmessConfig = ""
	raw.Listeners = nil
	raw.Tunnels = nil
	raw.TuicServer = config.RawTuicServer{}
	raw.IPTables = config.RawIPTables{}
	raw.Tun = config.RawTun{}
	raw.GeoAutoUpdate = false
	raw.NTP.Enable = false
	raw.DNS.Enable = true
	raw.DNS.Listen = ""
	// Local system DNS would resolve against the VPN itself. Explicit upstreams avoid that loop.
	if len(raw.DNS.NameServer) == 0 {
		raw.DNS.NameServer = []string{"https://1.1.1.1/dns-query", "https://223.5.5.5/dns-query"}
	}
	if len(raw.DNS.DefaultNameserver) == 0 {
		raw.DNS.DefaultNameserver = []string{"1.1.1.1", "223.5.5.5"}
	}
	// ArkTS owns selections by profile identity; the core cache uses global group names.
	raw.Profile.StoreSelected = false
	isolateProviderCache(raw, path)
	raw.Profile.StoreFakeIP = true
	parsed, err := config.ParseRawConfig(raw)
	if err != nil {
		return err
	}
	executor.ApplyConfig(parsed, true)
	currentConfig = parsed
	// The upstream loader logs provider download failures without returning them.
	// A provider-only profile must have actual nodes before it can report connected.
	if len(raw.Proxy) == 0 {
		available := false
		for name := range raw.ProxyProvider {
			if provider := parsed.Providers[name]; provider != nil && provider.Count() > 0 {
				available = true
				break
			}
		}
		if !available {
			stopCore()
			return errors.New("代理提供者未加载到可用节点，请检查订阅连接或缓存")
		}
	}
	if err = startController(secret); err != nil {
		stopCore()
		return err
	}

	// sing-tun consumes only the duplicate; the caller can destroy its VpnConnection separately.
	fd, err := syscall.Dup(tunFd)
	if err != nil {
		stopCore()
		return fmt.Errorf("复制 VPN 文件描述符失败: %w", err)
	}
	options := LC.Tun{
		Enable:              true,
		Device:              "HongFlow",
		Stack:               constant.TunMips,
		Inet4Address:        []netip.Prefix{netip.MustParsePrefix("198.18.0.1/30")},
		Inet6Address:        []netip.Prefix{netip.MustParsePrefix("fdfe:dcba:9876::1/126")},
		DNSHijack:           []string{"any:53", "tcp://any:53"},
		MTU:                 1500,
		FileDescriptor:      fd,
		AutoRoute:           false,
		AutoDetectInterface: false,
	}
	tunListener, err = sing_tun.New(options, tunnel.Tunnel)
	if err != nil {
		// In this fixed option set, no pre-tun validation can fail; sing-tun closes its owned fd on errors.
		stopCore()
		return fmt.Errorf("启动 TUN 网络栈失败: %w", err)
	}
	statistic.DefaultManager.ResetStatistic()
	return nil
}

func isolateProviderCache(raw *config.RawConfig, profilePath string) {
	// Subscriptions frequently reuse provider paths. Cache identity must include the
	// profile and URL so an offline switch cannot consume another subscription's nodes.
	for kind, providers := range map[string]map[string]map[string]any{"proxies": raw.ProxyProvider, "rules": raw.RuleProvider} {
		for name, mapping := range providers {
			if mapping["type"] != "http" {
				continue
			}
			key := sha256.Sum256([]byte(profilePath + "\x00" + kind + "\x00" + name + "\x00" + fmt.Sprint(mapping["url"])))
			mapping["path"] = filepath.Join("providers", kind, fmt.Sprintf("%x", key[:16])+".cache")
		}
	}
}

func startController(secret string) error {
	listener, err := net.Listen("tcp", controllerAddress)
	if err != nil {
		return fmt.Errorf("内核控制接口启动失败: %w", err)
	}
	owner := &embeddedController{done: make(chan struct{})}
	owner.server = &mihomoHTTP.Server{
		Handler:           route.NewEmbeddedHandler(secret),
		ReadHeaderTimeout: 5 * time.Second,
		ConnState: func(connection net.Conn, state mihomoHTTP.ConnState) {
			if state == mihomoHTTP.StateNew {
				owner.connections.Store(connection, struct{}{})
			}
			if state == mihomoHTTP.StateClosed {
				owner.connections.Delete(connection)
			}
			// Keep hijacked WebSocket connections until the owner explicitly stops them.
		},
	}
	controller = owner
	go func() { defer close(owner.done); _ = owner.server.Serve(listener) }()
	return nil
}

func stopController() {
	if controller == nil {
		return
	}
	owner := controller
	controller = nil
	_ = owner.server.Close()
	<-owner.done
	owner.connections.Range(func(connection, _ any) bool {
		_ = connection.(net.Conn).Close()
		return true
	})
}

// HongFlowSetMode uses Go HTTP so API 22 clients do not depend on the API 26 PATCH enum.
// It also works from the UI process while the core runs in the VPN extension process.
//
//export HongFlowSetMode
func HongFlowSetMode(mode, secret *C.char) *C.char {
	value := C.GoString(mode)
	if value != "rule" && value != "global" && value != "direct" {
		return errorString(errors.New("不支持的代理模式"))
	}
	token := C.GoString(secret)
	if len(token) < 24 {
		return errorString(errors.New("控制接口密钥长度不足"))
	}
	request, err := http.NewRequest(http.MethodPatch, "http://"+controllerAddress+"/configs", strings.NewReader(`{"mode":"`+value+`"}`))
	if err != nil {
		return errorString(err)
	}
	request.Header.Set("Content-Type", "application/json")
	request.Header.Set("Authorization", "Bearer "+token)
	client := &http.Client{Timeout: 5 * time.Second, Transport: &http.Transport{Proxy: nil}}
	defer client.CloseIdleConnections()
	response, err := client.Do(request)
	if err != nil {
		return errorString(fmt.Errorf("切换代理模式失败: %w", err))
	}
	defer response.Body.Close()
	body, _ := io.ReadAll(io.LimitReader(response.Body, 4096))
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		return errorString(fmt.Errorf("切换代理模式失败（HTTP %d）: %s", response.StatusCode, strings.TrimSpace(string(body))))
	}
	return errorString(nil)
}

//export HongFlowStop
func HongFlowStop() *C.char {
	lifecycleMu.Lock()
	defer lifecycleMu.Unlock()
	stopCore()
	return errorString(nil)
}

func stopCore() {
	stopController()
	tunnel.OnSuspend()
	if tunListener != nil {
		_ = tunListener.Close()
		tunListener = nil
	}
	statistic.DefaultManager.Range(func(connection statistic.Tracker) bool { _ = connection.Close(); return true })
	updater.StopGeoUpdater()
	executor.Shutdown()
	resolver.ResetConnection()
	if currentConfig != nil {
		for _, provider := range currentConfig.Providers {
			if closer, ok := provider.(io.Closer); ok {
				_ = closer.Close()
			}
		}
		for _, provider := range currentConfig.RuleProviders {
			if closer, ok := provider.(io.Closer); ok {
				_ = closer.Close()
			}
		}
		for _, proxy := range currentConfig.Proxies {
			_ = proxy.Close()
		}
		currentConfig = nil
	}
}

func main() {}
