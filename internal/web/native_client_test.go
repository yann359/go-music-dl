package web

import (
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"strings"
	"testing"

	"github.com/guohuiyuan/go-music-dl/core"
	"github.com/guohuiyuan/music-lib/model"
)

func TestNativeSourceCatalogPreservesEveryCoreSource(t *testing.T) {
	raw, err := NativeClientRequest(`{"action":"sources"}`)
	if err != nil {
		t.Fatal(err)
	}
	var envelope struct {
		Data struct {
			Sources []struct {
				ID string `json:"id"`
			} `json:"sources"`
		} `json:"data"`
	}
	if err = json.Unmarshal([]byte(raw), &envelope); err != nil {
		t.Fatal(err)
	}
	seen := map[string]bool{}
	for _, source := range envelope.Data.Sources {
		if seen[source.ID] {
			t.Fatalf("duplicate source %s", source.ID)
		}
		seen[source.ID] = true
	}
	for _, source := range core.GetAllSourceNames() {
		if !seen[source] {
			t.Fatalf("core source omitted: %s", source)
		}
	}
	if len(seen) != len(core.GetAllSourceNames()) {
		t.Fatal("catalog invented unsupported sources")
	}
}

func TestNativeSearchKeepsAuthorizationMetadataAndPartialErrors(t *testing.T) {
	initCollectionDBForTest(t)
	original := nativeSearchProvider
	t.Cleanup(func() { nativeSearchProvider = original })
	nativeSearchProvider = func(source string) core.SearchFunc {
		return func(query string) ([]model.Song, error) {
			if source == "qq" {
				return nil, errors.New("authorization expired")
			}
			return []model.Song{{ID: "track", Name: "Track", Artist: "Artist", Album: "Album", AlbumID: "album", Duration: 180,
				Link: "https://example.com/track", IsVIP: true, Extra: map[string]string{"quality": "lossless", "track_id": "original"}}}, nil
		}
	}
	raw, err := NativeClientRequest(`{"action":"search","params":{"q":"Track","sources":["netease","qq"]}}`)
	if err != nil {
		t.Fatal(err)
	}
	var result struct {
		Data nativeClientResults `json:"data"`
	}
	if err = json.Unmarshal([]byte(raw), &result); err != nil {
		t.Fatal(err)
	}
	if len(result.Data.Songs) != 1 || len(result.Data.Errors) != 1 {
		t.Fatalf("partial data lost: %s", raw)
	}
	song := result.Data.Songs[0]
	if song.Source != "netease" || song.AlbumID != "album" || song.Link != "https://example.com/track" || !song.IsVIP || !strings.Contains(song.Extra, "lossless") {
		t.Fatalf("metadata changed: %#v", song)
	}
}

type nativeClientTransport func(*http.Request) (*http.Response, error)

func (f nativeClientTransport) RoundTrip(request *http.Request) (*http.Response, error) {
	return f(request)
}

func TestNativeForegroundRoutesStayOnLoopbackAndRetainWriteGuard(t *testing.T) {
	original := nativeClientHTTP
	t.Cleanup(func() { nativeClientHTTP = original })
	nativeClientHTTP = &http.Client{Transport: nativeClientTransport(func(request *http.Request) (*http.Response, error) {
		if request.URL.Host != "127.0.0.1:37777" {
			t.Fatalf("escaped native service: %s", request.URL.Host)
		}
		if request.Method != http.MethodDelete || request.URL.Path != RoutePrefix+"/collections/42" {
			t.Fatalf("wrong route: %s %s", request.Method, request.URL.Path)
		}
		if request.Header.Get("X-Requested-With") != "XMLHttpRequest" || request.Header.Get("Origin") != nativeClientOrigin {
			t.Fatal("write guard was bypassed")
		}
		return &http.Response{StatusCode: 200, Body: io.NopCloser(strings.NewReader(`{"status":"ok"}`)), Header: make(http.Header)}, nil
	})}
	if _, err := NativeClientRequest(`{"action":"collections.delete","params":{"id":"42"}}`); err != nil {
		t.Fatal(err)
	}
}

func TestNativeRequestRejectsArbitraryNetworkAndPathInputs(t *testing.T) {
	for _, raw := range []string{
		`{"action":"http","params":{"url":"https://attacker.example"}}`,
		`{"action":"collections.delete","params":{"id":"../../settings"}}`,
		`{"action":"downloads.action","params":{"id":1,"action":"execute"}}`,
		`{"action":"qr.create","params":{"source":"../../"}}`,
		`{"action":"local.import","params":{"path":"C:/Windows/System32/kernel32.dll"}}`,
	} {
		if _, err := NativeClientRequest(raw); err == nil {
			t.Fatalf("accepted unsafe input: %s", raw)
		}
	}
}

func TestNativePartialSettingsUpdatePreservesUnmentionedFields(t *testing.T) {
	initCollectionDBForTest(t)
	settings := core.GetWebSettings()
	settings.WebDAVURL = "https://dav.example.com/music"
	settings.WebDAVUsername = "account"
	settings.WebDAVPassword = "private-password"
	if err := core.SaveWebSettings(settings); err != nil {
		t.Fatal(err)
	}
	result, err := NativeClientRequest(`{"action":"settings.save","params":{"settings":{"autoCacheOnPlay":true}}}`)
	if err != nil {
		t.Fatal(err)
	}
	saved := core.GetWebSettings()
	if saved.WebDAVURL != settings.WebDAVURL || saved.WebDAVUsername != settings.WebDAVUsername || saved.WebDAVPassword != settings.WebDAVPassword {
		t.Fatal("partial save destroyed existing settings")
	}
	if strings.Contains(result, "private-password") {
		t.Fatal("masked settings response leaked password")
	}
}
