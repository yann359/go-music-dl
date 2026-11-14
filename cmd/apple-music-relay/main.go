// Standalone optional service. Keep TLS termination and access logs under your
// control; never log request bodies, Authorization, cookies, fragments or query.
package main

import (
	"log"
	"net/http"
	"os"
	"time"

	"github.com/guohuiyuan/go-music-dl/internal/applemusicrelay"
)

func main() {
	keyData, err := os.ReadFile(os.Getenv("APPLE_MEDIA_KEY_FILE"))
	if err != nil {
		log.Fatal("Apple relay unavailable: configure readable server-only APPLE_MEDIA_KEY_FILE")
	}
	key, err := applemusicrelay.ParsePrivateKey(keyData)
	if err != nil {
		log.Fatal("Apple relay unavailable: invalid signing key")
	}
	handler, err := applemusicrelay.New(applemusicrelay.Config{Origin: os.Getenv("APPLE_MUSIC_ORIGIN"), Callback: os.Getenv("APPLE_MUSIC_CALLBACK"), TeamID: os.Getenv("APPLE_TEAM_ID"), KeyID: os.Getenv("APPLE_MEDIA_KEY_ID"), PrivateKey: key})
	if err != nil {
		log.Fatal("Apple relay unavailable: verify HTTPS origin, callback, Team ID and Media Services key configuration")
	}
	// Expose only through a trusted HTTPS reverse proxy. No public HTTP listener.
	server := http.Server{Addr: "127.0.0.1:8787", Handler: handler, ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 30 * time.Second, WriteTimeout: 45 * time.Second, IdleTimeout: 60 * time.Second, MaxHeaderBytes: 8192}
	log.Print("Apple Music relay listening on loopback; HTTPS proxy required")
	if err := server.ListenAndServe(); err != http.ErrServerClosed {
		log.Fatal("Apple relay stopped")
	}
}
