package core

import (
	"reflect"
	"testing"
)

func TestOnlySixMusicPlatformsAndIndependentLocalFiles(t *testing.T) {
	want := []string{"netease", "apple", "qq", "soda", "kugou", "spotify"}
	if !reflect.DeepEqual(GetMusicPlatformNames(), want) {
		t.Fatalf("platforms=%v", GetMusicPlatformNames())
	}
	if !reflect.DeepEqual(GetAllSourceNames(), append(want, "local")) {
		t.Fatal("local file capability was lost or extra providers remain")
	}
	for _, source := range want {
		if GetSearchFunc(source) == nil || GetDownloadFunc(source) == nil || GetPlaylistDetailFunc(source) == nil || !IsMusicPlatform(source) {
			t.Fatalf("retained factory missing: %s", source)
		}
	}
}

func TestRetiredProvidersHaveNoFactoriesOrLoginRegistration(t *testing.T) {
	// Compatibility assertions, not a registration table or an active adapter.
	for _, source := range []string{"migu", "kuwo", "fivesing", "jamendo", "joox", "qianqian", "bilibili"} {
		if IsMusicPlatform(source) || GetSearchFunc(source) != nil || GetAlbumSearchFunc(source) != nil || GetPlaylistSearchFunc(source) != nil ||
			GetDownloadFunc(source) != nil || GetLyricFunc(source) != nil || GetParseFunc(source) != nil || GetParseAlbumFunc(source) != nil || GetParsePlaylistFunc(source) != nil ||
			GetTopListsFunc(source) != nil || GetTopListSongsFunc(source) != nil || GetCategoryPlaylistsFunc(source) != nil || GetQRLoginCreateFunc(source) != nil || GetQRLoginCheckFunc(source) != nil {
			t.Fatalf("retired provider is executable: %s", source)
		}
	}
}

func TestLinkDetectionCannotReviveRetiredSubdomainsOrQueryURLs(t *testing.T) {
	for _, link := range []string{"https://5sing.kugou.com/123.html", "https://music.migu.cn/?next=https://music.163.com", "https://attacker.example/music.apple.com/song/1"} {
		if got := DetectSource(link); got != "" {
			t.Fatalf("non-platform link classified as %s", got)
		}
	}
	for link, want := range map[string]string{"https://music.163.com/#/song?id=1": "netease", "https://y.qq.com/n/ryqq/songDetail/id": "qq", "https://www.kugou.com/song/#hash=id": "kugou", "https://qishui.douyin.com/s/id/": "soda", "https://music.apple.com/song/id": "apple", "https://open.spotify.com/track/id": "spotify"} {
		if got := DetectSource(link); got != want {
			t.Fatalf("retained link=%s got=%s want=%s", link, got, want)
		}
	}
}

func TestNativeAppleAccountDoesNotReuseLegacyCookieOrDeleteIt(t *testing.T) {
	priorMode, priorCookie := nativeAppleAuthorization.Load(), CM.Get("apple")
	t.Cleanup(func() { nativeAppleAuthorization.Store(priorMode); CM.SetAll(map[string]string{"apple": priorCookie}) })
	CM.SetAll(map[string]string{"apple": "legacy-user-token"})
	EnableNativeAppleAuthorization()
	if appleCredential(CM.Get("apple")) != "" || CM.Get("apple") != "legacy-user-token" {
		t.Fatal("native credential isolation changed stored data or reused a legacy token")
	}
	request, err := BuildSourceRequest("GET", "https://audio.example/preview", "apple", "")
	if err != nil || request.Header.Get("Cookie") != "" {
		t.Fatal("legacy Apple credentials attached to native audio")
	}
}
