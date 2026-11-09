package web

import "testing"

func TestDecodeNativeSongExtra(t *testing.T) {
	for _, raw := range []string{
		`{"id":"123","source":"netease","duration":180,"extra":{"quality":"lossless"}}`,
		`{"id":"123","source":"netease","duration":180,"extra":"{\"quality\":\"lossless\"}"}`,
	} {
		song, err := decodeNativeSong(raw)
		if err != nil {
			t.Fatal(err)
		}
		if song.ID != "123" || song.Duration != 180 || song.Extra["quality"] != "lossless" {
			t.Fatalf("source metadata lost: %#v", song)
		}
	}
}

func TestNativePlaybackRejectsIncompleteInput(t *testing.T) {
	for _, raw := range []string{`{}`, `{"id":"1"}`, `{"source":"qq"}`, `{`, `{"id":"1","source":"qq","extra":42}`} {
		if _, err := decodeNativeSong(raw); err == nil {
			t.Fatalf("accepted invalid input %s", raw)
		}
	}
}

func TestNativeSongPreservesAlbumAndAuthorizationMetadata(t *testing.T) {
	song, err := decodeNativeSong(`{"id":"one","source":"qq","album_id":"album","link":"https://example.com/one","is_vip":true}`)
	if err != nil {
		t.Fatal(err)
	}
	if song.AlbumID != "album" || song.Link != "https://example.com/one" || !song.IsVIP {
		t.Fatalf("metadata lost: %#v", song)
	}
}

func TestNativePlaybackRejectsLocalTraversal(t *testing.T) {
	// Local IDs must go through the original library's path validation.
	if _, err := NativePlaybackAsset(`{"id":"Li4vc2VjcmV0Lm1wMw","source":"local"}`, false); err == nil {
		t.Fatal("accepted local path traversal")
	}
}
