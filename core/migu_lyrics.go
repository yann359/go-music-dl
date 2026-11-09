package core

// The library's Migu implementation uses an uncancellable two-minute client.
// Keep the same resource API, headers and authorization, but bound each request,
// reject partial bodies, and resolve a fresh lyric URL on every retry.
import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"regexp"
	"strings"
	"unicode/utf8"

	"github.com/guohuiyuan/music-lib/model"
	"golang.org/x/text/encoding/simplifiedchinese"
	"golang.org/x/text/encoding/unicode"
)

var lyricTimeMarkers = regexp.MustCompile(`\[\d+:\d+(?:\.\d+)?\]|<\d+:\d+(?:\.\d+)?>`)
var lyricHeaderLine = regexp.MustCompile(`^\[[A-Za-z]+:[^\]]*\]$`)

type LyricFailure struct {
	Kind string
	Err  error
}

func (e *LyricFailure) Error() string { return e.Kind + ": " + e.Err.Error() }
func (e *LyricFailure) Unwrap() error { return e.Err }

func LyricFailureKind(err error) string {
	if err == nil {
		return ""
	}
	var failure *LyricFailure
	if errors.As(err, &failure) {
		return failure.Kind
	}
	text := strings.ToLower(err.Error())
	// Legacy providers return wrapped string errors rather than typed statuses.
	if strings.Contains(text, "decrypt") || strings.Contains(text, "parse") || strings.Contains(text, "decode") {
		return "format"
	}
	if strings.Contains(text, "not found") || strings.Contains(text, "status 404") || strings.Contains(text, "empty") {
		return "missing"
	}
	if strings.Contains(text, "status 429") || strings.Contains(text, "status 5") {
		return "server"
	}
	if strings.Contains(text, "status 401") || strings.Contains(text, "status 403") {
		return "authorization"
	}
	var network interface{ Timeout() bool }
	if errors.Is(err, context.DeadlineExceeded) || errors.Is(err, io.EOF) || errors.Is(err, io.ErrUnexpectedEOF) || errors.As(err, &network) || strings.Contains(text, "connection reset") {
		return "network"
	}
	return "unavailable"
}
func LyricRetryable(err error) bool {
	kind := LyricFailureKind(err)
	return kind == "network" || kind == "server"
}

func ReadMiguLyrics(ctx context.Context, client *http.Client, song *model.Song) (string, error) {
	contentID := strings.Split(song.ID, "|")[0]
	if song.Extra["content_id"] != "" {
		contentID = song.Extra["content_id"]
	}
	if contentID == "" {
		return "", &LyricFailure{"missing", errors.New("invalid migu id")}
	}
	api := "http://c.musicapp.migu.cn/MIGUM2.0/v1.0/content/resourceinfo.do?" + url.Values{"resourceId": {contentID}, "resourceType": {"2"}}.Encode()
	body, _, err := readLyricHTTP(ctx, client, api, UA_Mobile, Ref_Migu, CM.Get("migu"))
	if err != nil {
		return "", err
	}
	var info struct {
		Code     string `json:"code"`
		Resource []struct {
			LrcURL   string `json:"lrcUrl"`
			LyricURL string `json:"lyricUrl"`
		} `json:"resource"`
	}
	if err = json.Unmarshal(body, &info); err != nil {
		return "", &LyricFailure{"format", fmt.Errorf("migu metadata: %w", err)}
	}
	if info.Code != "" && info.Code != "000000" {
		return "", &LyricFailure{"unavailable", fmt.Errorf("migu code %s", info.Code)}
	}
	if len(info.Resource) == 0 {
		return "", &LyricFailure{"missing", errors.New("migu resource not found")}
	}
	link := info.Resource[0].LrcURL
	if link == "" {
		link = info.Resource[0].LyricURL
	}
	if link == "" {
		return "", &LyricFailure{"missing", errors.New("migu lyric url not found")}
	}
	link = strings.Replace(link, "http://", "https://", 1)
	body, charset, err := readLyricHTTP(ctx, client, link, UA_Common, "https://y.migu.cn/", CM.Get("migu"))
	if err != nil {
		return "", err
	}
	return DecodeLyricText(body, charset)
}

func readLyricHTTP(ctx context.Context, client *http.Client, link, agent, referer, cookie string) ([]byte, string, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, link, nil)
	if err != nil {
		return nil, "", &LyricFailure{"format", err}
	}
	req.Header.Set("User-Agent", agent)
	req.Header.Set("Referer", referer)
	req.Header.Set("Cookie", cookie)
	resp, err := client.Do(req)
	if err != nil {
		return nil, "", err
	}
	defer func() { _ = resp.Body.Close() }()
	if resp.StatusCode != http.StatusOK {
		kind := "unavailable"
		switch {
		case resp.StatusCode == 404 || resp.StatusCode == 410:
			kind = "missing"
		case resp.StatusCode == 401 || resp.StatusCode == 403:
			kind = "authorization"
		case resp.StatusCode == 429 || resp.StatusCode >= 500:
			kind = "server"
		}
		return nil, "", &LyricFailure{kind, fmt.Errorf("lyric HTTP status %d", resp.StatusCode)}
	}
	const limit = 2 << 20
	body, err := io.ReadAll(io.LimitReader(resp.Body, limit+1))
	if err != nil {
		return nil, "", err
	} // never parse/cache the partial prefix
	if len(body) > limit {
		return nil, "", &LyricFailure{"format", errors.New("lyric exceeds 2 MB")}
	}
	if resp.ContentLength >= 0 && int64(len(body)) != resp.ContentLength {
		return nil, "", io.ErrUnexpectedEOF
	}
	return body, resp.Header.Get("Content-Type"), nil
}

func DecodeLyricText(body []byte, contentType string) (string, error) {
	charset := strings.ToLower(contentType)
	var err error
	if len(body) >= 2 && ((body[0] == 0xff && body[1] == 0xfe) || (body[0] == 0xfe && body[1] == 0xff)) {
		body, err = unicode.UTF16(unicode.LittleEndian, unicode.UseBOM).NewDecoder().Bytes(body)
	} else if strings.Contains(charset, "gbk") || strings.Contains(charset, "gb18030") || strings.Contains(charset, "gb2312") {
		body, err = simplifiedchinese.GB18030.NewDecoder().Bytes(body)
	}
	if err != nil || !utf8.Valid(body) || strings.Contains(string(body), "\ufffd") {
		return "", &LyricFailure{"format", errors.New("unsupported or invalid lyric encoding")}
	}
	text := strings.TrimSpace(strings.TrimPrefix(string(body), "\ufeff"))
	lower := strings.ToLower(text)
	if strings.Contains(lower, "<html") || strings.HasPrefix(lower, "<!doctype") || strings.HasPrefix(lower, "<?xml") || strings.HasPrefix(text, "{") {
		return "", &LyricFailure{"format", errors.New("response is not lyric text")}
	}
	if text == "" {
		return "", nil
	}
	for _, line := range strings.Split(text, "\n") {
		line = strings.TrimSpace(line)
		if lyricHeaderLine.MatchString(line) {
			continue
		}
		if strings.TrimSpace(lyricTimeMarkers.ReplaceAllString(line, "")) != "" {
			return text, nil
		}
	}
	return "", &LyricFailure{"missing", errors.New("lyric has no text")}
}
