package web

import (
	"errors"
	"strings"
	"testing"

	"github.com/guohuiyuan/go-music-dl/core"
	"github.com/guohuiyuan/music-lib/model"
)

func TestLegacyCredentialsNeedActualValidation(t *testing.T) {
	original := nativeAccountPlaylists
	t.Cleanup(func() { nativeAccountPlaylists = original; core.CM.SetAll(map[string]string{"qq": ""}) })
	core.CM.SetAll(map[string]string{"qq": ""})
	called := false
	nativeAccountPlaylists = func(string) core.UserPlaylistsFunc {
		return func(int, int) ([]model.Playlist, error) { called = true; return nil, nil }
	}
	params := mapJSONForNativeTest(t, `{"source":"qq"}`)
	if got := nativeValidateLegacyAccount(params).(map[string]string)["status"]; got != "disconnected" || called {
		t.Fatal("missing credentials triggered account API")
	}
	core.CM.SetAll(map[string]string{"qq": "fixture"})
	if got := nativeValidateLegacyAccount(params).(map[string]string)["status"]; got != "connected" || !called {
		t.Fatal("successful validation not recognized")
	}
	nativeAccountPlaylists = func(string) core.UserPlaylistsFunc {
		return func(int, int) ([]model.Playlist, error) { return nil, errors.New("login expired") }
	}
	if got := nativeValidateLegacyAccount(params).(map[string]string)["status"]; got != "expired" {
		t.Fatal("expired credential accepted")
	}
}

func TestRetiredSavedSongsAndImportedMetadataAreNotDeleted(t *testing.T) {
	initCollectionDBForTest(t)
	collection := Collection{Name: "Keep my history", Kind: collectionKindManual, Source: "local"}
	if err := db.Create(&collection).Error; err != nil {
		t.Fatal(err)
	}
	saved := SavedSong{CollectionID: collection.ID, SongID: "old-song", Source: "retired-provider", Name: "Preserved", Artist: "Artist"}
	if err := db.Create(&saved).Error; err != nil {
		t.Fatal(err)
	}
	songs, err := loadCollectionSongs(&collection)
	if err != nil || len(songs) != 1 || songs[0].Name != "Preserved" {
		t.Fatal("old song data disappeared")
	}
	_, err = NativePlaybackAsset(`{"id":"old-song","source":"retired-provider","name":"Preserved"}`, true)
	if err == nil || !strings.Contains(err.Error(), "记录仍保留") {
		t.Fatal("retired entry silently played via another adapter")
	}
	imported := Collection{Name: "Old imported", Kind: collectionKindImported, Source: "retired-provider", ExternalID: "old", TrackCount: 12}
	if err = db.Create(&imported).Error; err != nil {
		t.Fatal(err)
	}
	if _, err = loadCollectionSongs(&imported); err == nil || !strings.Contains(err.Error(), "仍保留") {
		t.Fatal("missing source was not explained")
	}
	var count int64
	db.Model(&SavedSong{}).Where("collection_id = ?", collection.ID).Count(&count)
	if count != 1 {
		t.Fatal("reading compatibility entries changed saved data")
	}
	var fetched Collection
	if err = db.First(&fetched, imported.ID).Error; err != nil || fetched.TrackCount != 12 {
		t.Fatal("imported metadata was reset")
	}
}

func TestNativeAccountsNeverExposeRetiredOrOAuthDatabaseCredentials(t *testing.T) {
	core.CM.SetAll(map[string]string{"retired-provider": "keep-in-db", "spotify": "old-secret", "apple": "old-user-token", "qq": "fixture"})
	t.Cleanup(func() {
		core.CM.SetAll(map[string]string{"retired-provider": "", "spotify": "", "apple": "", "qq": ""})
	})
	data, err := NativeClientRequest(`{"action":"cookies.get"}`)
	if err != nil || strings.Contains(data, "old-secret") || strings.Contains(data, "old-user-token") || strings.Contains(data, "keep-in-db") {
		t.Fatal("inactive/official credentials exposed to legacy UI")
	}
	if core.CM.Get("retired-provider") != "keep-in-db" {
		t.Fatal("legacy credentials were destructively removed")
	}
	if _, err = NativeClientRequest(`{"action":"cookies.save","params":{"cookies":{"spotify":"not-oauth"}}}`); err == nil {
		t.Fatal("native Spotify accepted manual cookie login")
	}
}
