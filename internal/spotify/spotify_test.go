package spotify

import (
	"io"
	"net/http"
	"strings"
	"testing"

	"github.com/guohuiyuan/music-lib/model"
)

type transport func(*http.Request) (*http.Response, error)

func (f transport) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

func TestMetadataAndPreviewAuthorization(t *testing.T) {
	c := New(`{"access_token":"authorized-token","market":"JP"}`)
	c.http.Transport = transport(func(r *http.Request) (*http.Response, error) {
		if r.URL.Host != "api.spotify.com" || r.Header.Get("Authorization") != "Bearer authorized-token" {
			t.Fatalf("unexpected credential destination: %s", r.URL.Host)
		}
		if r.Header.Get("Cookie") != "" {
			t.Fatal("API credentials became a cookie")
		}
		body := `{"id":"track1","name":"Track","duration_ms":180000,"artists":[{"name":"Artist"}],"album":{"id":"album1","name":"Album","images":[{"url":"https://example.com/cover.jpg"}]},"preview_url":null}`
		if strings.Contains(r.URL.Path, "search") {
			body = `{"tracks":{"items":[` + body + `]}}`
		}
		return &http.Response{StatusCode: 200, Body: io.NopCloser(strings.NewReader(body)), Header: make(http.Header)}, nil
	})
	songs, err := c.Search("Track")
	if err != nil || len(songs) != 1 {
		t.Fatalf("Search: %v %#v", err, songs)
	}
	if songs[0].Duration != 180 || songs[0].AlbumID != "album1" || songs[0].Link != "https://open.spotify.com/track/track1" {
		t.Fatalf("metadata lost: %#v", songs[0])
	}
	if _, err = c.GetDownloadURL(&model.Song{ID: "track1"}); err == nil {
		t.Fatal("claimed full playback without an authorized preview")
	}
}

func TestNoCredentialsFailsWithoutNetwork(t *testing.T) {
	c := New("")
	c.http.Transport = transport(func(*http.Request) (*http.Response, error) {
		t.Fatal("network used without credentials")
		return nil, nil
	})
	if _, err := c.Search("test"); err == nil {
		t.Fatal("missing authorization accepted")
	}
}

func TestRejectsPaginationCredentialExfiltration(t *testing.T) {
	for _, raw := range []string{"https://attacker.example/v1/tracks", "http://api.spotify.com/v1/tracks", "https://api.spotify.com.attacker.example/v1/tracks"} {
		if _, err := nextPath(raw); err == nil {
			t.Fatalf("accepted untrusted page %s", raw)
		}
	}
	if got, err := nextPath("https://api.spotify.com/v1/albums/one/tracks?offset=50"); err != nil || got != "/v1/albums/one/tracks?offset=50" {
		t.Fatalf("valid page rejected: %q %v", got, err)
	}
}

func TestLinkValidation(t *testing.T) {
	for _, link := range []string{"spotify:track:abc123", "https://open.spotify.com/intl-zh/track/abc123?si=test"} {
		if id, err := parseID(link, "track"); err != nil || id != "abc123" {
			t.Fatalf("%s: %s %v", link, id, err)
		}
	}
	if _, err := parseID("https://attacker.example/track/abc123", "track"); err == nil {
		t.Fatal("accepted external host")
	}
}
