package spotify

import (
	"errors"
	"sync"
	"time"
)

// iOS owns refresh tokens in Keychain. Go receives only a short-lived access
// token over its in-process C ABI; it must never persist or refresh it itself.
var nativeSession struct {
	sync.RWMutex
	enabled bool
	access  string
	expires time.Time
}

func EnableNativeAuthorization() {
	nativeSession.Lock()
	defer nativeSession.Unlock()
	nativeSession.enabled = true
}

func SetNativeAuthorization(access string, expires int64) error {
	if len(access) > 8192 || (access != "" && expires <= time.Now().Unix()) {
		return errors.New("invalid or expired Spotify session")
	}
	nativeSession.Lock()
	defer nativeSession.Unlock()
	nativeSession.enabled = true
	nativeSession.access = access
	nativeSession.expires = time.Unix(expires, 0)
	return nil
}

func nativeAccessToken() (string, bool, error) {
	nativeSession.RLock()
	defer nativeSession.RUnlock()
	if !nativeSession.enabled {
		return "", false, nil
	}
	if nativeSession.access == "" || !time.Now().Before(nativeSession.expires) {
		return "", true, errors.New("spotify authorization required; reconnect in Accounts")
	}
	return nativeSession.access, true, nil
}
