package core

import (
	"reflect"
	"testing"
)

func TestAllOriginalMusicPlatformsAndIndependentLocalFiles(t *testing.T) {
	want := []string{"netease", "apple", "qq", "soda", "kugou", "spotify", "kuwo", "migu", "fivesing", "jamendo", "joox", "qianqian", "bilibili"}
	if !reflect.DeepEqual(GetMusicPlatformNames(), want) {
		t.Fatalf("platforms=%v", GetMusicPlatformNames())
	}
	if !reflect.DeepEqual(GetAllSourceNames(), append(want, "local")) {
		t.Fatal("local file capability lost")
	}
	for _, source := range want {
		if GetSearchFunc(source) == nil || GetDownloadFunc(source) == nil || GetPlaylistDetailFunc(source) == nil || !IsMusicPlatform(source) {
			t.Fatalf("missing factory: %s", source)
		}
	}
	if GetSearchFunc("unknown") != nil || IsMusicPlatform("unknown") {
		t.Fatal("unknown provider enabled")
	}
	for _, source := range []string{"apple", "spotify", "migu", "kuwo", "fivesing", "jamendo", "joox", "qianqian", "bilibili"} {
		if GetLyricFunc(source) == nil || GetParseFunc(source) == nil || GetParsePlaylistFunc(source) == nil {
			t.Fatalf("missing source operation: %s", source)
		}
	}
	if GetQRLoginCreateFunc("bilibili") == nil || GetQRLoginCheckFunc("bilibili") == nil {
		t.Fatal("Bilibili login missing")
	}
}

func TestLinkDetectionUsesHostRatherThanQueryOrBrandSubstring(t *testing.T) {
	for _, link := range []string{"https://attacker.example/music.apple.com/song/1", "https://attacker.example/?next=https://music.migu.cn", "https://music.migu.cn.attacker.example/1"} {
		if got := DetectSource(link); got != "" {
			t.Fatalf("unsafe classification: %s", got)
		}
	}
	for link, want := range map[string]string{
		"https://5sing.kugou.com/123.html": "fivesing", "https://music.migu.cn/?next=https://music.163.com": "migu", "https://www.kuwo.cn/play_detail/1": "kuwo",
		"https://www.jamendo.com/track/1": "jamendo", "https://www.joox.com/song/1": "joox", "https://music.taihe.com/song/1": "qianqian", "https://b23.tv/1": "bilibili",
		"https://music.163.com/#/song?id=1": "netease", "https://y.qq.com/n/ryqq/songDetail/id": "qq", "https://www.kugou.com/song/#hash=id": "kugou",
		"https://qishui.douyin.com/s/id/": "soda", "https://music.apple.com/song/id": "apple", "https://open.spotify.com/track/id": "spotify"} {
		if got := DetectSource(link); got != want {
			t.Fatalf("%s got=%s want=%s", link, got, want)
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
