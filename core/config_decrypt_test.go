package core

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"testing"

	"github.com/metacubex/mihomo/component/age"
)

func TestDecryptConfigBytesPreservePlaintextAndEmptyInput(t *testing.T) {
	for _, content := range []string{"", "proxies: []\n# 测试\n"} {
		got, err := handleDecryptConfig(DecryptConfigParams{Data: []byte(content)})
		if err != nil {
			t.Fatalf("decrypt supplied bytes: %v", err)
		}
		if got != content {
			t.Errorf("plaintext changed: got %q, want %q", got, content)
		}
	}
}

func TestDecryptConfigBytesDecryptAgeAndRejectWrongIdentity(t *testing.T) {
	secret, recipient, err := age.GenX25519KeyPair()
	if err != nil {
		t.Fatal(err)
	}
	const content = "proxies: []\n# encrypted fixture\n"
	encrypted, err := age.EncryptBytes([]byte(content), recipient)
	if err != nil {
		t.Fatal(err)
	}
	got, err := handleDecryptConfig(DecryptConfigParams{Data: encrypted, AgeSecretKey: secret})
	if err != nil || got != content {
		t.Fatalf("decrypt bytes = %q, %v; want original fixture", got, err)
	}
	otherSecret, _, err := age.GenX25519KeyPair()
	if err != nil {
		t.Fatal(err)
	}
	if _, err := handleDecryptConfig(DecryptConfigParams{Data: encrypted, AgeSecretKey: otherSecret}); err == nil {
		t.Fatal("encrypted data accepted a different identity")
	}
}

func TestDecryptConfigRejectsLegacyPathEvenWhenReadable(t *testing.T) {
	path := filepath.Join(t.TempDir(), "ordinary-fixture.yaml")
	const content = "fixture available only through the old path argument"
	if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
		t.Fatal(err)
	}
	for _, data := range [][]byte{nil, []byte("supplied bytes")} {
		result, err := handleDecryptConfig(DecryptConfigParams{Path: path, Data: data})
		var methodErr *MethodError
		if !errors.As(err, &methodErr) || methodErr.Code != "invalid_arguments" {
			t.Fatalf("legacy path error = %v, want invalid_arguments", err)
		}
		if result != "" {
			t.Fatalf("legacy path returned data: %q", result)
		}
	}
}

func TestDecryptConfigWireRequiresExplicitByteData(t *testing.T) {
	cases := []struct {
		name      string
		arguments string
		want      string
		valid     bool
	}{
		{name: "missing", arguments: "{}"},
		{name: "null", arguments: `{"data":null}`},
		{name: "legacy path", arguments: `{"path":"unused-fixture.yaml"}`},
		{name: "malformed base64", arguments: `{"data":"%%%invalid"}`},
		{name: "empty", arguments: `{"data":""}`, valid: true},
		{name: "base64 plaintext", arguments: `{"data":"cHJveGllczogW10K"}`, want: "proxies: []\n", valid: true},
	}
	handler := methodHandlers[configDecryptMethod]
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got, err := handler(&MethodCall{
				Method:    configDecryptMethod,
				Arguments: json.RawMessage(tc.arguments),
			})
			if tc.valid {
				if err != nil || got != tc.want {
					t.Fatalf("wire decrypt = %q, %v; want %q", got, err, tc.want)
				}
				return
			}
			var methodErr *MethodError
			if !errors.As(err, &methodErr) || methodErr.Code != "invalid_arguments" {
				t.Fatalf("wire error = %v, want invalid_arguments", err)
			}
		})
	}
}
