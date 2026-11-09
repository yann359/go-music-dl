package web

import (
	"context"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/guohuiyuan/go-music-dl/core"
	"github.com/guohuiyuan/music-lib/model"
)

func TestNativeLyricRetryRecoversEOFAndNeverCachesPartial(t *testing.T) {
	original, search := nativeLyricProvider, nativeLyricSearch
	t.Cleanup(func() { nativeLyricProvider = original; nativeLyricSearch = search })
	nativeLyricSearch = func(string) core.SearchFunc { return nil }
	calls := 0
	nativeLyricProvider = func(string) func(*model.Song) (string, error) {
		return func(*model.Song) (string, error) {
			calls++
			if calls < 3 {
				return "partial", io.ErrUnexpectedEOF
			}
			return "[00:01]完整歌词", nil
		}
	}
	song := &model.Song{ID: "eof", Source: "qq", Name: "Song", Artist: "Singer", Album: "Album", Duration: 200}
	dir := t.TempDir()
	text, err := resilientNativeLyrics(song, dir)
	if err != nil || text != "[00:01]完整歌词" || calls != 3 {
		t.Fatalf("text=%q err=%v calls=%d", text, err, calls)
	}
	text, err = resilientNativeLyrics(song, dir)
	if err != nil || calls != 3 || text != "[00:01]完整歌词" {
		t.Fatal("matching cache not used first")
	}
	changed := *song
	changed.Name = "Song (Live)"
	if readNativeLyricCache(dir, nativeLyricIdentity(&changed)) != "" {
		t.Fatal("cache crossed track versions")
	}
}

func TestNativeLyricFailureClassificationAndSanitizedUI(t *testing.T) {
	original, search := nativeLyricProvider, nativeLyricSearch
	t.Cleanup(func() { nativeLyricProvider = original; nativeLyricSearch = search })
	nativeLyricSearch = func(string) core.SearchFunc { return nil }
	for _, tc := range []struct {
		err      error
		attempts int
		absent   bool
	}{
		{io.ErrUnexpectedEOF, 3, false},
		{&core.LyricFailure{Kind: "format", Err: errors.New("parse at https://secret.example")}, 1, false},
		{errors.New("lyric not found"), 1, true},
	} {
		calls := 0
		nativeLyricProvider = func(string) func(*model.Song) (string, error) {
			return func(*model.Song) (string, error) { calls++; return "", tc.err }
		}
		text, err := resilientNativeLyrics(&model.Song{ID: "none", Source: "qq"}, t.TempDir())
		if text != "" || calls != tc.attempts || (err == nil) != tc.absent {
			t.Fatalf("calls=%d err=%v", calls, err)
		}
		if err != nil && (strings.Contains(err.Error(), "https://") || strings.Contains(err.Error(), "EOF")) {
			t.Fatal("technical details leaked")
		}
	}
}

func TestNativeLyricStrictMatchRejectsVersionsCoversAndUnknownDurations(t *testing.T) {
	original := model.Song{Source: "soda", ID: "one", Name: "晴天", Artist: "周杰伦", Album: "叶惠美", Duration: 269}
	for _, tc := range []struct {
		name, artist, album string
		duration            int
		want                bool
	}{
		{"晴天", "周杰伦", "叶惠美", 270, true},
		{"晴天 (Live)", "周杰伦", "叶惠美", 269, false},
		{"晴天", "另一位", "叶惠美", 269, false},
		{"晴天", "周杰伦", "演唱会", 269, false},
		{"晴天", "周杰伦", "叶惠美", 0, false},
		{"晴天", "周杰伦", "叶惠美", 280, false},
		{"晴天", "周杰伦", "", 269, false},
	} {
		candidate := model.Song{Name: tc.name, Artist: tc.artist, Album: tc.album, Duration: tc.duration}
		if got := exactNativeLyricMatch(&original, &candidate); got != tc.want {
			t.Fatalf("candidate=%+v got=%t", candidate, got)
		}
	}
}

func TestNativeLyricFallbackUsesOnlyVerifiedMatch(t *testing.T) {
	origProvider, origSearch := nativeLyricProvider, nativeLyricSearch
	t.Cleanup(func() { nativeLyricProvider = origProvider; nativeLyricSearch = origSearch })
	song := &model.Song{ID: "original", Source: "soda", Name: "Song", Artist: "Singer", Album: "Album", Duration: 200}
	nativeLyricSearch = func(source string) core.SearchFunc {
		return func(string) ([]model.Song, error) {
			return []model.Song{
				{ID: "live", Name: "Song (Live)", Artist: "Singer", Album: "Album", Duration: 200},
				{ID: "cover", Name: "Song", Artist: "Cover", Album: "Album", Duration: 200},
				{ID: "correct", Name: "Song", Artist: "Singer", Album: "Album", Duration: 201},
			}, nil
		}
	}
	nativeLyricProvider = func(string) func(*model.Song) (string, error) {
		return func(candidate *model.Song) (string, error) {
			if candidate.ID != "correct" {
				t.Error("wrong version requested")
			}
			return "[00:01]correct lyrics", nil
		}
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	if got := fallbackNativeLyrics(ctx, song); got != "[00:01]correct lyrics" {
		t.Fatalf("fallback=%q", got)
	}
}

func TestNativeLyricCacheRejectsExpiredAndMismatchedFiles(t *testing.T) {
	dir := t.TempDir()
	key := nativeLyricIdentity(&model.Song{Source: "qq", ID: "one"})
	writeNativeLyricCache(dir, key, "[00:01]real")
	if readNativeLyricCache(dir, key) == "" {
		t.Fatal("valid cache missing")
	}
	file := filepath.Join(dir, key+".json")
	if err := os.WriteFile(file, []byte(`{"Identity":"wrong","Text":"bad","Saved":"2020-01-01T00:00:00Z"}`), 0600); err != nil {
		t.Fatal(err)
	}
	if readNativeLyricCache(dir, key) != "" {
		t.Fatal("stale/mismatched cache accepted")
	}
}
