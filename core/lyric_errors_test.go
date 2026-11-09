package core

import (
	"golang.org/x/text/encoding/simplifiedchinese"
	"testing"
)

func TestLyricDecodingAndFormatFailures(t *testing.T) {
	gbk, _ := simplifiedchinese.GB18030.NewEncoder().Bytes([]byte("[00:01]中文歌词"))
	for _, tc := range []struct {
		data          []byte
		charset, want string
	}{
		{[]byte("\xef\xbb\xbf[00:01]歌词"), "text/plain", "[00:01]歌词"},
		{gbk, "text/plain; charset=gbk", "[00:01]中文歌词"},
		{[]byte{0xff, 0xfe, 0x60, 0x4f, 0x7d, 0x59}, "text/plain", "你好"},
	} {
		got, err := DecodeLyricText(tc.data, tc.charset)
		if err != nil || got != tc.want {
			t.Fatalf("decode=%q err=%v", got, err)
		}
	}
	for _, data := range [][]byte{[]byte("<html>server error</html>"), []byte("{\"error\":true}"), {0xff, 0xff}} {
		if _, err := DecodeLyricText(data, "text/plain"); LyricFailureKind(err) != "format" || LyricRetryable(err) {
			t.Fatalf("invalid format accepted: %v", err)
		}
	}
	if _, err := DecodeLyricText([]byte("[ti:Title]\n[ar:Artist]\n[00:01.00]"), "text/plain"); LyricFailureKind(err) != "missing" {
		t.Fatalf("metadata-only lyric accepted: %v", err)
	}
}
