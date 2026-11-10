package web

import (
	"context"
	"crypto/sha256"
	"fmt"
	"sync"
	"time"

	"github.com/guohuiyuan/go-music-dl/core"
	"github.com/guohuiyuan/music-lib/model"
)

var nativeSourceTimeout = 8 * time.Second
var nativeSourcePools sync.Map

// Each registered source owns two slots. One blocked legacy adapter cannot
// consume another source's capacity. A slot remains held until I/O really ends.
func nativeSourceCall[T any](source, operation, identity string, fn func() (T, error)) (T, error) {
	var zero T
	if !core.IsMusicPlatform(source) {
		return zero, fmt.Errorf("unsupported source: %s", source)
	}
	return boundedSourceCall(source, operation, identity, nativeSourceTimeout, fn)
}

// Also used by the legacy automatic-switch path. Its workers need the same
// per-source limits and same-goroutine panic boundary as native searches.
func boundedSourceCall[T any](source, operation, identity string, timeout time.Duration, fn func() (T, error)) (T, error) {
	var zero T
	pool := nativeSourcePool(source)
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	key := nativeProviderKey(operation, source) + fmt.Sprintf(":%x", sha256.Sum256([]byte(identity)))
	value, err := pool.run(ctx, key, func() (interface{}, error) { return fn() })
	if result, ok := value.(T); ok {
		return result, err
	}
	return zero, err
}

var nativeDetailProvider = func(kind, source string) func(string) ([]model.Song, error) {
	switch kind {
	case "album":
		return core.GetAlbumDetailFunc(source)
	case "playlist":
		return core.GetPlaylistDetailFunc(source)
	case "toplist":
		return core.GetTopListSongsFunc(source)
	}
	return nil
}

func nativeSourcePool(source string) *nativeCallPool {
	if !core.IsMusicPlatform(source) {
		return nativeDiscoveryCalls
	}
	pool, _ := nativeSourcePools.LoadOrStore(source, newNativeCallPool(2))
	return pool.(*nativeCallPool)
}
