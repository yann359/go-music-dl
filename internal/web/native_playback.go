package web

// The iOS host calls these functions in-process. Audio never passes through
// the loopback HTTP server or the WebView.
import (
	"encoding/json"
	"errors"
	"net/url"
	"strings"

	"github.com/guohuiyuan/go-music-dl/core"
	"github.com/guohuiyuan/music-lib/model"
)

type nativeSong struct {
	ID       string          `json:"id"`
	Source   string          `json:"source"`
	Name     string          `json:"name"`
	Artist   string          `json:"artist"`
	Album    string          `json:"album"`
	AlbumID  string          `json:"album_id"`
	Link     string          `json:"link"`
	IsVIP    bool            `json:"is_vip"`
	Cover    string          `json:"cover"`
	Duration int             `json:"duration"`
	Extra    json.RawMessage `json:"extra"`
}

func decodeNativeSong(raw string) (*model.Song, error) {
	var input nativeSong
	if err := json.Unmarshal([]byte(raw), &input); err != nil {
		return nil, err
	}
	if strings.TrimSpace(input.ID) == "" || strings.TrimSpace(input.Source) == "" {
		return nil, errors.New("missing song id or source")
	}
	var extra map[string]string
	if len(input.Extra) > 0 && string(input.Extra) != "null" {
		var encoded string
		if json.Unmarshal(input.Extra, &encoded) == nil {
			extra = parseSongExtraQuery(encoded)
		} else if err := json.Unmarshal(input.Extra, &extra); err != nil {
			return nil, err
		}
	}
	return &model.Song{ID: input.ID, Source: input.Source, Name: input.Name,
		Artist: input.Artist, Album: input.Album, Cover: input.Cover,
		Duration: input.Duration, Extra: extra, AlbumID: input.AlbumID, Link: input.Link, IsVIP: input.IsVIP}, nil
}

// NativePlaybackAsset resolves a single authorized source. Temporary decoded
// files belong to the native host after this function succeeds.
func NativePlaybackAsset(raw string, fallback bool) (output string, err error) {
	defer func() {
		if recover() != nil {
			output = ""
			err = nativePanicError("playback", "resolve")
		}
	}()
	song, err := decodeNativeSong(raw)
	if err != nil {
		return "", err
	}
	if !core.IsMusicPlatform(song.Source) && !isLocalMusicSource(song.Source) {
		return "", errors.New("此来源已移除，歌曲记录仍保留；可在现有来源中重新搜索或播放本地文件")
	}
	if fallback && !isLocalMusicSource(song.Source) {
		song, _, err = findBestSwitchSong(song.Name, song.Artist, song.Source, "", song.Duration)
		if err != nil {
			return "", err
		}
	}
	var assetURL, temporary string
	headers := map[string]string{}
	if isLocalMusicSource(song.Source) {
		track, err := localMusicTrackByID(song.ID)
		if err != nil {
			return "", err
		}
		assetURL = (&url.URL{Scheme: "file", Path: track.absPath}).String()
	} else {
		resolved, temp, err := nativePreparePlaybackSource(song)
		if err != nil {
			return "", err
		}
		temporary = temp
		if temp != "" {
			assetURL = (&url.URL{Scheme: "file", Path: resolved}).String()
		} else {
			u, err := url.Parse(resolved)
			if err != nil || u.Hostname() == "" || (u.Scheme != "https" && u.Scheme != "http") {
				return "", errors.New("source did not return an HTTP audio URL")
			}
			if u.Hostname() == "localhost" || u.Hostname() == "127.0.0.1" || u.Hostname() == "::1" {
				return "", errors.New("native audio must not depend on the loopback server")
			}
			req, err := core.BuildSourceRequest("GET", resolved, song.Source, "")
			if err != nil {
				return "", err
			}
			for name := range req.Header {
				headers[name] = req.Header.Get(name)
			}
			assetURL = resolved
		}
	}
	// Never send this descriptor (which can contain source cookies) to JavaScript.
	result, err := json.Marshal(map[string]interface{}{"url": assetURL, "headers": headers,
		"temporary": temporary, "source": song.Source, "id": song.ID})
	return string(result), err
}

var nativePreparePlaybackSource = core.PreparePlaybackSource
