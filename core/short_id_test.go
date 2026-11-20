package core

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestHandleGetConfigKeepsAnUnquotedShortIDAsWritten(t *testing.T) {
	profile := `proxies:
  - name: octal
    type: vless
    reality-opts: {public-key: k, short-id: 0123}
  - name: zeros
    type: vless
    reality-opts:
      short-id: 00
  - name: exponent
    type: vless
    reality-opts:
      short-id: 1e5
  - name: quoted
    type: vless
    reality-opts:
      short-id: "0189"
  - name: hex
    type: vless
    reality-opts:
      short-id: 0a1b
listeners:
  - name: in
    type: vless
    reality-config:
      short-id: [01234567, ""]
`
	path := filepath.Join(t.TempDir(), "profile.yaml")
	if err := os.WriteFile(path, []byte(profile), 0o600); err != nil {
		t.Fatalf("write profile: %v", err)
	}

	raw, err := readRawConfig(path)
	if err != nil {
		t.Fatalf("handleGetConfig = %v", err)
	}

	want := map[string]string{
		"octal":    "0123",
		"zeros":    "00",
		"exponent": "1e5",
		"quoted":   "0189",
		"hex":      "0a1b",
	}
	for _, proxy := range raw.Proxy {
		name := proxy["name"].(string)
		got := proxy["reality-opts"].(map[string]any)["short-id"]
		if got != want[name] {
			t.Errorf("%s short-id = %#v, want %q", name, got, want[name])
		}
	}
	ids := raw.Listeners[0]["reality-config"].(map[string]any)["short-id"].([]any)
	if ids[0] != "01234567" || ids[1] != "" {
		t.Errorf("listener short-id = %#v, want [01234567 \"\"]", ids)
	}
}

func TestHandleGetConfigLeavesProfilesWithoutShortIDsToMihomo(t *testing.T) {
	path := filepath.Join(t.TempDir(), "profile.yaml")
	if err := os.WriteFile(path, []byte("mixed-port: 7899\n"), 0o600); err != nil {
		t.Fatalf("write profile: %v", err)
	}

	raw, err := readRawConfig(path)
	if err != nil {
		t.Fatalf("handleGetConfig = %v", err)
	}
	if raw.MixedPort != 7899 || raw.Mode.String() == "" {
		t.Errorf("raw config = port %d mode %q, want 7899 and the default mode", raw.MixedPort, raw.Mode)
	}
}

func TestShortIDRetaggingRejectsAliasAmplification(t *testing.T) {
	var profile strings.Builder
	profile.WriteString("short-id: 0123\nx0: &v0 [value]\n")
	for i := 1; i <= 24; i++ {
		fmt.Fprintf(&profile, "x%d: &v%d [*v%d, *v%d]\n", i, i, i-1, i-1)
	}
	profile.WriteString("proxies: *v24\n")
	if _, err := unmarshalRawConfig([]byte(profile.String())); err == nil || !strings.Contains(err.Error(), "excessive YAML alias expansion") {
		t.Fatalf("retagging must reject alias amplification before decode: %v", err)
	}
}
