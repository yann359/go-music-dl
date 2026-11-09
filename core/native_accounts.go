package core

import "sync/atomic"

var nativeAppleAuthorization atomic.Bool

// MusicKit owns native Apple credentials. Existing database rows are retained
// for rollback/server use, but must not silently authenticate a disconnected
// iOS account or leak as a Cookie onto an audio request.
func EnableNativeAppleAuthorization() { nativeAppleAuthorization.Store(true) }

func appleCredential(legacy string) string {
	if nativeAppleAuthorization.Load() {
		return ""
	}
	return legacy
}
