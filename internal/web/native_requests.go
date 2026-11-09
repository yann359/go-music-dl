package web

import (
	"context"
	"crypto/sha256"
	"crypto/tls"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/http/httptrace"
	"sync"
	"sync/atomic"
	"time"

	"github.com/guohuiyuan/go-music-dl/core"
)

func nativeProviderKey(action, source string) string {
	// A request started under previous credentials cannot satisfy a new login.
	fingerprint := sha256.Sum256([]byte(core.CM.Get(source)))
	return fmt.Sprintf("%s:%s:%x", action, source, fingerprint[:8])
}

// The upstream library has no context API (its HTTP timeout is two minutes).
// Keep its slot AND single-flight entry until it really exits, even after the
// caller's deadline. Retrying must not create unlimited abandoned requests.
type nativeCall struct {
	done  chan struct{}
	value interface{}
	err   error
}
type nativeCallPool struct {
	mu     sync.Mutex
	active map[string]*nativeCall
	slots  chan struct{}
}

func newNativeCallPool(limit int) *nativeCallPool {
	return &nativeCallPool{active: make(map[string]*nativeCall), slots: make(chan struct{}, limit)}
}
func (p *nativeCallPool) run(ctx context.Context, key string, fn func() (interface{}, error)) (interface{}, error) {
	start := time.Now()
	p.mu.Lock()
	call := p.active[key]
	p.mu.Unlock()
	if call == nil {
		select {
		case p.slots <- struct{}{}:
		case <-ctx.Done():
			nativeTiming("queue-deadline "+key, start, ctx.Err())
			return nil, ctx.Err()
		}
		p.mu.Lock()
		call = p.active[key]
		if call == nil {
			call = &nativeCall{done: make(chan struct{})}
			p.active[key] = call
			go func(c *nativeCall) {
				start := time.Now()
				defer func() {
					if r := recover(); r != nil {
						c.err = fmt.Errorf("provider panic: %v", r)
					}
					nativeTiming("provider "+key, start, c.err)
					p.mu.Lock()
					delete(p.active, key)
					close(c.done)
					p.mu.Unlock()
					<-p.slots
				}()
				c.value, c.err = fn()
			}(call)
		} else {
			<-p.slots
		}
		p.mu.Unlock()
	}
	select {
	case <-call.done:
		return call.value, call.err
	case <-ctx.Done():
		nativeTiming("caller-deadline "+key, start, ctx.Err())
		return nil, ctx.Err()
	}
}

var nativeDiscoveryCalls = newNativeCallPool(3)
var nativeLyricCalls = newNativeCallPool(3)
var nativeDiagnostics atomic.Bool
var nativeDiagnosticsOnce sync.Once

func nativeTiming(stage string, start time.Time, err error) {
	if nativeDiagnostics.Load() {
		log.Printf("[native-timing] %s elapsed=%s error=%v", stage, time.Since(start), err)
	}
}

// Enabled only by the native DEBUG build. Never log signed URLs, cookies or bodies.
func enableNativeDiagnostics() {
	nativeDiagnosticsOnce.Do(func() {
		http.DefaultTransport = nativeDiagnosticTransport{base: http.DefaultTransport}
	})
	nativeDiagnostics.Store(true)
}

type nativeDiagnosticTransport struct{ base http.RoundTripper }

func (t nativeDiagnosticTransport) RoundTrip(req *http.Request) (*http.Response, error) {
	if !nativeDiagnostics.Load() {
		return t.base.RoundTrip(req)
	}
	start := time.Now()
	var mu sync.Mutex
	stages := map[string]time.Time{}
	begin := func(stage string) { mu.Lock(); stages[stage] = time.Now(); mu.Unlock() }
	end := func(stage string, err error) {
		mu.Lock()
		since := stages[stage]
		mu.Unlock()
		if !since.IsZero() {
			nativeTiming(req.URL.Hostname()+" "+stage, since, err)
		}
	}
	trace := &httptrace.ClientTrace{
		TLSHandshakeStart: func() { begin("tls") },
		TLSHandshakeDone:  func(_ tls.ConnectionState, err error) { end("tls", err) },
		DNSStart:          func(httptrace.DNSStartInfo) { begin("dns") },
		DNSDone:           func(v httptrace.DNSDoneInfo) { end("dns", v.Err) },
		ConnectStart:      func(_, addr string) { begin("connect " + addr) },
		ConnectDone:       func(_, addr string, err error) { end("connect "+addr, err) },
		GotConn: func(v httptrace.GotConnInfo) {
			log.Printf("[native-timing] %s reused=%t", req.URL.Hostname(), v.Reused)
		},
		GotFirstResponseByte: func() { nativeTiming(req.URL.Hostname()+" first-byte", start, nil) },
	}
	resp, err := t.base.RoundTrip(req.WithContext(httptrace.WithClientTrace(req.Context(), trace)))
	nativeTiming(req.URL.Hostname()+" headers", start, err)
	if resp != nil && resp.Body != nil {
		resp.Body = &nativeDiagnosticBody{ReadCloser: resp.Body, host: req.URL.Hostname(), start: time.Now()}
	}
	return resp, err
}

type nativeDiagnosticBody struct {
	io.ReadCloser
	host  string
	start time.Time
	bytes int64
}

func (b *nativeDiagnosticBody) Read(p []byte) (int, error) {
	n, err := b.ReadCloser.Read(p)
	b.bytes += int64(n)
	if err != nil {
		if errors.Is(err, io.EOF) {
			err = nil
		}
		nativeTiming(fmt.Sprintf("%s body bytes=%d", b.host, b.bytes), b.start, err)
	}
	return n, err
}
