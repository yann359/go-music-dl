//go:build ios || nativebridge

package main

/*
#include <stdlib.h>
*/
import "C"

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"sync"
	"time"
	"unsafe"

	"github.com/guohuiyuan/go-music-dl/core"

	"github.com/guohuiyuan/go-music-dl/internal/appshell"
	"github.com/guohuiyuan/go-music-dl/internal/spotify"
	"github.com/guohuiyuan/go-music-dl/internal/web"
)

var startOnce sync.Once
var startURL string
var startError error

func response(value string, err error) *C.char {
	if err != nil {
		data, _ := json.Marshal(map[string]string{"error": err.Error()})
		return C.CString(string(data))
	}
	return C.CString(value)
}

//export MusicDLStart
func MusicDLStart(root *C.char) *C.char {
	startOnce.Do(func() {
		core.EnableNativeAppleAuthorization()
		spotify.EnableNativeAuthorization()
		dir := C.GoString(root)
		startError = os.MkdirAll(dir, 0700)
		if startError != nil {
			return
		}
		// Relative data/download paths now stay inside the app's sandbox.
		startError = os.Chdir(dir)
		if startError != nil {
			return
		}
		os.Setenv("MUSIC_DL_CONFIG_DB", filepath.Join(dir, "settings.db"))
		os.Setenv("MUSIC_DL_COOKIE_FILE", filepath.Join(dir, "cookies.json"))
		ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
		defer cancel()
		startURL, startError = appshell.StartDesktopServerAndWait(ctx, appshell.DefaultPort)
	})
	data, _ := json.Marshal(map[string]string{"url": startURL})
	return response(string(data), startError)
}

//export MusicDLResolve
func MusicDLResolve(song *C.char, fallback C.int) *C.char {
	value, err := web.NativePlaybackAsset(C.GoString(song), fallback != 0)
	return response(value, err)
}

//export MusicDLFree
func MusicDLFree(value *C.char) { C.free(unsafe.Pointer(value)) }

//export MusicDLRequest
func MusicDLRequest(request *C.char) *C.char {
	value, err := web.NativeClientRequest(C.GoString(request))
	return response(value, err)
}

func main() {}
