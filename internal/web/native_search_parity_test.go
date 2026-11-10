package web

import (
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/guohuiyuan/go-music-dl/core"
	"github.com/guohuiyuan/music-lib/model"
)

func TestNativeSearchNormalizesAndKeepsVersionsAndQuality(t *testing.T) {
	initCollectionDBForTest(t)
	previous := nativeSearchProvider
	t.Cleanup(func() { nativeSearchProvider = previous })
	nativeSearchProvider = func(source string) core.SearchFunc {
		return func(query string) ([]model.Song, error) {
			if source == "qq" {
				return nil, errors.New("unavailable")
			}
			if query != "周杰伦 晴天" {
				t.Errorf("unexpected normalized query %q", query)
			}
			return []model.Song{{ID: "studio", Name: "晴天", Artist: "周杰伦"}, {ID: "studio", Name: "晴天", Artist: "周杰伦"}, {ID: "live", Name: "晴天 (Live)", Artist: "周杰伦"}, {ID: "studio", Name: "晴天", Artist: "周杰伦", Extra: map[string]string{"quality": "lossless"}}}, nil
		}
	}
	raw, err := NativeClientRequest(`{"action":"search","params":{"q":"  周傑倫　\u200b晴天 ","sources":["netease","qq"]}}`)
	if err != nil {
		t.Fatal(err)
	}
	var envelope struct {
		Data nativeClientResults `json:"data"`
	}
	if err = json.Unmarshal([]byte(raw), &envelope); err != nil {
		t.Fatal(err)
	}
	if len(envelope.Data.Songs) != 3 || len(envelope.Data.Errors) != 1 {
		t.Fatalf("dedupe erased variants/partial results: %s", raw)
	}
}

func TestNativeSwitchRejectsWrongArtistDurationAndVersion(t *testing.T) {
	original := model.Song{ID: "a", Name: "晴天", Artist: "周傑倫", Source: "netease", Duration: 269}
	for _, test := range []struct {
		name, artist, album string
		duration            int
		match               bool
	}{
		{"晴天", "周杰伦", "叶惠美", 268, true},
		{"晴天 (Live)", "周杰伦", "", 269, false},
		{"晴天", "周杰伦", "世界巡回演唱会", 269, false},
		{"晴天 (伴奏)", "周杰伦", "", 269, false},
		{"晴天", "其他歌手", "", 269, false},
		{"晴天", "周杰伦", "", 180, false},
		{"晴天 (Remix)", "周杰伦", "", 269, false},
	} {
		candidate := model.Song{ID: "b", Name: test.name, Artist: test.artist, Album: test.album, Source: "qq", Duration: test.duration}
		_, ok := nativeSwitchMatch(&original, &candidate)
		if ok != test.match {
			t.Errorf("%+v matched=%v", test, ok)
		}
	}
}

func TestNativeSwitchProbesAudioAndPreservesSourceMetadata(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Range") != "bytes=0-511" {
			t.Error("range probe missing")
		}
		w.Header().Set("Content-Type", "audio/mpeg")
		w.WriteHeader(206)
		if r.URL.Path == "/bad" {
			_, _ = w.Write([]byte("<html>login required</html>"))
			return
		}
		_, _ = w.Write([]byte("ID3 real audio header for transport validation"))
	}))
	defer server.Close()
	previous := nativeSwitchDownload
	t.Cleanup(func() { nativeSwitchDownload = previous })
	nativeSwitchDownload = func(source string) func(*model.Song) (string, error) {
		return func(song *model.Song) (string, error) {
			if song.Extra["quality"] != "lossless" {
				t.Error("source metadata discarded")
			}
			return server.URL + song.Link, nil
		}
	}
	original := model.Song{ID: "one", Source: "netease", Name: "晴天", Artist: "周杰伦", Duration: 269}
	for _, path := range []string{"/ok", "/bad"} {
		candidate := model.Song{ID: "two", Source: "qq", Name: "晴天", Artist: "周杰伦", Duration: 270, Link: path, Extra: map[string]string{"quality": "lossless"}}
		params := map[string]json.RawMessage{}
		params["original"], _ = json.Marshal(original)
		params["song"], _ = json.Marshal(candidate)
		_, err := nativeValidateSwitch(params)
		if (err == nil) != (path == "/ok") {
			t.Fatalf("path=%s err=%v", path, err)
		}
	}
}

func TestNativeSearchMalformedAndUnsupportedDoNotPanic(t *testing.T) {
	for _, request := range []string{`{"action":"search","params":{"q":"x","type":"video"}}`, `{"action":"switch_source.validate","params":{"song":{}}}`} {
		_, err := NativeClientRequest(request)
		if err == nil {
			t.Fatalf("invalid operation accepted: %s", request)
		}
	}
	if got := core.NormalizeSearchQuery(" Ｍｉｎｅ\u200b   Mine "); got != "Mine Mine" {
		t.Fatalf("normalization=%q", got)
	}
	if !strings.Contains(core.SearchMatchText("陳奕迅"), "陈奕迅") {
		t.Fatal("traditional comparison unavailable")
	}
}
