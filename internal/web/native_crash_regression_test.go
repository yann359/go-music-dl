package web

import (
	"context"
	"os"
	"os/exec"
	"strings"
	"testing"
	"time"

	"github.com/guohuiyuan/music-lib/model"
)

// A real panic executes in a child process so a broken recovery boundary cannot
// kill the rest of the suite. No network or user database is involved.
func TestSwitchWorkerPanicIsolation(t *testing.T) {
	for _, stage := range []string{"search", "validation"} {
		t.Run(stage, func(t *testing.T) {
			if os.Getenv("MUSICDL_PANIC_CHILD") == stage {
				if stage == "search" {
					got := searchSwitchSourceCandidates("qq", func(string) ([]model.Song, error) {
						panic("controlled adapter failure")
					}, "Track", "Track", "Artist", 180)
					if len(got) != 0 {
						t.Fatal("panic became a song")
					}
				} else {
					switchValidatePlayable = func(song *model.Song) bool {
						if song.Source == "qq" {
							panic("controlled validation failure")
						}
						return true
					}
					got, _, ok := validateSwitchCandidates([]switchCandidate{
						{song: model.Song{ID: "bad", Source: "qq"}, score: 1},
						{song: model.Song{ID: "healthy", Source: "kuwo"}, score: .9},
					})
					if !ok || got == nil || got.ID != "healthy" {
						t.Fatal("healthy candidate was lost")
					}
				}
				return
			}
			ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
			defer cancel()
			cmd := exec.CommandContext(ctx, os.Args[0], "-test.run=^TestSwitchWorkerPanicIsolation$/^"+stage+"$", "-test.v")
			cmd.Env = append(os.Environ(), "MUSICDL_PANIC_CHILD="+stage)
			output, err := cmd.CombinedOutput()
			if err != nil {
				t.Fatalf("worker killed child: %v\n%s", err, output)
			}
		})
	}
}

func TestNativePlaybackPanicReturnsErrorAcrossBridge(t *testing.T) {
	previous := nativePreparePlaybackSource
	t.Cleanup(func() { nativePreparePlaybackSource = previous })
	nativePreparePlaybackSource = func(*model.Song) (string, string, error) {
		panic("secret-token-and-signed-url-must-not-escape")
	}
	output, err := NativePlaybackAsset(`{"id":"one","source":"qq","name":"Track"}`, false)
	if output != "" || err == nil || !strings.Contains(err.Error(), "内部异常") || strings.Contains(err.Error(), "secret") {
		t.Fatalf("unsafe bridge panic response: %q %v", output, err)
	}
}
