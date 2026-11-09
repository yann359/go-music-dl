package spotify

import (
	"io"
	"net/http"
	"strings"
	"testing"
	"time"
)

func isolateNativeSession(t *testing.T) {
	t.Helper()
	nativeSession.Lock()
	enabled, access, expires := nativeSession.enabled, nativeSession.access, nativeSession.expires
	nativeSession.enabled = false
	nativeSession.access = ""
	nativeSession.Unlock()
	t.Cleanup(func() {
		nativeSession.Lock()
		nativeSession.enabled = enabled
		nativeSession.access = access
		nativeSession.expires = expires
		nativeSession.Unlock()
	})
}

func TestNativeSessionUsesOnlyUnexpiredInProcessAccessToken(t *testing.T) {
	isolateNativeSession(t)
	EnableNativeAuthorization()
	client := New(`{"access_token":"legacy-token","client_id":"old","client_secret":"server-only"}`)
	if _, err := client.token(); err == nil {
		t.Fatal("native app reused old database credentials")
	}
	if err := SetNativeAuthorization("fixture-access", time.Now().Add(time.Hour).Unix()); err != nil {
		t.Fatal(err)
	}
	client.http.Transport = transport(func(r *http.Request) (*http.Response, error) {
		if r.URL.Host != "api.spotify.com" || r.Header.Get("Authorization") != "Bearer fixture-access" || r.Header.Get("Cookie") != "" {
			t.Fatal("native token escaped intended API/header")
		}
		return &http.Response{StatusCode: 200, Body: io.NopCloser(strings.NewReader(`{"tracks":{"items":[]}}`)), Header: make(http.Header)}, nil
	})
	if _, err := client.Search("fixture"); err != nil {
		t.Fatal(err)
	}
	if err := SetNativeAuthorization("", 0); err != nil {
		t.Fatal(err)
	}
	if _, err := client.token(); err == nil {
		t.Fatal("disconnected session still works")
	}
	if err := SetNativeAuthorization("expired", time.Now().Add(-time.Second).Unix()); err == nil {
		t.Fatal("expired access accepted")
	}
}

func TestSpotifyPlaylistFieldRenameRetainsLegacyCompatibility(t *testing.T) {
	isolateNativeSession(t)
	client := New(`{"access_token":"fixture"}`)
	client.http.Transport = transport(func(r *http.Request) (*http.Response, error) {
		return &http.Response{StatusCode: 200, Body: io.NopCloser(strings.NewReader(`{"items":[{"id":"new","name":"Current","items":{"total":42}},{"id":"old","tracks":{"total":3}}]}`)), Header: make(http.Header)}, nil
	})
	values, err := client.GetUserPlaylists(1, 20)
	if err != nil || len(values) != 2 || values[0].TrackCount != 42 || values[1].TrackCount != 3 {
		t.Fatalf("playlists=%+v err=%v", values, err)
	}
}
