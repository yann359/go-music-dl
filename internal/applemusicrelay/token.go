// Package applemusicrelay is an optional, separately deployed HTTPS companion.
// It is never started by the iOS app or the existing local music service.
package applemusicrelay

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"errors"
	"net/url"
	"regexp"
	"time"
)

var opaque = regexp.MustCompile(`^[A-Za-z0-9_-]{43}$`)
var identifier = regexp.MustCompile(`^[A-Z0-9]{10}$`)

const CustomCallback = "com.guohuiyuan.musicdl.apple-login://callback"

type Config struct {
	Origin, Callback, TeamID, KeyID string
	PrivateKey                      *ecdsa.PrivateKey
}

func (c Config) Validate() error {
	u, err := url.Parse(c.Origin)
	if err != nil || u.Scheme != "https" || u.Host == "" || u.User != nil || u.Port() != "" || u.RawQuery != "" || u.Fragment != "" || u.Path != "" {
		return errors.New("configure a bare HTTPS public origin")
	}
	if c.Callback != CustomCallback && c.Callback != c.Origin+"/apple-music/return" {
		return errors.New("configure the fixed app callback or associated HTTPS return URL")
	}
	if !identifier.MatchString(c.TeamID) || !identifier.MatchString(c.KeyID) || c.PrivateKey == nil || c.PrivateKey.Curve != elliptic.P256() {
		return errors.New("configure Apple Team ID, Media Services Key ID and server-only ES256 key")
	}
	return nil
}

func ParsePrivateKey(data []byte) (*ecdsa.PrivateKey, error) {
	block, _ := pem.Decode(data)
	if block == nil {
		return nil, errors.New("invalid server signing key")
	}
	key, err := x509.ParsePKCS8PrivateKey(block.Bytes)
	if err != nil {
		return nil, errors.New("invalid PKCS8 signing key")
	}
	k, ok := key.(*ecdsa.PrivateKey)
	if !ok || k.Curve != elliptic.P256() {
		return nil, errors.New("ES256 key required")
	}
	return k, nil
}

func randomID() string {
	var b [32]byte
	if _, err := rand.Read(b[:]); err != nil {
		panic("secure random unavailable")
	}
	return base64.RawURLEncoding.EncodeToString(b[:])
}

func challenge(verifier string) string {
	h := sha256.Sum256([]byte(verifier))
	return base64.RawURLEncoding.EncodeToString(h[:])
}

func (c Config) developerToken(now time.Time) (string, error) {
	if err := c.Validate(); err != nil {
		return "", err
	}
	header, _ := json.Marshal(map[string]string{"alg": "ES256", "kid": c.KeyID})
	claims, _ := json.Marshal(map[string]any{"iss": c.TeamID, "iat": now.Unix() - 30, "exp": now.Add(15 * time.Minute).Unix(), "origin": []string{c.Origin}})
	encode := base64.RawURLEncoding.EncodeToString
	input := encode(header) + "." + encode(claims)
	hash := sha256.Sum256([]byte(input))
	r, s, err := ecdsa.Sign(rand.Reader, c.PrivateKey, hash[:])
	if err != nil {
		return "", errors.New("developer token signing unavailable")
	}
	signature := make([]byte, 64)
	r.FillBytes(signature[:32])
	s.FillBytes(signature[32:])
	return input + "." + encode(signature), nil
}
