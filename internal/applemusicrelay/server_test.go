package applemusicrelay

import (
	"bytes"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"io"
	"math/big"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"sync"
	"testing"
	"time"
)

// All Apple responses below are isolated protocol fixtures, not real accounts.
type roundTrip func(*http.Request) (*http.Response, error)

func (f roundTrip) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }
func fixture(t *testing.T) *Server {
	t.Helper()
	key, e := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if e != nil {
		t.Fatal(e)
	}
	s, e := New(Config{Origin: "https://music.example.com", TeamID: "ABCDEFGHIJ", KeyID: "KLMNOPQRST", PrivateKey: key})
	if e != nil {
		t.Fatal(e)
	}
	s.client.Transport = roundTrip(func(r *http.Request) (*http.Response, error) {
		if r.URL.Host != "api.music.apple.com" {
			t.Errorf("unexpected host: %s", r.URL.Host)
		}
		if r.Header.Get("Music-User-Token") != "fixture-music-user-token" {
			t.Error("missing user token")
		}
		if r.Header.Get("Origin") != s.config.Origin {
			t.Error("missing token origin")
		}
		body := `{"data":[]}`
		if r.URL.Path == "/v1/me/storefront" {
			body = `{"data":[{"type":"storefronts","id":"cn"}]}`
		}
		return &http.Response{StatusCode: 200, Body: io.NopCloser(strings.NewReader(body))}, nil
	})
	return s
}
func call(s *Server, method, path string, body any, origin string, cookie *http.Cookie, capability string) *httptest.ResponseRecorder {
	var b bytes.Buffer
	if body != nil {
		_ = json.NewEncoder(&b).Encode(body)
	}
	r := httptest.NewRequest(method, "https://music.example.com"+path, &b)
	r.RemoteAddr = "127.0.0.1:1234"
	if body != nil {
		r.Header.Set("Content-Type", "application/json")
	}
	if origin != "" {
		r.Header.Set("Origin", origin)
	}
	if cookie != nil {
		r.AddCookie(cookie)
	}
	if capability != "" {
		r.Header.Set("Authorization", "Bearer "+capability)
	}
	w := httptest.NewRecorder()
	s.ServeHTTP(w, r)
	return w
}
func object(t *testing.T, w *httptest.ResponseRecorder) map[string]any {
	t.Helper()
	if w.Code != 200 {
		t.Fatalf("HTTP %d: %s", w.Code, w.Body.String())
	}
	var v map[string]any
	if json.Unmarshal(w.Body.Bytes(), &v) != nil {
		t.Fatal("invalid response")
	}
	return v
}

type started struct {
	id, verifier, state string
	cookie              *http.Cookie
}

func begin(t *testing.T, s *Server) started {
	t.Helper()
	verifier, state := randomID(), randomID()
	v := object(t, call(s, "POST", "/v1/flows", map[string]string{"challenge": challenge(verifier), "state": state}, "", nil, ""))
	u, _ := url.Parse(v["browserURL"].(string))
	p := strings.Split(u.Fragment, ".")
	if len(p) != 2 || p[0] != v["id"] || u.RawQuery != "" {
		t.Fatal("unsafe browser URL")
	}
	w := call(s, "POST", "/v1/browser/start", map[string]string{"id": p[0], "secret": p[1]}, s.config.Origin, nil, "")
	object(t, w)
	cookies := w.Result().Cookies()
	if len(cookies) != 1 || !cookies[0].HttpOnly || !cookies[0].Secure || cookies[0].SameSite != http.SameSiteStrictMode {
		t.Fatal("unsafe browser cookie")
	}
	if call(s, "POST", "/v1/browser/start", map[string]string{"id": p[0], "secret": p[1]}, s.config.Origin, nil, "").Code == 200 {
		t.Fatal("bootstrap replay accepted")
	}
	return started{p[0], verifier, state, cookies[0]}
}
func complete(t *testing.T, s *Server, f started) url.Values {
	t.Helper()
	v := object(t, call(s, "POST", "/v1/browser/complete", map[string]string{"token": "fixture-music-user-token"}, s.config.Origin, f.cookie, ""))
	u, _ := url.Parse(v["callback"].(string))
	q := u.Query()
	if strings.Contains(u.String(), "fixture-music-user-token") || len(q) != 3 || q.Get("state") != f.state || q.Get("id") != f.id {
		t.Fatal("unsafe callback")
	}
	return q
}
func exchange(t *testing.T, s *Server, f started, q url.Values) string {
	t.Helper()
	v := object(t, call(s, "POST", "/v1/exchange", map[string]string{"id": f.id, "code": q.Get("code"), "verifier": f.verifier}, "", nil, ""))
	return v["session"].(string)
}
func TestDeveloperTokenHasValidES256SignatureShortLifetimeAndOrigin(t *testing.T) {
	s := fixture(t)
	now := time.Now()
	token, e := s.config.developerToken(now)
	if e != nil {
		t.Fatal(e)
	}
	p := strings.Split(token, ".")
	decode := base64.RawURLEncoding.DecodeString
	sig, _ := decode(p[2])
	hash := sha256.Sum256([]byte(p[0] + "." + p[1]))
	if len(sig) != 64 || !ecdsa.Verify(&s.config.PrivateKey.PublicKey, hash[:], new(big.Int).SetBytes(sig[:32]), new(big.Int).SetBytes(sig[32:])) {
		t.Fatal("invalid JWT signature")
	}
	var claims map[string]any
	b, _ := decode(p[1])
	_ = json.Unmarshal(b, &claims)
	if claims["exp"].(float64) > float64(now.Add(16*time.Minute).Unix()) || claims["origin"].([]any)[0] != s.config.Origin {
		t.Fatal("unsafe JWT scope/lifetime")
	}
}
func TestBrowserExchangeReadAndDisconnect(t *testing.T) {
	s := fixture(t)
	f := begin(t, s)
	q := complete(t, s, f)
	bad := call(s, "POST", "/v1/exchange", map[string]string{"id": f.id, "code": q.Get("code"), "verifier": randomID()}, "", nil, "")
	if bad.Code != 401 {
		t.Fatal("wrong PKCE accepted")
	}
	capability := exchange(t, s, f, q)
	if call(s, "POST", "/v1/exchange", map[string]string{"id": f.id, "code": q.Get("code"), "verifier": f.verifier}, "", nil, "").Code != 401 {
		t.Fatal("code replay accepted")
	}
	w := call(s, "POST", "/v1/read", map[string]string{"path": "/v1/me/library/playlists?limit=50&offset=0"}, "", nil, capability)
	object(t, w)
	for _, v := range s.sessions {
		if bytes.Contains(v.Sealed, []byte("fixture-music-user-token")) {
			t.Fatal("MUT stored in plaintext")
		}
	}
	if call(s, "DELETE", "/v1/session", nil, "", nil, capability).Code != 204 {
		t.Fatal("disconnect failed")
	}
	if call(s, "POST", "/v1/read", map[string]string{"path": "/v1/me/storefront"}, "", nil, capability).Code != 401 {
		t.Fatal("disconnected session readable")
	}
}
func TestCancelExpiryAndReconnectionAreIsolated(t *testing.T) {
	s := fixture(t)
	first := begin(t, s)
	second := begin(t, s)
	if call(s, "POST", "/v1/cancel", map[string]string{"id": first.id, "verifier": first.verifier}, "", nil, "").Code != 204 {
		t.Fatal("cancel failed")
	}
	if call(s, "POST", "/v1/browser/complete", map[string]string{"token": "fixture-music-user-token"}, s.config.Origin, first.cookie, "").Code == 200 {
		t.Fatal("cancelled flow authorized")
	}
	q := complete(t, s, second)
	capability := exchange(t, s, second, q)
	now := time.Now().Add(25 * time.Hour)
	s.now = func() time.Time { return now }
	if call(s, "POST", "/v1/read", map[string]string{"path": "/v1/me/storefront"}, "", nil, capability).Code != 401 {
		t.Fatal("expired session readable")
	}
	if len(s.flows) != 0 || len(s.sessions) != 0 {
		t.Fatal("expired state not removed")
	}
}
func TestBrowserCancelAndCSRFProtection(t *testing.T) {
	s := fixture(t)
	f := begin(t, s)
	for _, origin := range []string{"", "https://attacker.example"} {
		if call(s, "POST", "/v1/browser/complete", map[string]string{"token": "fixture-music-user-token"}, origin, f.cookie, "").Code != 403 {
			t.Fatal("CSRF accepted")
		}
	}
	if call(s, "POST", "/v1/browser/cancel", nil, s.config.Origin, f.cookie, "").Code != 200 {
		t.Fatal("browser cancel failed")
	}
	if s.flows[f.id] != nil {
		t.Fatal("browser cancel retained flow")
	}
}
func TestAppleFailuresAndInvalidProbeCannotBecomeConnected(t *testing.T) {
	for _, status := range []int{200, 401, 403, 404, 429, 500} {
		t.Run(http.StatusText(status), func(t *testing.T) {
			s := fixture(t)
			f := begin(t, s)
			s.client.Transport = roundTrip(func(*http.Request) (*http.Response, error) {
				return &http.Response{StatusCode: status, Body: io.NopCloser(strings.NewReader(`{"data":[]}`))}, nil
			})
			w := call(s, "POST", "/v1/browser/complete", map[string]string{"token": "fixture-music-user-token"}, s.config.Origin, f.cookie, "")
			if w.Code == 200 || s.flows[f.id].Code != "" || len(s.sessions) != 0 {
				t.Fatal("unverified Apple response became authorized")
			}
			if strings.Contains(w.Body.String(), "fixture-music-user-token") {
				t.Fatal("error leaked token")
			}
		})
	}
}
func TestReadPathsRejectArbitraryRequestsAndWrites(t *testing.T) {
	for _, path := range []string{"https://evil.example/v1/me/storefront", "//evil.example/path", "/v1/me/library/playlists/../../songs", "/v1/me/library/songs?url=https://evil.example", "/v1/me/library/songs?limit=1000", "/v1/me/library/songs?offset=5000", "/v1/me/library/songs?limit=1&limit=2", "/v1/me/library/songs%3fsecret", "/v1/catalog/us/search?types=albums", "/v1/me/library/songs#secret"} {
		if allowedPath(path) {
			t.Errorf("accepted %s", path)
		}
	}
	for _, path := range []string{"/v1/me/storefront", "/v1/me/library/songs?limit=50&offset=0", "/v1/me/library/playlists/p.test/tracks?limit=100&offset=0", "/v1/catalog/cn/search?term=hello&types=songs&limit=25"} {
		if !allowedPath(path) {
			t.Errorf("rejected %s", path)
		}
	}
}
func TestConcurrentExchangeConsumesOnce(t *testing.T) {
	s := fixture(t)
	f := begin(t, s)
	q := complete(t, s, f)
	var wg sync.WaitGroup
	results := make(chan int, 8)
	for range 8 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			results <- call(s, "POST", "/v1/exchange", map[string]string{"id": f.id, "code": q.Get("code"), "verifier": f.verifier}, "", nil, "").Code
		}()
	}
	wg.Wait()
	close(results)
	ok := 0
	for status := range results {
		if status == 200 {
			ok++
		}
	}
	if ok != 1 {
		t.Fatalf("successful exchanges: %d", ok)
	}
}
func TestCancelDuringAppleVerificationCannotResurrectFlow(t *testing.T) {
	s := fixture(t)
	f := begin(t, s)
	started := make(chan struct{})
	finish := make(chan struct{})
	s.client.Transport = roundTrip(func(*http.Request) (*http.Response, error) {
		close(started)
		<-finish
		return &http.Response{StatusCode: 403, Body: io.NopCloser(strings.NewReader(`{}`))}, nil
	})
	done := make(chan int)
	go func() {
		done <- call(s, "POST", "/v1/browser/complete", map[string]string{"token": "fixture-music-user-token"}, s.config.Origin, f.cookie, "").Code
	}()
	<-started
	call(s, "POST", "/v1/cancel", map[string]string{"id": f.id, "verifier": f.verifier}, "", nil, "")
	close(finish)
	if <-done == 200 || len(s.sessions) != 0 {
		t.Fatal("cancelled flow resurrected")
	}
}
func TestInvalidConfigurationAndSecurityHeaders(t *testing.T) {
	s := fixture(t)
	for _, origin := range []string{"http://music.example.com", "https://user:password@music.example.com", "https://music.example.com/path", "https://music.example.com?token=x"} {
		c := s.config
		c.Origin = origin
		if c.Validate() == nil {
			t.Fatal("invalid origin accepted")
		}
	}
	w := call(s, "GET", "/connect", nil, "", nil, "")
	if w.Code != 200 || w.Header().Get("Cache-Control") != "no-store" || w.Header().Get("Referrer-Policy") != "no-referrer" || !strings.Contains(w.Header().Get("Content-Security-Policy"), "frame-ancestors 'none'") {
		t.Fatal("missing security headers")
	}
	if strings.Contains(w.Body.String(), "type=\"password\"") {
		t.Fatal("password form prohibited")
	}
}
