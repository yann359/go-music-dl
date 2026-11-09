package web

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/guohuiyuan/go-music-dl/core"
	"github.com/guohuiyuan/music-lib/model"
)

func mapJSONForNativeTest(t *testing.T, raw string) map[string]json.RawMessage {
	t.Helper()
	var result map[string]json.RawMessage
	if err := json.Unmarshal([]byte(raw), &result); err != nil {
		t.Fatal(err)
	}
	return result
}
func nativeLiveTimingEnabled() bool { return os.Getenv("MUSICDL_LIVE_TIMING") == "1" }

func TestNativeCallDeadlineKeepsSingleFlightAndUnderlyingConcurrencyBound(t *testing.T) {
	pool := newNativeCallPool(1)
	release := make(chan struct{})
	finished := make(chan struct{})
	var count atomic.Int32
	fn := func() (interface{}, error) { count.Add(1); <-release; close(finished); return "ok", nil }
	for i := 0; i < 3; i++ {
		ctx, cancel := context.WithTimeout(context.Background(), 20*time.Millisecond)
		_, err := pool.run(ctx, "same-source", fn)
		cancel()
		if !errors.Is(err, context.DeadlineExceeded) {
			t.Fatalf("deadline=%v", err)
		}
	}
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Millisecond)
	_, err := pool.run(ctx, "another-source", func() (interface{}, error) { t.Error("occupied slot released before provider exited"); return nil, nil })
	cancel()
	if !errors.Is(err, context.DeadlineExceeded) || count.Load() != 1 {
		t.Fatalf("err=%v count=%d", err, count.Load())
	}
	close(release)
	<-finished
}

func TestNativeRecommendationsAndToplistsKeepPartialDataOnTimeout(t *testing.T) {
	origRecommend, origTop, origTimeout, origPool := nativeRecommendProvider, nativeTopListsProvider, nativeDiscoveryTimeout, nativeDiscoveryCalls
	t.Cleanup(func() {
		nativeRecommendProvider = origRecommend
		nativeTopListsProvider = origTop
		nativeDiscoveryTimeout = origTimeout
		nativeDiscoveryCalls = origPool
	})
	nativeDiscoveryCalls = newNativeCallPool(3)
	nativeDiscoveryTimeout = 35 * time.Millisecond
	release := make(chan struct{})
	var workers sync.WaitGroup
	nativeRecommendProvider = func(source string) func() ([]model.Playlist, error) {
		return func() ([]model.Playlist, error) {
			if source == "qq" {
				workers.Add(1)
				defer workers.Done()
				<-release
				return nil, errors.New("offline")
			}
			return []model.Playlist{{ID: "real", Name: "Valid"}}, nil
		}
	}
	params := mapJSONForNativeTest(t, `{"sources":["netease","qq"]}`)
	result, err := nativePlaylists("recommend", params)
	if err != nil || len(result.Playlists) != 1 || len(result.Errors) != 1 || result.Playlists[0].Source != "netease" {
		t.Fatalf("partial data=%+v err=%v", result, err)
	}
	close(release)
	workers.Wait()
	nativeTopListsProvider = func(source string) core.TopListsFunc {
		return func() ([]model.TopList, error) {
			if source == "qq" {
				return nil, errors.New("offline https://secret.example")
			}
			return []model.TopList{{ID: "valid"}}, nil
		}
	}
	value, err := nativeTopLists(params)
	data := value.(map[string]interface{})
	if err != nil || len(data["toplists"].([]model.TopList)) != 1 || len(data["errors"].([]string)) != 1 {
		t.Fatalf("toplists=%+v err=%v", data, err)
	}
}

// Controlled timing, not an iPhone or public-network benchmark. The legacy
// screen awaited BOTH recommendations, then started charts. The new screen
// publishes independent completed operations. Delays represent weak sources.
func TestNativeDiscoveryControlledTiming(t *testing.T) {
	delays := []time.Duration{25 * time.Millisecond, 220 * time.Millisecond, 40 * time.Millisecond}
	start := time.Now()
	var oldGroup sync.WaitGroup
	for _, delay := range delays[:2] {
		oldGroup.Add(1)
		go func(delay time.Duration) { defer oldGroup.Done(); time.Sleep(delay) }(delay)
	}
	oldGroup.Wait()
	oldFirst := time.Since(start)
	time.Sleep(delays[2])
	oldTotal := time.Since(start)
	pool := newNativeCallPool(3)
	start = time.Now()
	done := make(chan time.Duration, 3)
	for i, delay := range delays {
		go func(i int, delay time.Duration) {
			_, _ = pool.run(context.Background(), string(rune('a'+i)), func() (interface{}, error) { time.Sleep(delay); return true, nil })
			done <- time.Since(start)
		}(i, delay)
	}
	newFirst := <-done
	var newTotal time.Duration
	for i := 0; i < 2; i++ {
		newTotal = <-done
	}
	t.Logf("controlled weak network: legacy_first=%s legacy_total=%s parallel_first=%s parallel_total=%s", oldFirst, oldTotal, newFirst, newTotal)
	if newFirst >= oldFirst || newTotal >= oldTotal {
		t.Fatal("independent source delivery did not improve controlled timing")
	}
}

// Optional explicit diagnostics of the actual provider library on this host.
func TestNativeDiscoveryLiveTiming(t *testing.T) {
	if !nativeLiveTimingEnabled() {
		t.Skip("set MUSICDL_LIVE_TIMING=1 for public provider timing")
	}
	start := time.Now()
	var group sync.WaitGroup
	counts := make([]int, 3)
	errs := make([]error, 3)
	for i, source := range []string{"netease", "qq"} {
		group.Add(1)
		go func(i int, source string) {
			defer group.Done()
			v, e := core.GetRecommendFunc(source)()
			counts[i] = len(v)
			errs[i] = e
		}(i, source)
	}
	group.Wait()
	first := time.Since(start)
	v, e := core.GetTopListsFunc("netease")()
	counts[2] = len(v)
	errs[2] = e
	t.Logf("host live legacy pipeline: first=%s total=%s counts=%v errors=%v", first, time.Since(start), counts, errs)
	start = time.Now()
	done := make(chan time.Duration, 3)
	for i, source := range []string{"netease", "qq", "netease"} {
		group.Add(1)
		go func(i int, source string) {
			defer group.Done()
			if i < 2 {
				r, _ := nativePlaylists("recommend", mapJSONForNativeTest(t, `{"sources":["`+source+`"]}`))
				counts[i] = len(r.Playlists)
				errs[i] = nil
				if len(r.Errors) > 0 {
					errs[i] = errors.New(r.Errors[0])
				}
			} else {
				r, _ := nativeTopLists(mapJSONForNativeTest(t, `{"sources":["netease"]}`))
				m := r.(map[string]interface{})
				counts[i] = len(m["toplists"].([]model.TopList))
				errs[i] = nil
				if len(m["errors"].([]string)) > 0 {
					errs[i] = errors.New(m["errors"].([]string)[0])
				}
			}
			done <- time.Since(start)
		}(i, source)
	}
	first = <-done
	group.Wait()
	t.Logf("host live parallel pipeline: first_completion=%s total=%s counts=%v errors=%v", first, time.Since(start), counts, errs)
}
