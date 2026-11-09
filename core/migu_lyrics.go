package core

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"github.com/guohuiyuan/music-lib/model"
	"io"
	"net/http"
	"net/url"
	"strings"
)

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
