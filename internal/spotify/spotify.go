// Package spotify supplies the official-API adapter referenced by the host
// since commit 81eedc6 but absent from its pinned music-lib dependency.
// It only exposes API metadata and authorized preview URLs, never full DRM audio.
package spotify

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"

	"github.com/guohuiyuan/music-lib/model"
)

type configuration struct {
	ClientID     string `json:"client_id"`
	ClientSecret string `json:"client_secret"`
	AccessToken  string `json:"access_token"`
	RefreshToken string `json:"refresh_token"`
	Market       string `json:"market"`
}

type Client struct {
	config configuration
	http   *http.Client
}

func New(raw string) *Client {
	c := &Client{http: &http.Client{Timeout: 20 * time.Second}}
	_ = json.Unmarshal([]byte(raw), &c.config)
	if c.config.Market == "" {
		c.config.Market = "US"
	}
	return c
}

func (c *Client) token() (string, error) {
	if c.config.AccessToken != "" {
		return c.config.AccessToken, nil
	}
	if c.config.ClientID == "" || c.config.ClientSecret == "" {
		return "", errors.New("Spotify requires authorized access_token or client_id/client_secret configuration")
	}
	form := url.Values{"grant_type": {"client_credentials"}}
	if c.config.RefreshToken != "" {
		form.Set("grant_type", "refresh_token")
		form.Set("refresh_token", c.config.RefreshToken)
	}
	req, _ := http.NewRequest("POST", "https://accounts.spotify.com/api/token", strings.NewReader(form.Encode()))
	req.SetBasicAuth(c.config.ClientID, c.config.ClientSecret)
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	resp, err := c.http.Do(req)
	if err != nil {
		return "", errors.New("Spotify authorization request failed")
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		return "", fmt.Errorf("Spotify authorization HTTP %d", resp.StatusCode)
	}
	var payload struct {
		Token string `json:"access_token"`
	}
	if err := json.NewDecoder(io.LimitReader(resp.Body, 1<<20)).Decode(&payload); err != nil {
		return "", err
	}
	if payload.Token == "" {
		return "", errors.New("Spotify returned no access token")
	}
	c.config.AccessToken = payload.Token
	return payload.Token, nil
}

func (c *Client) get(path string, result interface{}) error {
	if !strings.HasPrefix(path, "/v1/") || strings.Contains(path, "://") {
		return errors.New("invalid Spotify API path")
	}
	token, err := c.token()
	if err != nil {
		return err
	}
	req, err := http.NewRequest("GET", "https://api.spotify.com"+path, nil)
	if err != nil {
		return err
	}
	req.Header.Set("Authorization", "Bearer "+token)
	resp, err := c.http.Do(req)
	if err != nil {
		return errors.New("Spotify API request failed")
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		return fmt.Errorf("Spotify API HTTP %d (check account authorization and endpoint availability)", resp.StatusCode)
	}
	return json.NewDecoder(io.LimitReader(resp.Body, 8<<20)).Decode(result)
}

type image struct {
	URL string `json:"url"`
}
type artist struct {
	Name string `json:"name"`
}
type album struct {
	ID          string
	Name        string
	Images      []image
	Artists     []artist
	TotalTracks int `json:"total_tracks"`
}
type track struct {
	ID       string
	Name     string
	Artists  []artist
	Album    album
	Duration int    `json:"duration_ms"`
	Preview  string `json:"preview_url"`
}
type playlist struct {
	ID          string
	Name        string
	Description string
	Images      []image
	Owner       struct {
		Name string `json:"display_name"`
	}
	Tracks struct{ Total int }
}
type page[T any] struct {
	Items []T
	Next  string
}

func cover(images []image) string {
	if len(images) > 0 {
		return images[0].URL
	}
	return ""
}
func artists(values []artist) string {
	names := make([]string, 0, len(values))
	for _, v := range values {
		names = append(names, v.Name)
	}
	return strings.Join(names, " / ")
}
func song(t track) model.Song {
	return model.Song{ID: t.ID, Name: t.Name, Artist: artists(t.Artists), Album: t.Album.Name,
		AlbumID: t.Album.ID, Duration: t.Duration / 1000, Source: "spotify", Cover: cover(t.Album.Images),
		Link: "https://open.spotify.com/track/" + t.ID, Ext: "mp3", Extra: map[string]string{"preview_url": t.Preview}}
}
func collection(p playlist) model.Playlist {
	return model.Playlist{ID: p.ID, Name: p.Name, Description: p.Description, Cover: cover(p.Images), TrackCount: p.Tracks.Total, Creator: p.Owner.Name, Source: "spotify", Link: "https://open.spotify.com/playlist/" + p.ID}
}

func (c *Client) Search(keyword string) ([]model.Song, error) {
	var payload struct{ Tracks page[track] }
	err := c.get("/v1/search?"+url.Values{"q": {keyword}, "type": {"track"}, "limit": {"10"}, "market": {c.config.Market}}.Encode(), &payload)
	if err != nil {
		return nil, err
	}
	result := make([]model.Song, 0, len(payload.Tracks.Items))
	for _, t := range payload.Tracks.Items {
		if t.ID != "" {
			result = append(result, song(t))
		}
	}
	return result, nil
}
func (c *Client) SearchAlbum(keyword string) ([]model.Playlist, error) {
	var payload struct{ Albums page[album] }
	err := c.get("/v1/search?"+url.Values{"q": {keyword}, "type": {"album"}, "limit": {"10"}, "market": {c.config.Market}}.Encode(), &payload)
	if err != nil {
		return nil, err
	}
	result := []model.Playlist{}
	for _, a := range payload.Albums.Items {
		result = append(result, model.Playlist{ID: a.ID, Name: a.Name, Cover: cover(a.Images), Creator: artists(a.Artists), TrackCount: a.TotalTracks, Source: "spotify", Link: "https://open.spotify.com/album/" + a.ID})
	}
	return result, nil
}
func (c *Client) SearchPlaylist(keyword string) ([]model.Playlist, error) {
	var payload struct{ Playlists page[playlist] }
	err := c.get("/v1/search?"+url.Values{"q": {keyword}, "type": {"playlist"}, "limit": {"10"}}.Encode(), &payload)
	if err != nil {
		return nil, err
	}
	result := []model.Playlist{}
	for _, p := range payload.Playlists.Items {
		if p.ID != "" {
			result = append(result, collection(p))
		}
	}
	return result, nil
}
func nextPath(raw string) (string, error) {
	u, err := url.Parse(raw)
	if err != nil || u.Scheme != "https" || u.Host != "api.spotify.com" || !strings.HasPrefix(u.Path, "/v1/") {
		return "", errors.New("untrusted Spotify pagination URL")
	}
	return u.RequestURI(), nil
}
func validID(id string) bool {
	if id == "" {
		return false
	}
	for _, r := range id {
		if !(r >= 'a' && r <= 'z' || r >= 'A' && r <= 'Z' || r >= '0' && r <= '9') {
			return false
		}
	}
	return true
}
func (c *Client) GetAlbumSongs(id string) ([]model.Song, error) {
	if !validID(id) {
		return nil, errors.New("invalid Spotify album id")
	}
	var details album
	if err := c.get("/v1/albums/"+id+"?market="+url.QueryEscape(c.config.Market), &details); err != nil {
		return nil, err
	}
	path := "/v1/albums/" + id + "/tracks?limit=50&market=" + url.QueryEscape(c.config.Market)
	result := []model.Song{}
	for n := 0; path != "" && n < 200; n++ {
		var payload page[track]
		if err := c.get(path, &payload); err != nil {
			return nil, err
		}
		for _, t := range payload.Items {
			t.Album = details
			result = append(result, song(t))
		}
		if payload.Next == "" {
			break
		}
		var err error
		path, err = nextPath(payload.Next)
		if err != nil {
			return nil, err
		}
	}
	return result, nil
}
func (c *Client) GetPlaylistSongs(id string) ([]model.Song, error) {
	if !validID(id) {
		return nil, errors.New("invalid Spotify playlist id")
	}
	path := "/v1/playlists/" + id + "/items?limit=50&market=" + url.QueryEscape(c.config.Market)
	result := []model.Song{}
	for n := 0; path != "" && n < 200; n++ {
		var payload page[struct {
			Track track
			Item  track
		}]
		if err := c.get(path, &payload); err != nil {
			return nil, err
		}
		for _, entry := range payload.Items {
			t := entry.Item
			if t.ID == "" {
				t = entry.Track
			}
			if t.ID != "" {
				result = append(result, song(t))
			}
		}
		if payload.Next == "" {
			break
		}
		var err error
		path, err = nextPath(payload.Next)
		if err != nil {
			return nil, err
		}
	}
	return result, nil
}
func (c *Client) GetDownloadURL(s *model.Song) (string, error) {
	if s == nil || !validID(s.ID) {
		return "", errors.New("invalid Spotify track")
	}
	var t track
	if err := c.get("/v1/tracks/"+s.ID+"?market="+url.QueryEscape(c.config.Market), &t); err != nil {
		return "", err
	}
	if t.Preview == "" {
		return "", errors.New("Spotify API provides no authorized preview for this track; full audio is not downloadable")
	}
	u, err := url.Parse(t.Preview)
	if err != nil || u.Scheme != "https" || u.Host == "" {
		return "", errors.New("invalid Spotify preview URL")
	}
	return t.Preview, nil
}
func (c *Client) GetLyrics(*model.Song) (string, error) {
	return "", errors.New("Spotify official Web API does not expose lyrics")
}

func parseID(link, kind string) (string, error) {
	if strings.HasPrefix(link, "spotify:"+kind+":") {
		id := strings.TrimPrefix(link, "spotify:"+kind+":")
		if validID(id) {
			return id, nil
		}
	}
	u, err := url.Parse(link)
	if err == nil && u.Scheme == "https" && u.Host == "open.spotify.com" {
		parts := strings.Split(strings.Trim(u.Path, "/"), "/")
		for i, p := range parts {
			if p == kind && i+1 < len(parts) && validID(parts[i+1]) {
				return parts[i+1], nil
			}
		}
	}
	return "", errors.New("invalid Spotify link")
}
func (c *Client) Parse(link string) (*model.Song, error) {
	id, err := parseID(link, "track")
	if err != nil {
		return nil, err
	}
	var t track
	if err = c.get("/v1/tracks/"+id+"?market="+url.QueryEscape(c.config.Market), &t); err != nil {
		return nil, err
	}
	s := song(t)
	return &s, nil
}
func (c *Client) ParseAlbum(link string) (*model.Playlist, []model.Song, error) {
	id, err := parseID(link, "album")
	if err != nil {
		return nil, nil, err
	}
	var a album
	if err = c.get("/v1/albums/"+id, &a); err != nil {
		return nil, nil, err
	}
	songs, err := c.GetAlbumSongs(id)
	return &model.Playlist{ID: id, Name: a.Name, Source: "spotify", Cover: cover(a.Images), Link: "https://open.spotify.com/album/" + id, TrackCount: a.TotalTracks}, songs, err
}
func (c *Client) ParsePlaylist(link string) (*model.Playlist, []model.Song, error) {
	id, err := parseID(link, "playlist")
	if err != nil {
		return nil, nil, err
	}
	var p playlist
	if err = c.get("/v1/playlists/"+id, &p); err != nil {
		return nil, nil, err
	}
	songs, err := c.GetPlaylistSongs(id)
	value := collection(p)
	return &value, songs, err
}
func (c *Client) GetUserPlaylists(pageNumber, limit int) ([]model.Playlist, error) {
	if c.config.AccessToken == "" && c.config.RefreshToken == "" {
		return nil, errors.New("Spotify personal playlists require user OAuth authorization")
	}
	if limit < 1 || limit > 50 {
		limit = 20
	}
	if pageNumber < 1 {
		pageNumber = 1
	}
	var p page[playlist]
	if err := c.get("/v1/me/playlists?limit="+strconv.Itoa(limit)+"&offset="+strconv.Itoa((pageNumber-1)*limit), &p); err != nil {
		return nil, err
	}
	result := []model.Playlist{}
	for _, v := range p.Items {
		result = append(result, collection(v))
	}
	return result, nil
}
func (c *Client) GetPlaylistCategories() ([]model.PlaylistCategory, error) {
	var payload struct {
		Categories page[struct {
			ID   string
			Name string
		}]
	}
	if err := c.get("/v1/browse/categories?limit=50", &payload); err != nil {
		return nil, err
	}
	result := []model.PlaylistCategory{}
	for _, v := range payload.Categories.Items {
		result = append(result, model.PlaylistCategory{ID: v.ID, Name: v.Name, Source: "spotify"})
	}
	return result, nil
}
func (c *Client) GetCategoryPlaylists(id string, pageNumber, limit int) ([]model.Playlist, error) {
	if !validID(id) {
		return nil, errors.New("invalid Spotify category id")
	}
	if limit < 1 || limit > 50 {
		limit = 20
	}
	if pageNumber < 1 {
		pageNumber = 1
	}
	var payload struct{ Playlists page[playlist] }
	if err := c.get("/v1/browse/categories/"+id+"/playlists?limit="+strconv.Itoa(limit)+"&offset="+strconv.Itoa((pageNumber-1)*limit), &payload); err != nil {
		return nil, err
	}
	result := []model.Playlist{}
	for _, v := range payload.Playlists.Items {
		result = append(result, collection(v))
	}
	return result, nil
}
func (c *Client) GetRecommendedPlaylists() ([]model.Playlist, error) {
	var payload struct{ Playlists page[playlist] }
	if err := c.get("/v1/browse/featured-playlists?limit=20", &payload); err != nil {
		return nil, err
	}
	result := []model.Playlist{}
	for _, value := range payload.Playlists.Items {
		result = append(result, collection(value))
	}
	return result, nil
}

var chartDefinitions = []struct{ ID, Name, Playlist string }{
	{"global-top-50", "Global Top 50", "37i9dQZEVXbMDoHDwVN2tF"},
	{"us-top-50", "USA Top 50", "37i9dQZEVXbLRQDuF5jeBp"},
	{"uk-top-50", "UK Top 50", "37i9dQZEVXbLnolsZ8PSNw"},
	{"jp-top-50", "Japan Top 50", "37i9dQZEVXbKXQ4mDTEBXq"},
	{"au-top-50", "Australia Top 50", "37i9dQZEVXbJPcfkRz0wJ0"},
	{"ca-top-50", "Canada Top 50", "37i9dQZEVXbKj23U1GF4IR"},
}

func GetTopLists() ([]model.TopList, error) {
	result := []model.TopList{}
	for _, v := range chartDefinitions {
		result = append(result, model.TopList{ID: v.ID, Name: v.Name, Source: "spotify", Link: "https://open.spotify.com/playlist/" + v.Playlist, Extra: map[string]string{"playlist_id": v.Playlist}})
	}
	return result, nil
}
func (c *Client) GetTopLists() ([]model.TopList, error) { return GetTopLists() }
func (c *Client) GetTopListSongs(id string) ([]model.Song, error) {
	for _, v := range chartDefinitions {
		if v.ID == id {
			return c.GetPlaylistSongs(v.Playlist)
		}
	}
	return c.GetPlaylistSongs(id)
}
