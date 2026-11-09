package core

import (
	"context"
	"errors"
	"io"
	"net/http"
	"strings"
	"testing"

	"github.com/guohuiyuan/music-lib/model"
)

type lyricTestTransport func(*http.Request) (*http.Response, error)

func (f lyricTestTransport) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

type interruptedLyricBody struct{ sent bool }

func (b *interruptedLyricBody) Read(p []byte) (int, error) {
	if b.sent {
		return 0, io.ErrUnexpectedEOF
	}
	b.sent = true
	return copy(p, "[00:00.00]partial"), nil
}
func (*interruptedLyricBody) Close() error { return nil }

func TestMiguRejectsInterruptedBodyAndRefetchesURL(t *testing.T) {
	metadata, downloads := 0, 0
	client := &http.Client{Transport: lyricTestTransport(func(r *http.Request) (*http.Response, error) {
		response := &http.Response{StatusCode: 200, Header: make(http.Header), ContentLength: -1}
		if strings.Contains(r.URL.Path, "resourceinfo.do") {
			metadata++
			response.Body = io.NopCloser(strings.NewReader(`{"resource":[{"lrcUrl":"http://lyrics.example/current"}]}`))
		} else {
			downloads++
			if r.URL.Scheme != "https" {
				t.Error("lyric download did not retain HTTPS upgrade")
			}
			if downloads == 1 {
				response.Body = &interruptedLyricBody{}
			} else {
				response.Body = io.NopCloser(strings.NewReader("[00:01.00]完整歌词"))
			}
		}
		return response, nil
	})}
	song := &model.Song{Source: "migu", ID: "content|other"}
	text, err := ReadMiguLyrics(context.Background(), client, song)
	if text != "" || !errors.Is(err, io.ErrUnexpectedEOF) || !LyricRetryable(err) {
		t.Fatalf("partial text accepted: %q %v", text, err)
	}
	text, err = ReadMiguLyrics(context.Background(), client, song)
	if err != nil || text != "[00:01.00]完整歌词" || metadata != 2 || downloads != 2 {
		t.Fatalf("fresh URL not resolved: %q %v metadata=%d", text, err, metadata)
	}
}

func TestLyricHTTPStatusClassificationAndLength(t *testing.T) {
	for _, tc := range []struct {
		status int
		kind   string
		retry  bool
	}{{404, "missing", false}, {410, "missing", false}, {403, "authorization", false}, {429, "server", true}, {503, "server", true}} {
		client := &http.Client{Transport: lyricTestTransport(func(*http.Request) (*http.Response, error) {
			return &http.Response{StatusCode: tc.status, Body: io.NopCloser(strings.NewReader("")), Header: make(http.Header)}, nil
		})}
		_, _, err := readLyricHTTP(context.Background(), client, "https://example.com", "", "", "")
		if LyricFailureKind(err) != tc.kind || LyricRetryable(err) != tc.retry {
			t.Fatalf("status=%d err=%v", tc.status, err)
		}
	}
	client := &http.Client{Transport: lyricTestTransport(func(*http.Request) (*http.Response, error) {
		return &http.Response{StatusCode: 200, ContentLength: 100, Body: io.NopCloser(strings.NewReader("short")), Header: make(http.Header)}, nil
	})}
	if data, _, err := readLyricHTTP(context.Background(), client, "https://example.com", "", "", ""); data != nil || !errors.Is(err, io.ErrUnexpectedEOF) {
		t.Fatal("content length mismatch accepted")
	}
}
