package web

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestPlaylistImportFormats(t *testing.T) {
	for _, tt := range []struct {
		format, text string
		count        int
	}{
		{"text", "周杰伦 - 晴天\n\n林俊杰 - 江南", 2},
		{"csv", "title,artist,album\r\n\"Hello, World\",A,Album\r\n", 1},
		{"json", `{"tracks":[{"title":"晴天","artists":["周杰伦"],"album":"叶惠美"}]}`, 1},
		{"m3u8", "#EXTM3U\n#EXTINF:269,周杰伦 - 晴天\nC:\\Music\\晴天.mp3\nhttps://example.com/stream.m3u8", 2},
	} {
		t.Run(tt.format, func(t *testing.T) {
			rows, e := parseImportText(tt.text, tt.format)
			if e != nil || len(rows) != tt.count {
				t.Fatalf("rows=%v err=%v", rows, e)
			}
			if rows[0].ID == "" {
				t.Fatal("missing metadata identity")
			}
		})
	}
	for _, tt := range []struct{ format, text string }{
		{"csv", "title,artist\n\"unterminated"}, {"csv", "title,artist\nA,B,C"}, {"json", "{"}, {"json", `[{"artist":"A"}]`}, {"m3u8", "#EXT-X-TARGETDURATION:3"}, {"text", strings.Repeat("x", 5<<20+1)}, {"text", strings.Repeat("A - Song\n", 5001)},
	} {
		if _, e := parseImportText(tt.text, tt.format); e == nil {
			t.Fatalf("accepted malformed %s", tt.format)
		}
	}
	rows, _ := parseImportText("周杰伦 - 晴天", "text")
	if rows[0].Artist != "周杰伦" || rows[0].Title != "晴天" {
		t.Fatal(rows)
	}
}

func TestPlaylistImportURLBoundary(t *testing.T) {
	good := map[string]string{"https://music.163.com/#/playlist?id=3778678": "netease", "https://y.qq.com/n/ryqq/playlist/9209322004": "qq", "https://y.qq.com/n2/m/share/details/taoge.html?id=9209322004": "qq", "https://open.spotify.com/playlist/37i9dQZF1DXcBWIGoYBM5M": "spotify"}
	for raw, s := range good {
		ref, e := parseImportPlaylistURL(raw, s)
		if e != nil || ref.Source != s || ref.ID == "" {
			t.Fatalf("%s %v", raw, e)
		}
	}
	for _, raw := range []string{"http://music.163.com/playlist?id=1", "https://127.0.0.1/playlist?id=1", "https://music.163.com.evil.test/playlist?id=1", "https://user@music.163.com/playlist?id=1", "https://music.163.com:443/playlist?id=1", "https://music.163.com/song?id=1", "https://music.163.com/playlist?id=1%26url=https://localhost", "https://y.qq.com/n/ryqq/playlist/../1", "https://open.spotify.com/playlist/abc"} {
		if _, e := parseImportPlaylistURL(raw, ""); e == nil {
			t.Fatalf("unsafe link accepted: %s", raw)
		}
	}
	if _, e := parseImportPlaylistURL("https://music.163.com/playlist?id=1", "qq"); e == nil {
		t.Fatal("cross-platform mismatch accepted")
	}
	if normalizedImportPath("https://example.com/audio.mp3") != "" {
		t.Fatal("stream treated as a file")
	}
	if normalizedImportPath("file:///C:/Music/A.mp3") != normalizedImportPath(`C:\Music\A.mp3`) {
		t.Fatal("path normalization mismatch")
	}
}

func importTestDB(t *testing.T) Collection {
	t.Helper()
	root := t.TempDir()
	t.Setenv("MUSIC_DL_CONFIG_DB", filepath.Join(root, "settings.db"))
	t.Setenv("MUSIC_DL_FAVORITES_DB", filepath.Join(root, "no-favorites.db"))
	resetCollectionStateForTest()
	t.Cleanup(resetCollectionStateForTest)
	InitDB()
	c := Collection{Name: "Import destination", Kind: collectionKindManual}
	if e := db.Create(&c).Error; e != nil {
		t.Fatal(e)
	}
	return c
}
func commitTestSongs(t *testing.T, id uint, songs []nativeClientSong) (importCommitResult, error) {
	t.Helper()
	b, _ := json.Marshal(songs)
	i, _ := json.Marshal(fmt.Sprint(id))
	return commitImportSongs(map[string]json.RawMessage{"id": i, "songs": b})
}
func TestPlaylistImportAtomicOrderPersistenceAndIsolation(t *testing.T) {
	c := importTestDB(t)
	other := Collection{Name: "Untouched"}
	db.Create(&other)
	old := SavedSong{CollectionID: c.ID, SongID: "old", Source: "local", Name: "Existing"}
	db.Create(&old)
	songs := []nativeClientSong{{ID: "1", Source: "netease", Name: "First", Artist: "A", Album: "Album", Extra: `{"keep":"yes"}`}, {ID: "2", Source: "qq", Name: "Second", Artist: "B"}}
	r, e := commitTestSongs(t, c.ID, songs)
	if e != nil || r.Added != 2 {
		t.Fatalf("%+v %v", r, e)
	}
	songs[0].Extra = `{"transient":"different"}`
	r, e = commitTestSongs(t, c.ID, songs)
	if e != nil || r.Duplicates != 2 || r.Added != 0 {
		t.Fatalf("retry %+v %v", r, e)
	}
	bad := append([]nativeClientSong{{ID: "third", Source: "netease", Name: "Must rollback"}}, nativeClientSong{ID: "bad", Source: "qq"})
	if _, e = commitTestSongs(t, c.ID, bad); e == nil {
		t.Fatal("bad batch accepted")
	}
	CloseDB()
	InitDB()
	loaded, e := loadSavedSongs(c.ID)
	if e != nil || len(loaded) != 3 || loaded[0].ID != "old" || loaded[1].Name != "First" || loaded[2].Name != "Second" || loaded[1].Album != "Album" {
		t.Fatalf("persisted rows %+v %v", loaded, e)
	}
	var n int64
	db.Model(&SavedSong{}).Where("collection_id = ?", other.ID).Count(&n)
	if n != 0 {
		t.Fatal("other playlist changed")
	}
}

func TestPlaylistImportPlaceholderReplacement(t *testing.T) {
	c := importTestDB(t)
	p := nativeClientSong{ID: "metadata-key", Source: "import-metadata", Name: "Song", Artist: "Artist", Extra: `{"isrc":"USABC1234567","musicdl_import_key":"metadata-key"}`}
	if _, e := commitTestSongs(t, c.ID, []nativeClientSong{p}); e != nil {
		t.Fatal(e)
	}
	p.ID = "actual"
	p.Source = "netease"
	if _, e := commitTestSongs(t, c.ID, []nativeClientSong{p}); e != nil {
		t.Fatal(e)
	}
	s, e := loadSavedSongs(c.ID)
	if e != nil || len(s) != 1 || s[0].Source != "netease" {
		t.Fatalf("%+v %v", s, e)
	}
}

func TestPlaylistImportHTTPRefusesRedirectsAndLimits(t *testing.T) {
	hits := 0
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		hits++
		http.Redirect(w, r, "http://127.0.0.1/private", 302)
	}))
	defer server.Close()
	var out interface{}
	if e := importGetJSON(server.URL, "", &out); e == nil || hits != 1 {
		t.Fatalf("redirect followed: %d %v", hits, e)
	}
	limited := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(429) }))
	defer limited.Close()
	if e := importGetJSON(limited.URL, "", &out); e == nil || !strings.Contains(e.Error(), "限流") {
		t.Fatal(e)
	}
}

// Explicit real-network acceptance. An unavailable provider fails, never skips
// into a claimed success. Uses public metadata and an isolated temporary DB.
func TestPlaylistImportRealPublicPages(t *testing.T) {
	if os.Getenv("MUSICDL_IMPORT_LIVE") != "1" {
		t.Skip("opt-in public network acceptance")
	}
	c := importTestDB(t)
	for _, tt := range []struct{ source, url string }{{"netease", "https://music.163.com/playlist?id=3778678"}, {"qq", "https://y.qq.com/n/ryqq/playlist/9209322004"}} {
		t.Run(tt.source, func(t *testing.T) {
			offset := 0
			all := []importTrack{}
			total := 0
			for n := 0; n < 100; n++ {
				p := map[string]json.RawMessage{}
				for k, v := range map[string]interface{}{"url": tt.url, "source": tt.source, "offset": offset} {
					p[k], _ = json.Marshal(v)
				}
				page, e := readImportPlaylistPage(p)
				if e != nil {
					t.Fatal(e)
				}
				all = append(all, page.Tracks...)
				total = page.Total
				t.Logf("source=%s name=%s offset=%d read=%d total=%d", tt.source, page.Title, offset, len(page.Tracks), total)
				offset = page.Next
				if !page.More {
					break
				}
			}
			if len(all) != total || total == 0 {
				t.Fatalf("incomplete real import %d/%d", len(all), total)
			}
			for start := 0; start < len(all); start += 100 {
				songs := []nativeClientSong{}
				for _, track := range all[start:min(start+100, len(all))] {
					b, _ := json.Marshal(track)
					extra, _ := json.Marshal(map[string]string{"musicdl_import_metadata": string(b)})
					songs = append(songs, nativeClientSong{ID: track.ID, Source: "import-metadata", Name: track.Title, Artist: track.Artist, Album: track.Album, Duration: track.Duration, Extra: string(extra)})
				}
				if _, e := commitTestSongs(t, c.ID, songs); e != nil {
					t.Fatal(e)
				}
			}
		})
	}
	CloseDB()
	InitDB()
	songs, e := loadSavedSongs(c.ID)
	if e != nil || len(songs) == 0 {
		t.Fatal("real metadata import failed persistence", e)
	}
	t.Logf("real imports persisted %d metadata rows; playback not claimed", len(songs))
}
