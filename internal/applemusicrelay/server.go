package applemusicrelay

import (
	"context"
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"crypto/subtle"
	"embed"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/http"
	"net/url"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"
)

//go:embed web/*
var assets embed.FS

type flow struct {
	Challenge, State, Bootstrap, Cookie, Code string
	Sealed                                    []byte
	Expires                                   time.Time
	Completing                                bool
}
type session struct {
	Sealed  []byte
	Expires time.Time
}
type budget struct {
	Count int
	Until time.Time
}
type Server struct {
	config   Config
	client   *http.Client
	mu       sync.Mutex
	flows    map[string]*flow
	sessions map[string]session
	limits   map[string]budget
	box      cipher.AEAD
	now      func() time.Time
}

func New(c Config) (*Server, error) {
	if c.Callback == "" {
		c.Callback = CustomCallback
	}
	if err := c.Validate(); err != nil {
		return nil, err
	}
	key := make([]byte, 32)
	if _, err := rand.Read(key); err != nil {
		return nil, err
	}
	block, _ := aes.NewCipher(key)
	box, _ := cipher.NewGCM(block)
	return &Server{config: c, client: &http.Client{Timeout: 20 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }},
		flows: map[string]*flow{}, sessions: map[string]session{}, limits: map[string]budget{}, box: box, now: time.Now}, nil
}

func (s *Server) seal(token string) []byte {
	nonce := make([]byte, s.box.NonceSize())
	if _, err := rand.Read(nonce); err != nil {
		panic("secure random unavailable")
	}
	return s.box.Seal(nonce, nonce, []byte(token), nil)
}
func (s *Server) unseal(b []byte) (string, error) {
	if len(b) < s.box.NonceSize() {
		return "", errors.New("invalid session")
	}
	v, e := s.box.Open(nil, b[:s.box.NonceSize()], b[s.box.NonceSize():], nil)
	return string(v), e
}
func same(a, b string) bool {
	return len(a) > 0 && subtle.ConstantTimeCompare([]byte(a), []byte(b)) == 1
}
func fail(w http.ResponseWriter, status int, code string) {
	reply(w, status, map[string]string{"error": code})
}
func reply(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}
func decode(w http.ResponseWriter, r *http.Request, v any) bool {
	if strings.Split(r.Header.Get("Content-Type"), ";")[0] != "application/json" {
		fail(w, 415, "invalid_request")
		return false
	}
	d := json.NewDecoder(http.MaxBytesReader(w, r.Body, 32768))
	d.DisallowUnknownFields()
	if d.Decode(v) != nil || d.Decode(new(any)) != io.EOF {
		fail(w, 400, "invalid_request")
		return false
	}
	return true
}

func (s *Server) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("Referrer-Policy", "no-referrer")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.Header().Set("Strict-Transport-Security", "max-age=31536000")
	w.Header().Set("Content-Security-Policy", "default-src 'none'; script-src 'self' https://js-cdn.music.apple.com; style-src 'self'; connect-src 'self' https://*.apple.com https://*.mzstatic.com; img-src 'self' data: https://*.mzstatic.com; frame-src https://*.apple.com; base-uri 'none'; form-action 'none'; frame-ancestors 'none'")
	if origin := r.Header.Get("Origin"); origin != "" && origin != s.config.Origin {
		fail(w, 403, "invalid_origin")
		return
	}
	if !s.allow(r.RemoteAddr) {
		fail(w, 429, "rate_limited")
		return
	}
	switch {
	case r.Method == "GET" && r.URL.Path == "/v1/config":
		reply(w, 200, map[string]any{"version": 1, "ready": true, "callback": s.config.Callback})
	case r.Method == "GET" && r.URL.Path == "/v1/web-config":
		token, err := s.config.developerToken(s.now())
		if err != nil {
			fail(w, 503, "developer_unavailable")
			return
		}
		reply(w, 200, map[string]string{"developerToken": token})
	case r.Method == "POST" && r.URL.Path == "/v1/flows":
		s.create(w, r)
	case r.Method == "POST" && r.URL.Path == "/v1/browser/start":
		s.bootstrap(w, r)
	case r.Method == "POST" && r.URL.Path == "/v1/browser/complete":
		s.complete(w, r)
	case r.Method == "POST" && r.URL.Path == "/v1/browser/cancel":
		s.browserCancel(w, r)
	case r.Method == "POST" && r.URL.Path == "/v1/exchange":
		s.exchange(w, r)
	case r.Method == "POST" && r.URL.Path == "/v1/cancel":
		s.cancel(w, r)
	case r.Method == "POST" && r.URL.Path == "/v1/read":
		s.read(w, r)
	case r.Method == "DELETE" && r.URL.Path == "/v1/session":
		s.disconnect(w, r)
	case r.Method == "GET" && (r.URL.Path == "/connect" || r.URL.Path == "/disconnect" || r.URL.Path == "/apple-music/return"):
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		b, _ := assets.ReadFile("web/index.html")
		_, _ = w.Write(b)
	case r.Method == "GET" && (r.URL.Path == "/app.js" || r.URL.Path == "/app.css"):
		if strings.HasSuffix(r.URL.Path, ".js") {
			w.Header().Set("Content-Type", "text/javascript; charset=utf-8")
		} else {
			w.Header().Set("Content-Type", "text/css; charset=utf-8")
		}
		b, _ := assets.ReadFile("web" + r.URL.Path)
		_, _ = w.Write(b)
	default:
		fail(w, 404, "not_found")
	}
}

func (s *Server) allow(remote string) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	now := s.now()
	for k, v := range s.flows {
		if !now.Before(v.Expires) {
			delete(s.flows, k)
		}
	}
	for k, v := range s.sessions {
		if !now.Before(v.Expires) {
			delete(s.sessions, k)
		}
	}
	for k, v := range s.limits {
		if !now.Before(v.Until) {
			delete(s.limits, k)
		}
	}
	ip, _, err := net.SplitHostPort(remote)
	if err != nil {
		ip = remote
	}
	v := s.limits[ip]
	if v.Count == 0 {
		v.Until = now.Add(time.Minute)
	}
	if v.Count >= 90 || len(s.limits) >= 4096 {
		return false
	}
	v.Count++
	s.limits[ip] = v
	return true
}
func (s *Server) create(w http.ResponseWriter, r *http.Request) {
	var in struct {
		Challenge string `json:"challenge"`
		State     string `json:"state"`
	}
	if !decode(w, r, &in) {
		return
	}
	if !opaque.MatchString(in.Challenge) || !opaque.MatchString(in.State) {
		fail(w, 400, "invalid_request")
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if len(s.flows) >= 4096 {
		fail(w, 503, "busy")
		return
	}
	id, secret := randomID(), randomID()
	s.flows[id] = &flow{Challenge: in.Challenge, State: in.State, Bootstrap: secret, Expires: s.now().Add(10 * time.Minute)}
	reply(w, 200, map[string]string{"id": id, "browserURL": s.config.Origin + "/connect#" + id + "." + secret})
}
func (s *Server) bootstrap(w http.ResponseWriter, r *http.Request) {
	if r.Header.Get("Origin") != s.config.Origin {
		fail(w, 403, "invalid_origin")
		return
	}
	var in struct {
		ID     string `json:"id"`
		Secret string `json:"secret"`
	}
	if !decode(w, r, &in) {
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	f := s.flows[in.ID]
	if f == nil || !s.now().Before(f.Expires) || !same(f.Bootstrap, in.Secret) {
		fail(w, 401, "expired_flow")
		return
	}
	f.Bootstrap = ""
	f.Cookie = randomID()
	http.SetCookie(w, &http.Cookie{Name: "__Host-musicdl-apple", Value: in.ID + "." + f.Cookie, Path: "/", Secure: true, HttpOnly: true, SameSite: http.SameSiteStrictMode, MaxAge: 600})
	reply(w, 200, map[string]bool{"ready": true})
}
func (s *Server) complete(w http.ResponseWriter, r *http.Request) {
	if r.Header.Get("Origin") != s.config.Origin {
		fail(w, 403, "invalid_origin")
		return
	}
	var in struct {
		Token string `json:"token"`
	}
	if !decode(w, r, &in) {
		return
	}
	if len(in.Token) < 8 || len(in.Token) > 16384 || strings.ContainsAny(in.Token, "\r\n") {
		fail(w, 400, "invalid_token")
		return
	}
	cookie, err := r.Cookie("__Host-musicdl-apple")
	if err != nil {
		fail(w, 401, "expired_flow")
		return
	}
	p := strings.Split(cookie.Value, ".")
	if len(p) != 2 {
		fail(w, 401, "expired_flow")
		return
	}
	s.mu.Lock()
	f := s.flows[p[0]]
	if f == nil || !same(f.Cookie, p[1]) || f.Code != "" || f.Completing || !s.now().Before(f.Expires) {
		s.mu.Unlock()
		fail(w, 409, "expired_flow")
		return
	}
	f.Completing = true
	s.mu.Unlock()
	// Verify both user region and actual library access before returning a code.
	data, status, code := s.apple(r.Context(), in.Token, "/v1/me/storefront")
	if status == 200 {
		var region struct{ Data []struct{ ID, Type string } }
		if json.Unmarshal(data, &region) != nil || len(region.Data) == 0 || region.Data[0].ID == "" || region.Data[0].Type != "storefronts" {
			status, code = 502, "apple_invalid_response"
		}
	}
	if status == 200 {
		data, status, code = s.apple(r.Context(), in.Token, "/v1/me/library/playlists?limit=1")
		var library struct{ Data []json.RawMessage }
		if status == 200 && (json.Unmarshal(data, &library) != nil || library.Data == nil) {
			status, code = 502, "apple_invalid_response"
		}
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.flows[p[0]] != f || !s.now().Before(f.Expires) {
		fail(w, 410, "expired_flow")
		return
	}
	f.Completing = false
	if status != 200 {
		fail(w, status, code)
		return
	}
	f.Code = randomID()
	f.Sealed = s.seal(in.Token)
	f.Expires = s.now().Add(2 * time.Minute)
	u, _ := url.Parse(s.config.Callback)
	q := url.Values{"id": {p[0]}, "code": {f.Code}, "state": {f.State}}
	u.RawQuery = q.Encode()
	reply(w, 200, map[string]string{"callback": u.String()})
}
func (s *Server) exchange(w http.ResponseWriter, r *http.Request) {
	var in struct {
		ID       string `json:"id"`
		Code     string `json:"code"`
		Verifier string `json:"verifier"`
	}
	if !decode(w, r, &in) {
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	f := s.flows[in.ID]
	if f == nil || !s.now().Before(f.Expires) || !opaque.MatchString(in.Verifier) || !same(f.Challenge, challenge(in.Verifier)) || !same(f.Code, in.Code) {
		fail(w, 401, "invalid_exchange")
		return
	}
	if len(s.sessions) >= 4096 {
		fail(w, 503, "busy")
		return
	}
	id := randomID()
	expires := s.now().Add(24 * time.Hour)
	s.sessions[id] = session{Sealed: f.Sealed, Expires: expires}
	delete(s.flows, in.ID)
	reply(w, 200, map[string]any{"session": id, "expires": expires.Unix()})
}
func (s *Server) cancel(w http.ResponseWriter, r *http.Request) {
	var in struct {
		ID       string `json:"id"`
		Verifier string `json:"verifier"`
	}
	if !decode(w, r, &in) {
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if f := s.flows[in.ID]; f != nil && same(f.Challenge, challenge(in.Verifier)) {
		delete(s.flows, in.ID)
	}
	w.WriteHeader(204)
}
func (s *Server) browserCancel(w http.ResponseWriter, r *http.Request) {
	if r.Header.Get("Origin") != s.config.Origin {
		fail(w, 403, "invalid_origin")
		return
	}
	cookie, err := r.Cookie("__Host-musicdl-apple")
	if err != nil {
		w.WriteHeader(204)
		return
	}
	p := strings.Split(cookie.Value, ".")
	if len(p) == 2 {
		s.mu.Lock()
		if f := s.flows[p[0]]; f != nil && same(f.Cookie, p[1]) {
			delete(s.flows, p[0])
		}
		s.mu.Unlock()
	}
	w.WriteHeader(204)
}
func (s *Server) credential(r *http.Request) (string, string, bool) {
	id := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")
	if !opaque.MatchString(id) {
		return "", "", false
	}
	s.mu.Lock()
	v, ok := s.sessions[id]
	s.mu.Unlock()
	if !ok || !s.now().Before(v.Expires) {
		return "", "", false
	}
	token, err := s.unseal(v.Sealed)
	return id, token, err == nil
}
func (s *Server) disconnect(w http.ResponseWriter, r *http.Request) {
	id, _, ok := s.credential(r)
	if ok {
		s.mu.Lock()
		delete(s.sessions, id)
		s.mu.Unlock()
	}
	w.WriteHeader(204)
}
func (s *Server) read(w http.ResponseWriter, r *http.Request) {
	id, token, ok := s.credential(r)
	if !ok {
		fail(w, 401, "session_expired")
		return
	}
	var in struct {
		Path string `json:"path"`
	}
	if !decode(w, r, &in) {
		return
	}
	if !allowedPath(in.Path) {
		fail(w, 400, "invalid_path")
		return
	}
	data, status, code := s.apple(r.Context(), token, in.Path)
	if status != 200 {
		if status == 403 {
			s.mu.Lock()
			delete(s.sessions, id)
			s.mu.Unlock()
		}
		fail(w, status, code)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	_, _ = w.Write(data)
}

var readPath = regexp.MustCompile(`^/v1/(me/storefront|me/library/(songs|playlists)(/[A-Za-z0-9.\-]{1,100}(/tracks)?)?|catalog/[a-z]{2}/(search|playlists/[A-Za-z0-9.\-]{1,100}(/tracks)?))$`)

func allowedPath(path string) bool {
	if len(path) > 2048 {
		return false
	}
	u, err := url.Parse(path)
	if err != nil || u.Host != "" || u.Scheme != "" || u.Fragment != "" || !readPath.MatchString(u.Path) || u.RawPath != "" {
		return false
	}
	q, err := url.ParseQuery(u.RawQuery)
	if err != nil {
		return false
	}
	for k, v := range q {
		if len(v) != 1 {
			return false
		}
		switch k {
		case "offset", "limit":
			n, e := strconv.Atoi(v[0])
			if e != nil || n < 0 || (k == "offset" && n >= 5000) || (k == "limit" && (n < 1 || n > 100)) {
				return false
			}
		case "term":
			if !strings.HasSuffix(u.Path, "/search") || len(v[0]) > 600 || strings.TrimSpace(v[0]) == "" {
				return false
			}
		case "types":
			if !strings.HasSuffix(u.Path, "/search") || v[0] != "songs" {
				return false
			}
		default:
			return false
		}
	}
	return true
}
func (s *Server) apple(ctx context.Context, userToken, path string) ([]byte, int, string) {
	developer, err := s.config.developerToken(s.now())
	if err != nil {
		return nil, 503, "developer_unavailable"
	}
	request, err := http.NewRequestWithContext(ctx, "GET", "https://api.music.apple.com"+path, nil)
	if err != nil {
		return nil, 400, "invalid_path"
	}
	request.Header.Set("Authorization", "Bearer "+developer)
	request.Header.Set("Music-User-Token", userToken)
	request.Header.Set("Origin", s.config.Origin)
	response, err := s.client.Do(request)
	if err != nil {
		return nil, 502, "apple_network"
	}
	defer response.Body.Close()
	switch response.StatusCode {
	case 200:
		data, err := io.ReadAll(io.LimitReader(response.Body, 8*1024*1024+1))
		if err != nil || len(data) > 8*1024*1024 || !json.Valid(data) {
			return nil, 502, "apple_invalid_response"
		}
		var envelope struct {
			Data    json.RawMessage `json:"data"`
			Results json.RawMessage `json:"results"`
		}
		if json.Unmarshal(data, &envelope) != nil || (len(envelope.Data) == 0 && len(envelope.Results) == 0) {
			return nil, 502, "apple_invalid_response"
		}
		return data, 200, ""
	case 401:
		return nil, 503, "developer_unavailable"
	case 403:
		return nil, 403, "music_access_denied"
	case 404:
		return nil, 404, "apple_not_found"
	case 429:
		return nil, 429, "apple_rate_limited"
	default:
		return nil, 502, "apple_unavailable"
	}
}
