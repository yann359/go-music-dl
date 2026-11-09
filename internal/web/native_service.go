package web

import (
	"bytes"
	"context"
	"errors"
	"io"
	"net"
	"net/http"
	"sync"
	"sync/atomic"
	"time"

	"github.com/guohuiyuan/go-music-dl/core"
)

type nativeHandler struct{ http.Handler }

var nativeRoutes atomic.Pointer[nativeHandler]
var nativeServiceMu sync.Mutex
var nativeServiceStarting bool
var nativeServiceError error

// Called by the C ABI after sandbox paths have been configured. One owner
// initializes SQLite/queue; a timeout in a waiting caller does not poison it.
func EnsureNativeService(ctx context.Context, port string) error {
	nativeServiceMu.Lock()
	if nativeRoutes.Load() == nil && !nativeServiceStarting {
		nativeServiceStarting = true
		nativeServiceError = nil
		go func() {
			defer func() {
				nativeServiceMu.Lock()
				if r := recover(); r != nil {
					CloseDB() // clean only this failed initialization before retry
					nativeServiceError = errors.New("本地数据库初始化失败，请解锁设备后重试")
				}
				if nativeRoutes.Load() == nil && nativeServiceError == nil {
					nativeServiceError = errors.New("本地服务初始化未完成，请重试")
				}
				nativeServiceStarting = false
				nativeServiceMu.Unlock()
			}()
			StartWithOptions(port, StartOptions{DisableAuth: true, ListenHost: "127.0.0.1", Native: true})
		}()
	}
	nativeServiceMu.Unlock()
	ticker := time.NewTicker(50 * time.Millisecond)
	defer ticker.Stop()
	for {
		if nativeRoutes.Load() != nil {
			return nil
		}
		nativeServiceMu.Lock()
		err := nativeServiceError
		nativeServiceMu.Unlock()
		if err != nil {
			return err
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-ticker.C:
		}
	}
}

func serveNativeRoutes(handler http.Handler, queue *core.DownloadQueue, port string) {
	// SQLite and downloads stay alive independently of an optional TCP listener.
	ctx := context.Background()
	if err := queue.Start(ctx, processQueuedDownload); err != nil {
		return
	}
	nativeRoutes.Store(&nativeHandler{handler})
	// AI SSE remains loopback-only. Foreground data and audio never need it.
	go func() {
		for attempt := 0; attempt < 3; attempt++ {
			listener, err := net.Listen("tcp", "127.0.0.1:"+port)
			if err == nil {
				err = http.Serve(listener, handler)
				_ = listener.Close()
			}
			nativeTiming("optional-loopback", time.Now(), err)
			time.Sleep(time.Duration(attempt+1) * 250 * time.Millisecond)
		}
	}()
	// Lifetime owner, suspended by iOS normally; no background assertion/timer.
	select {}
}

// Bounded response buffering, shared route validation and write guards.
type nativeResponse struct {
	header   http.Header
	body     bytes.Buffer
	status   int
	overflow bool
}

func (r *nativeResponse) Header() http.Header { return r.header }
func (r *nativeResponse) WriteHeader(status int) {
	if r.status == 0 {
		r.status = status
	}
}
func (r *nativeResponse) Write(data []byte) (int, error) {
	if r.status == 0 {
		r.status = http.StatusOK
	}
	if r.body.Len()+len(data) > 16<<20 {
		r.overflow = true
		return 0, errors.New("native API response exceeds 16 MB")
	}
	return r.body.Write(data)
}
func performNativeRoute(handler http.Handler, request *http.Request) (*http.Response, error) {
	if request.URL.Scheme != "http" || request.URL.Host != "127.0.0.1:37777" {
		return nil, errors.New("invalid native route origin")
	}
	recorder := &nativeResponse{header: make(http.Header)}
	// Match server requests; several guards depend on the loopback peer.
	request.RemoteAddr = "127.0.0.1:1"
	handler.ServeHTTP(recorder, request)
	if recorder.overflow {
		return nil, errors.New("native API response exceeds 16 MB")
	}
	if recorder.status == 0 {
		recorder.status = http.StatusOK
	}
	return &http.Response{StatusCode: recorder.status, Header: recorder.header, Body: io.NopCloser(bytes.NewReader(recorder.body.Bytes()))}, nil
}
