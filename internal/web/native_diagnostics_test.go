package web

import (
	"errors"
	"io"
	"log"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"
)

func TestNativeDiagnosticBodyPreservesEOF(t *testing.T) {
	body := &nativeDiagnosticBody{ReadCloser: io.NopCloser(strings.NewReader("complete response")), start: time.Now()}
	buffer := make([]byte, 64)
	n, err := body.Read(buffer)
	if n != len("complete response") || err != nil {
		t.Fatalf("first read=%d,%v", n, err)
	}
	n, err = body.Read(buffer)
	if n != 0 || !errors.Is(err, io.EOF) {
		t.Fatalf("completed body must return EOF, got %d,%v", n, err)
	}
}

type stalledNativeLog struct {
	entered chan struct{}
	release chan struct{}
	once    sync.Once
}

func (w *stalledNativeLog) Write(p []byte) (int, error) {
	w.once.Do(func() { close(w.entered) })
	<-w.release
	return len(p), nil
}

func TestNativeHTTPDiagnosticsCannotBlockNetworkOnSlowLogSink(t *testing.T) {
	// XCTest/embedded hosts may stop draining stderr. Diagnostics must never
	// make a healthy socket or its source slot wait for that logging pipe.
	previousWriter, previousEnabled := log.Writer(), nativeDiagnostics.Load()
	writer := &stalledNativeLog{entered: make(chan struct{}), release: make(chan struct{})}
	log.SetOutput(writer)
	nativeDiagnostics.Store(true)
	t.Cleanup(func() { close(writer.release); log.SetOutput(previousWriter); nativeDiagnostics.Store(previousEnabled) })
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) { _, _ = io.WriteString(w, "healthy") }))
	defer server.Close()
	transport := &http.Transport{}
	defer transport.CloseIdleConnections()
	client := &http.Client{Transport: nativeDiagnosticTransport{base: transport}, Timeout: 500 * time.Millisecond}
	done := make(chan error, 1)
	go func() {
		response, err := client.Get(server.URL)
		if err == nil {
			_, err = io.ReadAll(response.Body)
			_ = response.Body.Close()
		}
		done <- err
	}()
	select {
	case err := <-done:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(time.Second):
		t.Fatal("diagnostic log sink blocked an otherwise healthy HTTP request")
	}
	select {
	case <-writer.entered:
	case <-time.After(time.Second):
		t.Fatal("diagnostic path was not exercised")
	}
}
