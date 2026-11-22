package web

import (
	"context"
	"encoding/json"
	"strings"
	"time"

	"github.com/guohuiyuan/go-music-dl/core"
)

func legacyAccountSource(source string) bool {
	switch source {
	case "netease", "qq", "soda", "kugou", "kuwo", "migu", "fivesing", "jamendo", "joox", "qianqian", "bilibili":
		return true
	}
	return false
}

// Old DB rows stay untouched for rollback. Unsupported credentials are no
// longer exposed as account choices, and native OAuth tokens never enter CM.
func activeAccountCookies(native bool) map[string]string {
	result := map[string]string{}
	for source, cookie := range core.CM.GetAll() {
		if core.IsMusicPlatform(source) && (!native || legacyAccountSource(source)) {
			result[source] = cookie
		}
	}
	return result
}

var nativeAccountPlaylists = core.GetUserPlaylistsFunc

func nativeValidateLegacyAccount(params map[string]json.RawMessage) interface{} {
	source := nativeString(params, "source")
	if !legacyAccountSource(source) {
		return map[string]string{"status": "unavailable"}
	}
	if core.CM.Get(source) == "" {
		return map[string]string{"status": "disconnected"}
	}
	fn := nativeAccountPlaylists(source)
	if fn == nil {
		return map[string]string{"status": "unsupported"}
	}
	ctx, cancel := context.WithTimeout(context.Background(), 6*time.Second)
	defer cancel()
	count, err := nativeSourcePool(source).run(ctx, nativeProviderKey("account", source), func() (interface{}, error) { rows, err := fn(1, 1); return len(rows), err })
	status := "unverified"
	if n, ok := count.(int); err == nil && ok && n > 0 {
		status = "playlists_readable"
	}
	if err != nil {
		status = "unavailable"
		text := strings.ToLower(err.Error())
		for _, marker := range []string{"unauthorized", "expired", "401", "未登录", "登录过期"} {
			if strings.Contains(text, marker) {
				status = "expired"
				break
			}
		}
	}
	return map[string]string{"status": status}
}
