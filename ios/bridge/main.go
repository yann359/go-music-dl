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

var startMu sync.Mutex
var pathsReady bool

func response(value string, err error) *C.char {
	if err != nil {
		data, _ := json.Marshal(map[string]string{"error": err.Error()})
		return C.CString(string(data))
	}
	return C.CString(value)
}

//export MusicDLStart
func MusicDLStart(root *C.char) *C.char {
	startMu.Lock()
	if !pathsReady {
		dir := C.GoString(root)
		if err := os.MkdirAll(dir, 0700); err != nil {
			startMu.Unlock()
			return response("", err)
		}
		if err := os.Chdir(dir); err != nil {
			startMu.Unlock()
			return response("", err)
		}
		os.Setenv("MUSIC_DL_CONFIG_DB", filepath.Join(dir, "settings.db"))
		os.Setenv("MUSIC_DL_COOKIE_FILE", filepath.Join(dir, "cookies.json"))
		core.EnableNativeAppleAuthorization()
		spotify.EnableNativeAuthorization()
		pathsReady = true
	}
	startMu.Unlock()
	ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
	defer cancel()
	err := web.EnsureNativeService(ctx, appshell.DefaultPort)
	data, _ := json.Marshal(map[string]string{"url": appshell.AppURL(appshell.DefaultPort)})
	return response(string(data), err)
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
