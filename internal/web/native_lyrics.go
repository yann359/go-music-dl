package web

import (
	"context"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"
	"unicode"

	"github.com/guohuiyuan/go-music-dl/core"
	"github.com/guohuiyuan/music-lib/model"
)

var nativeLyricHTTP = &http.Client{Timeout: 4 * time.Second}
var nativeLyricProvider = core.GetLyricFunc
var nativeLyricSearch = core.GetSearchFunc

func nativeLyricIdentity(song *model.Song) string {
	data, _ := json.Marshal([]interface{}{song.Source, song.ID, song.Name, song.Artist, song.Album, song.Duration})
	return fmt.Sprintf("%x", sha256.Sum256(data))
}

type nativeCachedLyric struct {
	Identity string
	Text     string
	Saved    time.Time
}

func readNativeLyricCache(dir, key string) string {
	data, err := os.ReadFile(filepath.Join(dir, key+".json"))
	if err != nil || len(data) > 3<<20 {
		return ""
	}
	var value nativeCachedLyric
	if json.Unmarshal(data, &value) != nil || value.Identity != key || time.Since(value.Saved) < 0 || time.Since(value.Saved) > 30*24*time.Hour {
		return ""
	}
	return value.Text
}
func writeNativeLyricCache(dir, key, text string) {
	if strings.TrimSpace(text) == "" || len(text) > 2<<20 {
		return
	}
	if os.MkdirAll(dir, 0700) != nil {
		return
	}
	data, _ := json.Marshal(nativeCachedLyric{key, text, time.Now()})
	file, err := os.CreateTemp(dir, ".lyric-*")
	if err != nil {
		return
	}
	name := file.Name()
	defer func() { _ = os.Remove(name) }()
	_, err = file.Write(data)
	closeErr := file.Close()
	if err == nil && closeErr == nil {
		_ = os.Rename(name, filepath.Join(dir, key+".json"))
	}
}

func requestNativeLyrics(ctx context.Context, song *model.Song) (string, error) {
	if song.Source == "migu" {
		value, err := nativeLyricCalls.run(ctx, nativeProviderKey("lyric", song.Source)+":"+nativeLyricIdentity(song), func() (interface{}, error) {
			return core.ReadMiguLyrics(ctx, nativeLyricHTTP, song)
		})
		if err != nil {
			return "", err
		}
		return value.(string), nil
	}
	fn := nativeLyricProvider(song.Source)
	if fn == nil {
		return "", &core.LyricFailure{Kind: "missing", Err: errors.New("lyrics unsupported")}
	}
	// Legacy QQ can fill in metadata on the pointer; don't mutate the current song.
	copySong := *song
	copySong.Extra = make(map[string]string, len(song.Extra))
	for key, value := range song.Extra {
		copySong.Extra[key] = value
	}
	value, err := nativeLyricCalls.run(ctx, nativeProviderKey("lyric", song.Source)+":"+nativeLyricIdentity(song), func() (interface{}, error) { return fn(&copySong) })
	if err != nil {
		return "", err
	}
	return core.DecodeLyricText([]byte(value.(string)), "text/plain; charset=utf-8")
}

func retryNativeLyrics(ctx context.Context, song *model.Song) (string, error) {
	var err error
	for attempt := 0; attempt < 3; attempt++ {
		if attempt > 0 {
			timer := time.NewTimer(time.Duration(200*(1<<(attempt-1))) * time.Millisecond)
			select {
			case <-timer.C:
			case <-ctx.Done():
				timer.Stop()
				return "", ctx.Err()
			}
		}
		start := time.Now()
		attemptCtx, cancel := context.WithTimeout(ctx, 4*time.Second)
		var text string
		text, err = requestNativeLyrics(attemptCtx, song)
		cancel()
		nativeTiming(fmt.Sprintf("lyric source=%s attempt=%d kind=%s", song.Source, attempt+1, core.LyricFailureKind(err)), start, err)
		if err == nil {
			return text, nil
		}
		if !core.LyricRetryable(err) || ctx.Err() != nil {
			break
		}
	}
	return "", err
}

// Deliberately stricter than audio source switching: unknown durations, alternate
// versions and ambiguous albums cannot supply synchronized lyrics.
func exactNativeLyricMatch(original, candidate *model.Song) bool {
	normalize := func(s string) string {
		return strings.Map(func(r rune) rune {
			if unicode.IsSpace(r) {
				return -1
			}
			if r == '（' {
				return '('
			}
			if r == '）' {
				return ')'
			}
			return unicode.ToLower(r)
		}, strings.TrimSpace(s))
	}
	if normalize(original.Name) == "" || normalize(original.Artist) == "" || original.Duration <= 0 || candidate.Duration <= 0 {
		return false
	}
	if normalize(original.Name) != normalize(candidate.Name) || normalize(original.Artist) != normalize(candidate.Artist) {
		return false
	}
	if core.IntAbs(original.Duration-candidate.Duration) > 2 {
		return false
	}
	// Album must be known and identical: otherwise a same-title studio/live edit
	// with missing version labels cannot be verified safely.
	return normalize(original.Album) != "" && normalize(original.Album) == normalize(candidate.Album)
}

func fallbackNativeLyrics(ctx context.Context, song *model.Song) string {
	if song.Duration <= 0 || song.Name == "" || song.Artist == "" || song.Album == "" {
		return ""
	}
	type match struct {
		source string
		songs  []model.Song
	}
	results := make(chan match, 2)
	var group sync.WaitGroup
	for _, source := range []string{"netease", "qq"} {
		if source == song.Source {
			continue
		}
		fn := nativeLyricSearch(source)
		if fn == nil {
			continue
		}
		group.Add(1)
		go func(source string) {
			defer group.Done()
			searchCtx, cancel := context.WithTimeout(ctx, 2*time.Second)
			defer cancel()
			value, err := nativeLyricCalls.run(searchCtx, nativeProviderKey("lyric-search", source)+":"+nativeLyricIdentity(song), func() (interface{}, error) { return fn(song.Name + " " + song.Artist) })
			if err == nil {
				results <- match{source, value.([]model.Song)}
			}
		}(source)
	}
	go func() { group.Wait(); close(results) }()
	for result := range results {
		for i := range result.songs[:min(8, len(result.songs))] {
			candidate := result.songs[i]
			candidate.Source = result.source
			if exactNativeLyricMatch(song, &candidate) {
				text, err := requestNativeLyrics(ctx, &candidate)
				if err == nil && strings.TrimSpace(text) != "" {
					return text
				}
				break
			}
		}
	}
	return ""
}

func resilientNativeLyrics(song *model.Song, dir string) (string, error) {
	start := time.Now()
	key := nativeLyricIdentity(song)
	if text := readNativeLyricCache(dir, key); text != "" {
		nativeTiming("lyric cache=hit", start, nil)
		return text, nil
	}
	nativeTiming("lyric cache=miss", start, nil)
	ctx, cancel := context.WithTimeout(context.Background(), 16*time.Second)
	defer cancel()
	text, err := retryNativeLyrics(ctx, song)
	if err != nil || strings.TrimSpace(text) == "" {
		if fallback := fallbackNativeLyrics(ctx, song); fallback != "" {
			text = fallback
			err = nil
		}
	}
	if err != nil {
		kind := core.LyricFailureKind(err)
		if kind == "missing" {
			return "", nil
		}
		messages := map[string]string{"network": "网络暂时中断，请重试。", "server": "歌词服务暂时繁忙，请稍后重试。", "format": "歌词内容暂时无法读取，请重试。", "authorization": "此来源的歌词暂时无法访问，请检查账号授权。"}
		message := messages[kind]
		if message == "" {
			message = "歌词来源暂时不可用，请稍后重试。"
		}
		return "", errors.New(message)
	}
	writeNativeLyricCache(dir, key, text)
	pruneNativeLyricCache(dir)
	return text, nil
}

func pruneNativeLyricCache(dir string) {
	entries, _ := os.ReadDir(dir)
	if len(entries) <= 256 {
		return
	}
	type item struct {
		name  string
		saved time.Time
	}
	var files []item
	for _, entry := range entries {
		if entry.IsDir() || !strings.HasSuffix(entry.Name(), ".json") {
			continue
		}
		if info, err := entry.Info(); err == nil {
			files = append(files, item{entry.Name(), info.ModTime()})
		}
	}
	sort.Slice(files, func(i, j int) bool { return files[i].saved.Before(files[j].saved) })
	for _, file := range files[:max(0, len(files)-256)] {
		_ = os.Remove(filepath.Join(dir, file.name))
	}
}
