package spotify

import (
	"errors"
	"github.com/guohuiyuan/music-lib/model"
	"net/http"
	"strconv"
)

// Uses the existing Keychain-backed native OAuth session, never a web-player
// token. Return one page so iOS can checkpoint, cancel and respect rate limits.
func (c *Client) ImportPlaylistPage(id string, offset int) (model.Playlist, []model.Song, int, int, error) {
	var p playlist
	if !validID(id) || offset < 0 || offset >= 5000 {
		return model.Playlist{}, nil, 0, 0, errors.New("invalid Spotify playlist page")
	}
	c.http.CheckRedirect = func(*http.Request, []*http.Request) error { return errors.New("Spotify redirect blocked") }
	if e := c.get("/v1/playlists/"+id, &p); e != nil {
		return model.Playlist{}, nil, 0, 0, e
	}
	var payload struct {
		Items []struct {
			Track *track
			Item  *track
		}
		Total int
		Next  string
	}
	if e := c.get("/v1/playlists/"+id+"/items?limit=50&offset="+strconv.Itoa(offset), &payload); e != nil {
		return model.Playlist{}, nil, 0, 0, e
	}
	if payload.Total > 5000 {
		return collection(p), nil, 0, 0, errors.New("Spotify playlist exceeds 5000 tracks")
	}
	if payload.Total < offset+len(payload.Items) || p.Name == "" {
		return collection(p), nil, 0, 0, errors.New("Spotify playlist response is incomplete")
	}
	rows := []model.Song{}
	for i, v := range payload.Items {
		t := v.Item
		if t == nil {
			t = v.Track
		}
		if t == nil || t.ID == "" {
			rows = append(rows, model.Song{ID: "unavailable-" + strconv.Itoa(offset+i), Name: "不可用曲目", Source: "spotify"})
			continue
		}
		s := song(*t)
		s.Extra["isrc"] = t.ExternalIDs.ISRC
		rows = append(rows, s)
	}
	next := offset + len(payload.Items)
	if next < payload.Total && next <= offset {
		return collection(p), nil, 0, 0, errors.New("Spotify returned an incomplete page")
	}
	return collection(p), rows, next, payload.Total, nil
}
