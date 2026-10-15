package main

import (
	"crypto/x509"
	"errors"
	"io"
	netHTTP "net/http"
	netTest "net/http/httptest"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"sync/atomic"
	"testing"

	"github.com/metacubex/http/httptest"
	"github.com/metacubex/mihomo/component/ca"
	"github.com/metacubex/mihomo/component/resolver"
	"github.com/metacubex/mihomo/config"
	"github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/hub/executor"
	"github.com/metacubex/mihomo/hub/route"
	"github.com/metacubex/mihomo/tunnel"
)

func TestEmbeddedCARootsKeepStrictValidationWithoutSystemStore(t *testing.T) {
	oldSystem, oldEmbed := ca.DisableSystemCa, ca.DisableEmbedCa
	ca.DisableSystemCa, ca.DisableEmbedCa = true, false
	ca.ResetCertificate()
	t.Cleanup(func() {
		ca.DisableSystemCa, ca.DisableEmbedCa = oldSystem, oldEmbed
		ca.ResetCertificate()
	})
	// OHOS cannot use Go's Linux CA paths. This proves the built-in pool alone
	// contains the pinned Mozilla roots, with ordinary chain verification enabled.
	if got := len(ca.GetCertPool().Subjects()); got != 121 {
		t.Fatalf("expected 121 embedded Mozilla roots without system CA, got %d", got)
	}
	tlsConfig, err := ca.GetTLSConfig(ca.Option{})
	if err != nil || tlsConfig.InsecureSkipVerify || tlsConfig.RootCAs == nil {
		t.Fatalf("strict TLS configuration unavailable: %v", err)
	}
	server := netTest.NewTLSServer(netHTTP.HandlerFunc(func(netHTTP.ResponseWriter, *netHTTP.Request) {}))
	defer server.Close()
	_, err = server.Certificate().Verify(x509.VerifyOptions{Roots: tlsConfig.RootCAs})
	var untrusted x509.UnknownAuthorityError
	if !errors.As(err, &untrusted) {
		t.Fatalf("untrusted certificate was not rejected: %v", err)
	}
}

func TestValidateClashProfile(t *testing.T) {
	summary, err := validateProfile([]byte(`proxies:
  - name: node
    type: ss
    server: 127.0.0.1
    port: 12345
    cipher: aes-128-gcm
    password: password
proxy-groups:
  - name: select
    type: select
    proxies: [node, DIRECT]
rules:
  - MATCH,select
`))
	if err != nil {
		t.Fatal(err)
	}
	if summary["valid"] != true || summary["proxies"] != 1 || summary["groups"] != 1 || summary["rules"] != 1 {
		t.Fatalf("unexpected summary: %#v", summary)
	}
}

func TestRejectInvalidProfiles(t *testing.T) {
	for _, content := range []string{"", "proxies: invalid", "dns: {enable: true}", "proxies: [{name: node, type: unsupported}]"} {
		if _, err := validateProfile([]byte(content)); err == nil {
			t.Fatalf("accepted invalid profile: %q", content)
		}
	}
}

func TestRejectInvalidProfileReferences(t *testing.T) {
	const node = "proxies:\n  - {name: node, type: ss, server: 127.0.0.1, port: 12345, cipher: aes-128-gcm, password: password}\n"
	for _, test := range []struct {
		name, content, want string
	}{
		{"missing group member", node + "proxy-groups:\n  - {name: select, type: select, proxies: [missing]}\n", "'missing' not found"},
		{"missing rule target", node + "rules:\n  - MATCH,missing\n", "proxy [missing] not found"},
		{"invalid provider type", "proxy-providers:\n  remote: {type: nonsense}\n", "unsupport vehicle type"},
		{"duplicate proxy and group", node + "proxy-groups:\n  - {name: node, type: select, proxies: [DIRECT]}\n", "duplicate name"},
		{"duplicate proxies", "proxies:\n  - {name: node, type: direct}\n  - {name: node, type: direct}\n", "duplicate name"},
		{"missing provider", node + "proxy-groups:\n  - {name: select, type: select, use: [missing]}\n", "provider 'missing' not found"},
		{"group cycle", node + "proxy-groups:\n  - {name: first, type: select, proxies: [second]}\n  - {name: second, type: select, proxies: [first]}\n", "loop is detected"},
		{"missing sub-rule", node + "rules:\n  - SUB-RULE,(NETWORK,TCP),missing\n", "sub-rule [missing] not found"},
		{"invalid sub-rule target", node + "sub-rules:\n  local:\n    - MATCH,missing\n", "proxy [missing] not found"},
		{"sub-rule cycle", node + "sub-rules:\n  first:\n    - SUB-RULE,(NETWORK,TCP),second\n  second:\n    - SUB-RULE,(NETWORK,TCP),first\n", "circular references"},
		{"nested missing rule provider", node + "rules:\n  - AND,((NETWORK,TCP),(RULE-SET,missing)),DIRECT\n", "rule set [missing] not found"},
		{"invalid group type", node + "proxy-groups:\n  - {name: select, type: nonsense, proxies: [node]}\n", "unsupported type"},
		{"empty group", node + "proxy-groups:\n  - {name: select, type: select}\n", "`use` or `proxies` missing"},
		{"empty include-all providers", node + "proxy-groups:\n  - {name: select, type: select, include-all-providers: true, use: [ignored]}\n", "`use` or `proxies` missing"},
		{"invalid expected status", node + "proxy-groups:\n  - {name: select, type: select, proxies: [node], expected-status: invalid}\n", "invalid"},
		{"invalid group filter", node + "proxy-groups:\n  - {name: select, type: select, include-all-proxies: true, filter: '['}\n", "invalid filter"},
		{"invalid group exclude filter", node + "proxy-groups:\n  - {name: select, type: select, proxies: [node], exclude-filter: '['}\n", "invalid filter"},
		{"invalid load-balance strategy", node + "proxy-groups:\n  - {name: select, type: load-balance, proxies: [node], strategy: nonsense}\n", "unsupported strategy"},
		{"implicit GLOBAL unavailable to groups", node + "proxy-groups:\n  - {name: select, type: select, proxies: [GLOBAL]}\n", "'GLOBAL' not found"},
		{"group and provider collision", node + "proxy-providers:\n  same: {type: http, url: https://example.invalid/provider}\nproxy-groups:\n  - {name: same, type: select, proxies: [node]}\n", "duplicate provider name"},
		{"include-all group and provider collision", node + "proxy-providers:\n  same: {type: http, url: https://example.invalid/provider}\nproxy-groups:\n  - {name: same, type: select, include-all: true}\n", "duplicate provider name"},
		{"filtered fallback provider collision", node + "proxy-providers:\n  same: {type: http, url: https://example.invalid/provider}\nproxy-groups:\n  - {name: same, type: select, include-all-proxies: true, filter: '^absent$'}\n", "duplicate provider name"},
	} {
		t.Run(test.name, func(t *testing.T) {
			if _, err := validateProfile([]byte(test.content)); err == nil || !strings.Contains(err.Error(), test.want) {
				t.Fatalf("expected %q, got %v", test.want, err)
			}
		})
	}
}

func TestValidateProfileReferenceBoundaries(t *testing.T) {
	for _, test := range []struct {
		name, content string
	}{
		{"built-in targets and implicit GLOBAL", `proxies: [{name: node, type: direct}]
rules:
  - DOMAIN,one.example,DIRECT
  - DOMAIN,two.example,REJECT
  - DOMAIN,three.example,REJECT-DROP
  - DOMAIN,four.example,COMPATIBLE
  - DOMAIN,five.example,PASS
  - DOMAIN,six.example,PASS-RULE
  - MATCH,GLOBAL
`},
		{"explicit GLOBAL and include-all proxies", `proxies: [{name: node, type: direct}]
proxy-groups:
  - {name: GLOBAL, type: select, include-all-proxies: true}
rules: ["MATCH,GLOBAL"]
`},
		{"explicit GLOBAL referenced by another group", `proxies: [{name: node, type: direct}]
proxy-groups:
  - {name: select, type: select, proxies: [GLOBAL]}
  - {name: GLOBAL, type: select, proxies: [node]}
rules: ["MATCH,select"]
`},
		{"all group types and filtered empty fallback", `proxies: [{name: node, type: direct}]
proxy-groups:
  - {name: select, type: select, include-all-proxies: true, filter: '^absent$', empty-fallback: DIRECT}
  - {name: urltest, type: url-test, proxies: [node], expected-status: '200/204', tolerance: 50}
  - {name: fallback, type: fallback, proxies: [node], exclude-filter: '^absent$'}
  - {name: balance, type: load-balance, proxies: [node], strategy: sticky-sessions, hash-key: in-user}
rules: ["MATCH,select"]
`},
		{"dynamic provider with include-all override", `proxy-providers:
  remote: {type: http, url: "https://example.invalid/proxies.yaml"}
proxy-groups:
  - {name: all, type: select, include-all: true, use: [ignored]}
  - {name: providers, type: select, include-all-providers: true, use: [ignored]}
rules: ["MATCH,all"]
`},
		{"local and inline providers", `proxy-providers:
  local: {type: file, path: providers/local.yaml}
  inline:
    type: inline
    payload: [{name: node, type: direct}]
proxy-groups:
  - {name: select, type: select, use: [local, inline]}
rules: ["MATCH,select"]
`},
		{"use-only group sharing provider name", `proxy-providers:
  same: {type: http, url: "https://example.invalid/provider"}
proxy-groups:
  - {name: same, type: select, use: [same]}
rules: ["MATCH,same"]
`},
		{"filtered include-all group sharing provider name", `proxies: [{name: node, type: direct}]
proxy-providers:
  same: {type: http, url: "https://example.invalid/provider"}
proxy-groups:
  - {name: same, type: select, include-all: true, filter: '^absent$'}
rules: ["MATCH,same"]
`},
		{"filtered include-all-proxies retains explicit provider", `proxies: [{name: node, type: direct}]
proxy-providers:
  same: {type: http, url: "https://example.invalid/provider"}
proxy-groups:
  - {name: same, type: select, include-all-proxies: true, filter: '^absent$', use: [same]}
rules: ["MATCH,same"]
`},
		{"node may share a provider name", `proxies: [{name: same, type: direct}]
proxy-providers:
  same: {type: http, url: "https://example.invalid/provider"}
proxy-groups:
  - {name: select, type: select, proxies: [same], use: [same]}
rules: ["MATCH,select"]
`},
		{"nested rule providers and sub-rules", `proxies: [{name: node, type: direct}]
rule-providers:
  domains: {type: http, behavior: domain, url: "https://example.invalid/rules.yaml"}
rules:
  - SUB-RULE,(NETWORK,TCP),local
  - MATCH,COMPATIBLE
sub-rules:
  local:
    - AND,((NETWORK,TCP),(RULE-SET,domains)),node
    - GEOSITE,cn,DIRECT
    - GEOIP,CN,DIRECT
    - MATCH,REJECT
`},
	} {
		t.Run(test.name, func(t *testing.T) {
			if _, err := validateProfile([]byte(test.content)); err != nil {
				t.Fatal(err)
			}
			// Compare local schema boundaries with the actual startup parser. Geo
			// loading is intentionally kept in the separate offline-only case.
			if !strings.Contains(test.content, "GEOSITE") {
				constant.SetHomeDir(t.TempDir())
				raw, err := config.UnmarshalRawConfig([]byte(test.content))
				if err != nil {
					t.Fatal(err)
				}
				parsed, err := config.ParseRawConfig(raw)
				if err != nil {
					t.Fatalf("static validation diverged from startup: %v", err)
				}
				for _, provider := range parsed.Providers {
					if closer, ok := provider.(io.Closer); ok {
						_ = closer.Close()
					}
				}
				for _, proxy := range parsed.Proxies {
					_ = proxy.Close()
				}
			}
		})
	}
}

func TestValidationPreservesLiveCoreAndDoesNotLoadResources(t *testing.T) {
	constant.SetHomeDir(t.TempDir())
	raw, err := config.UnmarshalRawConfig([]byte("proxies: [{name: active, type: direct}]\nmode: direct\ndns: {enable: true, nameserver: [1.1.1.1]}\nrules: [\"MATCH,active\"]\n"))
	if err != nil {
		t.Fatal(err)
	}
	parsed, err := config.ParseRawConfig(raw)
	if err != nil {
		t.Fatal(err)
	}
	executor.ApplyConfig(parsed, true)
	currentConfig = parsed
	t.Cleanup(stopCore)
	beforeNames := append([]string(nil), config.GetProxyNameList()...)
	beforeResolver, beforeMode, beforeStatus := resolver.DefaultResolver, tunnel.Mode(), tunnel.Status()
	var requests atomic.Int32
	source := netTest.NewServer(netHTTP.HandlerFunc(func(w netHTTP.ResponseWriter, r *netHTTP.Request) {
		requests.Add(1)
		w.WriteHeader(503)
	}))
	defer source.Close()
	content := "mode: global\nproxy-providers:\n  remote: {type: http, url: " + source.URL + "}\nproxy-groups:\n  - {name: select, type: select, use: [remote]}\n  - {name: test, type: url-test, use: [remote], url: " + source.URL + ", interval: 1}\n  - {name: fallback, type: fallback, use: [remote], url: " + source.URL + "}\n  - {name: balance, type: load-balance, use: [remote], strategy: sticky-sessions}\nrule-providers:\n  domains: {type: http, behavior: domain, url: " + source.URL + "}\ngeox-url:\n  geoip: " + source.URL + "\n  geosite: " + source.URL + "\nrules:\n  - RULE-SET,domains,select\n  - GEOSITE,cn,DIRECT\n  - GEOIP,CN,DIRECT\n  - MATCH,select\n"
	if _, err := validateProfile([]byte(content)); err != nil {
		t.Fatal(err)
	}
	if _, err := validateProfile([]byte(strings.Replace(content, "MATCH,select", "MATCH,missing", 1))); err == nil {
		t.Fatal("invalid candidate passed validation")
	}
	if requests.Load() != 0 {
		t.Fatal("validation fetched provider or Geo resources")
	}
	if currentConfig != parsed || tunnel.Tunnel.Proxies()["active"] != parsed.Proxies["active"] ||
		resolver.DefaultResolver != beforeResolver || tunnel.Mode() != beforeMode || tunnel.Status() != beforeStatus ||
		!reflect.DeepEqual(config.GetProxyNameList(), beforeNames) {
		t.Fatal("validation changed the active configuration")
	}
	for _, name := range []string{"GeoSite.dat", "GeoIP.dat", "country.mmdb", "providers", "rules", "proxies"} {
		if _, err := os.Stat(filepath.Join(constant.Path.HomeDir(), name)); !os.IsNotExist(err) {
			t.Fatalf("validation created resource %s: %v", name, err)
		}
	}
}

func TestAcceptProviderProfile(t *testing.T) {
	summary, err := validateProfile([]byte(`proxy-providers:
  provider:
    type: http
    url: https://example.com/proxies.yaml
    path: provider.yaml
proxy-groups:
  - name: select
    type: select
    use: [provider]
rules:
  - MATCH,select
`))
	if err != nil {
		t.Fatal(err)
	}
	if summary["providers"] != 1 || summary["proxies"] != 0 {
		t.Fatalf("unexpected summary: %#v", summary)
	}
}

func TestProviderCachesAreScopedToProfileAndURL(t *testing.T) {
	first, _ := config.UnmarshalRawConfig([]byte(`proxy-providers:
  airport: {type: http, path: provider.yaml, url: https://example.com/a}
rule-providers:
  rules: {type: http, behavior: domain, path: rules.yaml, url: https://example.com/rules}
  local: {type: file, behavior: domain, path: local.yaml}
`))
	second, _ := config.UnmarshalRawConfig([]byte(`proxy-providers:
  airport: {type: http, path: provider.yaml, url: https://example.com/a}
`))
	isolateProviderCache(first, "/profiles/first.yaml")
	isolateProviderCache(second, "/profiles/second.yaml")
	if first.ProxyProvider["airport"]["path"] == second.ProxyProvider["airport"]["path"] {
		t.Fatal("profiles share a provider cache")
	}
	before := first.ProxyProvider["airport"]["path"]
	first.ProxyProvider["airport"]["url"] = "https://example.com/b"
	isolateProviderCache(first, "/profiles/first.yaml")
	if first.ProxyProvider["airport"]["path"] == before {
		t.Fatal("URLs share a provider cache")
	}
	if first.RuleProvider["local"]["path"] != "local.yaml" {
		t.Fatal("local provider path changed")
	}
}

func TestEmbeddedControllerAllowsOnlyAuthenticatedModeChange(t *testing.T) {
	secret := "hongflow-test-secret-0123456789"
	server := httptest.NewServer(route.NewEmbeddedHandler(secret))
	defer server.Close()
	for _, test := range []struct {
		method, path, token, body string
		expected                  int
	}{
		{"PATCH", "/configs", "", `{"mode":"global"}`, 401},
		{"PATCH", "/configs", secret, `{"mode":"global"}`, 204},
		{"PATCH", "/configs", secret, `{"mode":"unsupported"}`, 400},
		{"PUT", "/configs", secret, `{"payload":"invalid"}`, 405},
	} {
		request, _ := netHTTP.NewRequest(test.method, server.URL+test.path, strings.NewReader(test.body))
		request.Header.Set("Authorization", "Bearer "+test.token)
		request.Header.Set("Content-Type", "application/json")
		response, err := netHTTP.DefaultClient.Do(request)
		if err != nil {
			t.Fatal(err)
		}
		response.Body.Close()
		if response.StatusCode != test.expected {
			t.Fatalf("%s %s: expected %d, got %d", test.method, test.path, test.expected, response.StatusCode)
		}
	}
	if tunnel.Mode() != tunnel.Global {
		t.Fatalf("mode change did not reach tunnel: %v", tunnel.Mode())
	}
	tunnel.SetMode(tunnel.Rule)
}

func TestHTTPProviderInitializationCompletesBeforeApplyReturns(t *testing.T) {
	var requested atomic.Bool
	source := netTest.NewServer(netHTTP.HandlerFunc(func(w netHTTP.ResponseWriter, r *netHTTP.Request) {
		requested.Store(true)
		_, _ = w.Write([]byte("proxies:\n  - name: remote-node\n    type: ss\n    server: 127.0.0.1\n    port: 12345\n    cipher: aes-128-gcm\n    password: test-fixture\n"))
	}))
	defer source.Close()
	home := t.TempDir()
	constant.SetHomeDir(home)
	raw, err := config.UnmarshalRawConfig([]byte("proxy-providers:\n  remote:\n    type: http\n    url: " + source.URL + "\nproxy-groups:\n  - name: select\n    type: select\n    use: [remote]\nrules:\n  - MATCH,select\n"))
	if err != nil {
		t.Fatal(err)
	}
	parsed, err := config.ParseRawConfig(raw)
	if err != nil {
		t.Fatal(err)
	}
	executor.ApplyConfig(parsed, true)
	currentConfig = parsed
	defer stopCore()
	if !requested.Load() || parsed.Providers["remote"].Count() != 1 {
		t.Fatal("ApplyConfig returned before the HTTP provider loaded its node")
	}
}

func TestProviderOnlyFailureDoesNotKeepCoreRunning(t *testing.T) {
	for _, test := range []struct {
		name   string
		status int
		body   string
	}{
		{"HTTP503", 503, "unavailable"},
		{"EmptyHTTP200", 200, "proxies: []\n"},
	} {
		t.Run(test.name, func(t *testing.T) {
			t.Cleanup(stopCore)
			var requested atomic.Bool
			source := netTest.NewServer(netHTTP.HandlerFunc(func(w netHTTP.ResponseWriter, r *netHTTP.Request) {
				requested.Store(true)
				w.WriteHeader(test.status)
				_, _ = w.Write([]byte(test.body))
			}))
			defer source.Close()
			home := t.TempDir()
			path := filepath.Join(home, "profile.yaml")
			content := "proxy-providers:\n  remote:\n    type: http\n    url: " + source.URL + "\nproxy-groups:\n  - name: select\n    type: select\n    use: [remote]\nrules:\n  - MATCH,select\n"
			if err := os.WriteFile(path, []byte(content), 0600); err != nil {
				t.Fatal(err)
			}
			read, write, err := os.Pipe()
			if err != nil {
				t.Fatal(err)
			}
			defer read.Close()
			defer write.Close()
			lifecycleMu.Lock()
			err = startCore(path, home, int(read.Fd()), "hongflow-test-secret-0123456789")
			lifecycleMu.Unlock()
			if err == nil || !strings.Contains(err.Error(), "代理提供者未加载") {
				t.Fatalf("unexpected start result: %v", err)
			}
			if !requested.Load() {
				t.Fatal("startup rejected the provider before its actual HTTP failure")
			}
			if currentConfig != nil || tunListener != nil || controller != nil || tunnel.Status() != tunnel.Suspend {
				t.Fatal("failed startup kept native resources active")
			}
			if _, err := read.Stat(); err != nil {
				t.Fatalf("caller fd was closed: %v", err)
			}
		})
	}
}
