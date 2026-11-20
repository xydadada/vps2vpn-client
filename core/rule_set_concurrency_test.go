package core

import (
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func TestRuleSetCompilationRejectsOverlappingWritesForTheSameName(t *testing.T) {
	withRuleSetHome(t)
	started, release := make(chan struct{}, 4), make(chan struct{})
	var calls atomic.Int32
	var once sync.Once
	unblock := func() { once.Do(func() { close(release) }) }
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		calls.Add(1)
		started <- struct{}{}
		<-release
		_, _ = w.Write([]byte("example.org\n"))
	}))
	defer server.Close()
	defer unblock()
	params := CompileRuleSetParams{Name: "same", URL: server.URL}
	done := make(chan error, 1)
	go func() { _, err := handleCompileRuleSet(params); done <- err }()
	select {
	case <-started:
	case <-time.After(time.Second):
		t.Fatal("first download did not start")
	}
	second := make(chan error, 1)
	go func() { _, err := handleCompileRuleSet(params); second <- err }()
	select {
	case err := <-second:
		if err == nil || asMethodError(err).Code != "rule_set_updating" {
			t.Fatalf("overlapping compilation result: %v", err)
		}
	case <-time.After(time.Second):
		unblock()
		<-second
		<-done
		t.Fatal("overlapping compilation entered the download")
	}
	unblock()
	if err := <-done; err != nil {
		t.Fatal(err)
	}
	if calls.Load() != 1 {
		t.Fatalf("duplicate download count: %d", calls.Load())
	}
	params.URL = ""
	if _, err := handleCompileRuleSet(params); err != nil {
		t.Fatalf("completed compilation retained its claim: %v", err)
	}
}

func TestRuleSetFileWritersDoNotDeleteEachOthersTemporaryFiles(t *testing.T) {
	path := filepath.Join(t.TempDir(), "rules")
	var wg sync.WaitGroup
	for i := 0; i < 8; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for j := 0; j < 10; j++ {
				if err := writeRuleSetFile(path, []byte("example.org\n")); err != nil {
					t.Error(err)
				}
			}
		}()
	}
	wg.Wait()
	if got, err := os.ReadFile(path); err != nil || string(got) != "example.org\n" {
		t.Fatalf("final file = %q, error %v", got, err)
	}
}
