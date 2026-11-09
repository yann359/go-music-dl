package web

import (
	"context"
	"errors"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/guohuiyuan/go-music-dl/core"
	"github.com/guohuiyuan/music-lib/model"
)

// A subprocess owns the process-scoped DB/queue, so normal tests and user data
// are never attached to or closed by this real initialization regression.
func TestNativeServiceActualStartupWithoutLoopback(t *testing.T) {
	if os.Getenv("MUSICDL_SERVICE_CHILD") != "1" {
		ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
		defer cancel()
		command := exec.CommandContext(ctx, os.Args[0], "-test.run=^TestNativeServiceActualStartupWithoutLoopback$", "-test.v")
		command.Env = append(os.Environ(), "MUSICDL_SERVICE_CHILD=1", "MUSICDL_SERVICE_ROOT="+t.TempDir())
		output, err := command.CombinedOutput()
		if err != nil {
			t.Fatalf("native startup child: %v\n%s", err, output)
		}
		t.Logf("actual native initialization, occupied loopback, SQLite roundtrip: passed")
		return
	}
	root := os.Getenv("MUSICDL_SERVICE_ROOT")
	if root == "" {
		t.Fatal("missing isolated root")
	}
	t.Chdir(root)
	t.Setenv("MUSIC_DL_CONFIG_DB", filepath.Join(root, "settings.db"))
	t.Setenv("MUSIC_DL_COOKIE_FILE", filepath.Join(root, "cookies.json"))
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = listener.Close() }()
	_, port, err := net.SplitHostPort(listener.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	blocked := filepath.Join(root, "blocked")
	if err := os.WriteFile(blocked, []byte("fixture"), 0600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("MUSIC_DL_CONFIG_DB", filepath.Join(blocked, "settings.db"))
	if err = EnsureNativeService(ctx, port); err == nil {
		t.Fatal("invalid DB path reported ready")
	}
	t.Setenv("MUSIC_DL_CONFIG_DB", filepath.Join(root, "settings.db"))
	if err = EnsureNativeService(ctx, port); err != nil {
		t.Fatal(err)
	}
	raw, err := NativeClientRequest(`{"action":"collections.create","params":{"name":"isolated-native-service"}}`)
	if err != nil {
		t.Fatal(err)
	}
	if len(raw) == 0 {
		t.Fatal("missing persisted collection")
	}
	raw, err = NativeClientRequest(`{"action":"collections.list"}`)
	if err != nil || !strings.Contains(raw, "isolated-native-service") {
		t.Fatalf("library unavailable with occupied port: %s %v", raw, err)
	}
}

func TestNativeInProcessRoutesWorkWhenTCPTransportIsDown(t *testing.T) {
	previous, transport := nativeRoutes.Load(), nativeClientHTTP
	t.Cleanup(func() { nativeRoutes.Store(previous); nativeClientHTTP = transport })
	nativeClientHTTP = &http.Client{Transport: nativeClientTransport(func(*http.Request) (*http.Response, error) {
		t.Fatal("in-process call used TCP")
		return nil, errors.New("offline")
	})}
	nativeRoutes.Store(&nativeHandler{http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != "DELETE" || r.URL.Path != RoutePrefix+"/collections/42" || r.Header.Get("Origin") != nativeClientOrigin || r.Header.Get("X-Requested-With") != "XMLHttpRequest" {
			t.Error("route/write guard changed")
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"status":"ok"}`))
	})})
	if _, err := NativeClientRequest(`{"action":"collections.delete","params":{"id":"42"}}`); err != nil {
		t.Fatal(err)
	}
	request, _ := http.NewRequest("GET", "https://attacker.example/music/collections", nil)
	if _, err := performNativeRoute(nativeRoutes.Load(), request); err == nil {
		t.Fatal("arbitrary remote origin accepted")
	}
}

func TestNativeServiceReadyWaitDoesNotRestartInitializedRuntime(t *testing.T) {
	previous := nativeRoutes.Load()
	t.Cleanup(func() { nativeRoutes.Store(previous) })
	nativeRoutes.Store(&nativeHandler{http.NotFoundHandler()})
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	if err := EnsureNativeService(ctx, "37777"); err != nil {
		t.Fatal(err)
	}
	value, err := NativeClientRequest(`{"action":"service.status"}`)
	if err != nil || value != `{"data":{"ready":true}}` {
		t.Fatalf("%s %v", value, err)
	}
}

func TestDetailEmptyPartialFullAndDeadline(t *testing.T) {
	provider, timeout := nativeDetailProvider, nativeSourceTimeout
	t.Cleanup(func() { nativeDetailProvider = provider; nativeSourceTimeout = timeout })
	nativeSourceTimeout = 30 * time.Millisecond
	release := make(chan struct{})
	defer close(release)
	nativeDetailProvider = func(_, source string) func(string) ([]model.Song, error) {
		return func(id string) ([]model.Song, error) {
			switch id {
			case "empty":
				return []model.Song{}, nil
			case "partial":
				return []model.Song{{ID: "one"}}, errors.New("partial response")
			case "timeout":
				<-release
				return nil, nil
			default:
				return []model.Song{{ID: "one"}, {ID: "two"}}, nil
			}
		}
	}
	for _, tc := range []struct {
		id      string
		count   int
		partial bool
	}{{"empty", 0, false}, {"partial", 1, true}, {"full", 2, false}} {
		result, err := nativeDetail("detail", mapJSONForNativeTest(t, `{"kind":"toplist","source":"netease","id":"`+tc.id+`"}`))
		if err != nil || len(result.Songs) != tc.count || (len(result.Errors) > 0) != tc.partial {
			t.Fatalf("%s %+v %v", tc.id, result, err)
		}
	}
	_, err := nativeDetail("detail", mapJSONForNativeTest(t, `{"kind":"album","source":"netease","id":"timeout"}`))
	if !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("unbounded detail: %v", err)
	}
}

func TestSourceIsolationAndDuplicateDetailRequests(t *testing.T) {
	var calls atomic.Int32
	release, started := make(chan struct{}), make(chan struct{})
	// Occupy every slot of one source without blocking another source.
	var workers sync.WaitGroup
	for i := 0; i < 2; i++ {
		workers.Add(1)
		go func(i int) {
			defer workers.Done()
			_, _ = nativeSourceCall("migu", "blocked", string(rune('a'+i)), func() (bool, error) { <-release; return true, nil })
		}(i)
	}
	old := nativeDetailProvider
	t.Cleanup(func() { nativeDetailProvider = old })
	nativeDetailProvider = func(_, source string) func(string) ([]model.Song, error) {
		return func(string) ([]model.Song, error) {
			if calls.Add(1) == 1 {
				close(started)
			}
			time.Sleep(50 * time.Millisecond)
			return []model.Song{{ID: "one"}}, nil
		}
	}
	var requests sync.WaitGroup
	errorsFound := make(chan error, 6)
	params := mapJSONForNativeTest(t, `{"kind":"playlist","source":"qq","id":"single-flight-stability"}`)
	begin := time.Now()
	for i := 0; i < 6; i++ {
		requests.Add(1)
		go func() {
			defer requests.Done()
			result, err := nativeDetail("detail", params)
			if err == nil && len(result.Songs) != 1 {
				err = errors.New("missing data")
			}
			errorsFound <- err
		}()
	}
	<-started
	requests.Wait()
	close(errorsFound)
	close(release)
	workers.Wait()
	for err := range errorsFound {
		if err != nil {
			t.Fatal(err)
		}
	}
	if calls.Load() != 1 {
		t.Fatalf("duplicate provider calls=%d", calls.Load())
	}
	t.Logf("six concurrent detail readers: provider_calls=%d elapsed=%s", calls.Load(), time.Since(begin))
}

func TestSourceFactoryPanicDoesNotCrashOrDiscardOtherSearchResults(t *testing.T) {
	previous := nativeSearchProvider
	t.Cleanup(func() { nativeSearchProvider = previous })
	nativeSearchProvider = func(source string) core.SearchFunc {
		if source == "migu" {
			panic("fixture constructor failure")
		}
		return func(string) ([]model.Song, error) { return []model.Song{{ID: "valid"}}, nil }
	}
	result, err := nativeSearch(mapJSONForNativeTest(t, `{"q":"constructor-panic","sources":["migu","qq"]}`))
	if err != nil || len(result.Songs) != 1 || result.Songs[0].Source != "qq" || len(result.Errors) != 1 {
		t.Fatalf("source fault escaped: %+v %v", result, err)
	}
}

// Explicit network diagnostic: registered capabilities are distinct from live
// availability. Never needs credentials; inaccessible providers are reported.
func TestRestoredSourcesPublicSearchProbe(t *testing.T) {
	if os.Getenv("MUSICDL_SOURCE_PROBE") != "1" {
		t.Skip("set MUSICDL_SOURCE_PROBE=1 for public source availability probe")
	}
	var group sync.WaitGroup
	for _, source := range core.GetMusicPlatformNames() {
		group.Add(1)
		go func(source string) {
			defer group.Done()
			start := time.Now()
			result, err := nativeSearch(mapJSONForNativeTest(t, `{"q":"piano","sources":["`+source+`"]}`))
			t.Logf("SOURCE_PROBE source=%s songs=%d errors=%v error=%v elapsed=%s", source, len(result.Songs), result.Errors, err, time.Since(start))
		}(source)
	}
	group.Wait()
	for _, source := range core.GetMusicPlatformNames() {
		group.Add(1)
		go func(source string) {
			defer group.Done()
			start := time.Now()
			result, err := nativeSearch(mapJSONForNativeTest(t, `{"q":"piano","type":"playlist","sources":["`+source+`"]}`))
			t.Logf("PLAYLIST_PROBE source=%s playlists=%d errors=%v error=%v elapsed=%s", source, len(result.Playlists), result.Errors, err, time.Since(start))
			if err != nil || len(result.Playlists) == 0 {
				return
			}
			params := mapJSONForNativeTest(t, `{"kind":"playlist","source":"`+source+`","id":"`+result.Playlists[0].ID+`"}`)
			start = time.Now()
			detail, err := nativeDetail("detail", params)
			t.Logf("DETAIL_PROBE source=%s songs=%d partial=%t error=%v elapsed=%s", source, len(detail.Songs), len(detail.Errors) > 0, err, time.Since(start))
		}(source)
	}
	group.Wait()
}

func TestNativeDetailLiveTimingComparison(t *testing.T) {
	if os.Getenv("MUSICDL_DETAIL_TIMING") != "1" {
		t.Skip("set MUSICDL_DETAIL_TIMING=1 for real network detail comparison")
	}
	charts, err := core.GetTopListsFunc("netease")()
	if err != nil || len(charts) == 0 {
		t.Skipf("no chart available: %v", err)
	}
	chart := charts[0]
	for _, candidate := range charts {
		if strings.Contains(candidate.Name, "热歌") {
			chart = candidate
			break
		}
	}
	params := mapJSONForNativeTest(t, `{"kind":"toplist","source":"netease","id":"`+chart.ID+`"}`)
	// Baseline executes the exact old direct provider/normalization path. Bound
	// this diagnostic wait only; do not label it iPhone latency or a cache test.
	for round := 0; round < 2; round++ {
		order := []bool{false, true}
		if round == 1 {
			order = []bool{true, false}
		}
		for _, optimized := range order {
			start := time.Now()
			var songs []nativeClientSong
			var err error
			if optimized {
				var result nativeClientResults
				result, err = nativeDetail("detail", params)
				songs = result.Songs
			} else {
				ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
				value, callErr := newNativeCallPool(1).run(ctx, "baseline", func() (interface{}, error) { return core.GetTopListSongsFunc("netease")(chart.ID) })
				cancel()
				err = callErr
				if value != nil {
					raw := value.([]model.Song)
					for i := range raw {
						raw[i].Source = "netease"
					}
					songs = nativeSongs(filterSongsForDisplay(raw, core.GetWebSettings()))
				}
			}
			t.Logf("DETAIL_TIMING round=%d bounded=%t source=netease kind=toplist songs=%d elapsed=%s error=%v", round+1, optimized, len(songs), time.Since(start), err)
		}
	}
}
