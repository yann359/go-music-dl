package web

// NativeClientRequest is a data API for the SwiftUI client. Discovery calls
// share the existing source implementations; foreground library operations
// share the existing JSON routes and their write guards. This is never used
// for delivering AVPlayer audio bytes.
import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/guohuiyuan/go-music-dl/core"
	"github.com/guohuiyuan/go-music-dl/internal/spotify"
	"github.com/guohuiyuan/music-lib/model"
)

type nativeClientInput struct {
	Action string                     `json:"action"`
	Params map[string]json.RawMessage `json:"params"`
}

type nativeClientSong struct {
	ID       string `json:"id"`
	Source   string `json:"source"`
	Name     string `json:"name"`
	Artist   string `json:"artist"`
	Album    string `json:"album"`
	AlbumID  string `json:"album_id"`
	Cover    string `json:"cover"`
	Duration int    `json:"duration"`
	Extra    string `json:"extra"`
	Link     string `json:"link"`
	IsVIP    bool   `json:"is_vip"`
}

type nativeClientResults struct {
	Songs     []nativeClientSong `json:"songs"`
	Playlists []model.Playlist   `json:"playlists"`
	Errors    []string           `json:"errors"`
}

func nativeSongs(songs []model.Song) []nativeClientSong {
	result := make([]nativeClientSong, 0, len(songs))
	for _, song := range songs {
		extra, _ := json.Marshal(song.Extra)
		if song.Extra == nil {
			extra = []byte("{}")
		}
		result = append(result, nativeClientSong{ID: song.ID, Source: song.Source, Name: song.Name,
			Artist: song.Artist, Album: song.Album, AlbumID: song.AlbumID, Cover: song.Cover,
			Duration: song.Duration, Extra: string(extra), Link: song.Link, IsVIP: song.IsVIP})
	}
	return result
}

func newNativeResults() nativeClientResults {
	return nativeClientResults{Songs: []nativeClientSong{}, Playlists: []model.Playlist{}, Errors: []string{}}
}

func nativeString(params map[string]json.RawMessage, key string) string {
	var value string
	if json.Unmarshal(params[key], &value) == nil {
		return strings.TrimSpace(value)
	}
	var number json.Number
	if json.Unmarshal(params[key], &number) == nil {
		return number.String()
	}
	return ""
}

func nativeInt(params map[string]json.RawMessage, key string, fallback int) int {
	var value int
	if json.Unmarshal(params[key], &value) == nil {
		return value
	}
	return fallback
}

func nativeSelectedSources(params map[string]json.RawMessage, defaults []string) []string {
	var selected []string
	_ = json.Unmarshal(params["sources"], &selected)
	if len(selected) == 0 {
		if source := nativeString(params, "source"); source != "" {
			selected = []string{source}
		}
	}
	if len(selected) == 0 {
		selected = defaults
	}
	seen := make(map[string]bool)
	result := make([]string, 0, len(selected))
	for _, source := range selected {
		source = strings.TrimSpace(source)
		if source != "" && !seen[source] {
			seen[source] = true
			result = append(result, source)
		}
	}
	if len(result) > 32 {
		result = result[:32]
	}
	return result
}

func nativeMembership(source string, values []string) bool {
	for _, value := range values {
		if value == source {
			return true
		}
	}
	return false
}

func nativeSourceCatalog() map[string]interface{} {
	sources := make([]map[string]interface{}, 0)
	for _, source := range core.GetMusicPlatformNames() {
		sources = append(sources, map[string]interface{}{
			"id": source, "name": core.GetSourceDescription(source),
			"search":   core.GetSearchFunc(source) != nil || isLocalMusicSource(source),
			"playlist": nativeMembership(source, core.GetPlaylistSourceNames()) || isLocalMusicSource(source),
			"album":    nativeMembership(source, core.GetAlbumSourceNames()),
			// Spotify's current development mode cannot access the old browse
			// categories or public chart contents. Keep legacy server adapters,
			// but do not advertise those as usable native OAuth capabilities.
			"toplist":        source != "spotify" && nativeMembership(source, core.GetTopListSourceNames()),
			"recommend":      source != "spotify" && nativeMembership(source, core.GetRecommendSourceNames()),
			"category":       source != "spotify" && nativeMembership(source, core.GetPlaylistCategorySourceNames()),
			"qr_login":       nativeMembership(source, core.GetQRLoginSourceNames()),
			"user_playlists": nativeMembership(source, core.GetUserPlaylistSourceNames()),
			"configured":     legacyAccountSource(source) && core.CM.Get(source) != "",
		})
	}
	return map[string]interface{}{"sources": sources, "defaults": core.GetDefaultSourceNames(), "qr_sources": core.GetQRLoginSourceNames()}
}

// NativeClientRequest keeps credentials inside the trusted native/Go boundary.
// Its input is a finite named operation, never a caller-supplied URL or script.
func NativeClientRequest(raw string) (output string, err error) {
	defer func() {
		if recover() != nil {
			output = ""
			err = errors.New("native operation failed; please retry")
		}
	}()
	if len(raw) > 8<<20 {
		return "", errors.New("native request exceeds 8 MB")
	}
	var request nativeClientInput
	if err = json.Unmarshal([]byte(raw), &request); err != nil {
		return "", errors.New("invalid native request JSON")
	}
	if request.Params == nil {
		request.Params = map[string]json.RawMessage{}
	}
	var data interface{}
	switch request.Action {
	case "accounts.legacy.validate":
		data = nativeValidateLegacyAccount(request.Params)
	case "auth.spotify.session":
		err = spotify.SetNativeAuthorization(nativeString(request.Params, "access_token"), int64(nativeInt(request.Params, "expires_at", 0)))
		data = map[string]bool{"accepted": err == nil}
	case "diagnostics.enable":
		enableNativeDiagnostics()
		data = true
	case "sources", "bootstrap":
		data = nativeSourceCatalog()
	case "search":
		data, err = nativeSearch(request.Params)
	case "recommend", "user_playlists", "category_playlists":
		data, err = nativePlaylists(request.Action, request.Params)
	case "toplists":
		data, err = nativeTopLists(request.Params)
	case "categories":
		data, err = nativeCategories(request.Params)
	case "detail", "collections.songs":
		data, err = nativeDetail(request.Action, request.Params)
	case "switch_source":
		var song *model.Song
		song, err = decodeNativeSong(string(request.Params["song"]))
		if err == nil {
			var selected *model.Song
			selected, _, err = findBestSwitchSong(song.Name, song.Artist, song.Source, nativeString(request.Params, "target"), song.Duration)
			if err == nil && selected != nil {
				data = nativeSongs([]model.Song{*selected})[0]
			}
		}
	case "lyric":
		data, err = nativeLyric(request.Params)
	case "settings.get":
		data = publicWebSettingsPayload()
	case "settings.save":
		data, err = nativeSaveSettings(request.Params)
	case "cookies.get":
		data = activeAccountCookies(true)
	case "cookies.save":
		var cookies map[string]string
		if err = json.Unmarshal(request.Params["cookies"], &cookies); err == nil {
			for source := range cookies {
				if !legacyAccountSource(source) {
					return "", errors.New("此账号请使用对应的官方授权入口")
				}
			}
			core.CM.SetAll(cookies)
			core.CM.Save()
			data = map[string]string{"status": "ok"}
		}
	case "local.import":
		data, err = nativeImportFile(request.Params)
	default:
		data, err = nativeJSONRoute(request.Action, request.Params)
	}
	if err != nil {
		return "", err
	}
	encoded, err := json.Marshal(map[string]interface{}{"data": data})
	return string(encoded), err
}

var nativeSearchProvider = core.GetSearchFunc
var nativePlaylistSearchProvider = core.GetPlaylistSearchFunc
var nativeAlbumSearchProvider = core.GetAlbumSearchFunc

func nativeSearch(params map[string]json.RawMessage) (nativeClientResults, error) {
	result := newNativeResults()
	query := nativeString(params, "q")
	if query == "" {
		return result, nil
	}
	if len(query) > 4096 {
		return result, errors.New("search query is too long")
	}
	kind := nativeString(params, "type")
	if kind == "" {
		kind = "song"
	}
	if kind != "song" && kind != "album" && kind != "playlist" {
		return result, errors.New("invalid search type")
	}
	if strings.HasPrefix(query, "https://") || strings.HasPrefix(query, "http://") || strings.HasPrefix(query, "spotify:") {
		return nativeParseLink(query, kind)
	}
	sources := nativeSelectedSources(params, defaultSourcesForSearchType(kind))
	settings := core.GetWebSettings()
	parts := make([]nativeClientResults, len(sources))
	var group sync.WaitGroup
	for i, source := range sources {
		group.Add(1)
		go func(index int, source string) {
			defer group.Done()
			part := newNativeResults()
			var songs []model.Song
			var playlists []model.Playlist
			var err error
			if isLocalMusicSource(source) {
				if kind == "song" {
					songs = localMusicSearchSongs(query, 500)
				} else if kind == "playlist" {
					playlists = localCollectionSearchPlaylists(query)
				} else {
					err = errors.New("local album search is unavailable")
				}
			} else if kind == "song" {
				if fn := nativeSearchProvider(source); fn != nil {
					songs, err = fn(query)
				} else {
					err = errors.New("song search is unsupported")
				}
			} else {
				fn := nativePlaylistSearchProvider(source)
				if kind == "album" {
					fn = nativeAlbumSearchProvider(source)
				}
				if fn != nil {
					playlists, err = fn(query)
				} else {
					err = errors.New("collection search is unsupported")
				}
			}
			if err != nil {
				part.Errors = append(part.Errors, core.GetSourceDescription(source)+"："+err.Error())
			}
			for i := range songs {
				songs[i].Source = source
			}
			for i := range playlists {
				playlists[i].Source = source
			}
			songs = filterSongsForDisplay(songs, settings)
			if artist := nativeString(params, "exact_artist"); artist != "" {
				songs = filterSongsByExactArtist(songs, artist)
			}
			part.Songs = nativeSongs(songs)
			part.Playlists = append(part.Playlists, playlists...)
			parts[index] = part
		}(i, source)
	}
	group.Wait()
	for _, part := range parts {
		result.Songs = append(result.Songs, part.Songs...)
		result.Playlists = append(result.Playlists, part.Playlists...)
		result.Errors = append(result.Errors, part.Errors...)
	}
	return result, nil
}

func nativeParseLink(link, kind string) (nativeClientResults, error) {
	result := newNativeResults()
	source := core.DetectSource(link)
	if source == "" {
		return result, errors.New("unsupported music link")
	}
	if kind == "song" {
		if fn := core.GetParseFunc(source); fn != nil {
			if song, err := fn(link); err == nil && song != nil {
				song.Source = source
				result.Songs = nativeSongs([]model.Song{*song})
				return result, nil
			}
		}
	}
	if fn := core.GetParsePlaylistFunc(source); fn != nil && kind != "album" {
		if playlist, songs, err := fn(link); err == nil {
			if playlist != nil {
				playlist.Source = source
				result.Playlists = append(result.Playlists, *playlist)
			}
			for i := range songs {
				songs[i].Source = source
			}
			result.Songs = nativeSongs(songs)
			return result, nil
		}
	}
	if fn := core.GetParseAlbumFunc(source); fn != nil {
		if playlist, songs, err := fn(link); err == nil {
			if playlist != nil {
				playlist.Source = source
				result.Playlists = append(result.Playlists, *playlist)
			}
			for i := range songs {
				songs[i].Source = source
			}
			result.Songs = nativeSongs(songs)
			return result, nil
		}
	}
	return result, errors.New("link could not be resolved with the current platform authorization")
}

func nativePlaylists(action string, params map[string]json.RawMessage) (nativeClientResults, error) {
	result := newNativeResults()
	defaults := core.GetRecommendSourceNames()
	if action == "user_playlists" {
		defaults = core.GetUserPlaylistSourceNames()
	}
	sources := nativeSelectedSources(params, defaults)
	parts := make([]nativeClientResults, len(sources))
	var group sync.WaitGroup
	for i, source := range sources {
		group.Add(1)
		go func(i int, source string) {
			defer group.Done()
			part := newNativeResults()
			var playlists []model.Playlist
			var err error
			switch action {
			case "recommend":
				if fn := nativeRecommendProvider(source); fn != nil {
					ctx, cancel := context.WithTimeout(context.Background(), nativeDiscoveryTimeout)
					defer cancel()
					var value interface{}
					value, err = nativeDiscoveryCalls.run(ctx, nativeProviderKey("recommend", source), func() (interface{}, error) { return fn() })
					if err == nil {
						playlists = append([]model.Playlist(nil), value.([]model.Playlist)...)
					}
				} else {
					err = errors.New("recommendations are unsupported")
				}
			case "user_playlists":
				if fn := core.GetUserPlaylistsFunc(source); fn != nil {
					playlists, err = fn(max(1, nativeInt(params, "page", 1)), min(120, max(1, nativeInt(params, "limit", 50))))
				} else {
					err = errors.New("personal playlists are unsupported")
				}
			case "category_playlists":
				if fn := core.GetCategoryPlaylistsFunc(source); fn != nil {
					playlists, err = fn(nativeString(params, "category_id"), max(1, nativeInt(params, "page", 1)), min(120, max(1, nativeInt(params, "limit", 50))))
				} else {
					err = errors.New("category playlists are unsupported")
				}
			}
			for i := range playlists {
				playlists[i].Source = source
			}
			part.Playlists = append(part.Playlists, playlists...)
			if err != nil {
				if action == "recommend" {
					part.Errors = append(part.Errors, core.GetSourceDescription(source)+"：连接暂时不可用，请重试")
				} else {
					part.Errors = append(part.Errors, core.GetSourceDescription(source)+"："+err.Error())
				}
			}
			parts[i] = part
		}(i, source)
	}
	group.Wait()
	for _, part := range parts {
		result.Playlists = append(result.Playlists, part.Playlists...)
		result.Errors = append(result.Errors, part.Errors...)
	}
	return result, nil
}

var nativeRecommendProvider = core.GetRecommendFunc
var nativeTopListsProvider = core.GetTopListsFunc
var nativeDiscoveryTimeout = 6 * time.Second

func nativeTopLists(params map[string]json.RawMessage) (interface{}, error) {
	sources := nativeSelectedSources(params, core.GetTopListSourceNames())
	parts := make([][]model.TopList, len(sources))
	errs := make([]error, len(sources))
	var group sync.WaitGroup
	for i, source := range sources {
		group.Add(1)
		go func(i int, source string) {
			defer group.Done()
			fn := nativeTopListsProvider(source)
			if fn == nil {
				errs[i] = errors.New("unsupported")
				return
			}
			ctx, cancel := context.WithTimeout(context.Background(), nativeDiscoveryTimeout)
			defer cancel()
			value, err := nativeDiscoveryCalls.run(ctx, nativeProviderKey("toplists", source), func() (interface{}, error) { return fn() })
			errs[i] = err
			if err == nil {
				parts[i] = append([]model.TopList(nil), value.([]model.TopList)...)
				for j := range parts[i] {
					parts[i][j].Source = source
				}
			}
		}(i, source)
	}
	group.Wait()
	toplists := []model.TopList{}
	failures := []string{}
	for i, part := range parts {
		toplists = append(toplists, part...)
		if errs[i] != nil {
			failures = append(failures, core.GetSourceDescription(sources[i])+"：排行榜暂时不可用，请重试")
		}
	}
	return map[string]interface{}{"toplists": toplists, "errors": failures}, nil
}

func nativeCategories(params map[string]json.RawMessage) (interface{}, error) {
	categories := []model.PlaylistCategory{}
	failures := []string{}
	for _, source := range nativeSelectedSources(params, core.GetPlaylistCategorySourceNames()) {
		fn := core.GetPlaylistCategoriesFunc(source)
		if fn == nil {
			failures = append(failures, source+"：歌单分类不可用")
			continue
		}
		values, err := fn()
		if err != nil {
			failures = append(failures, source+"："+err.Error())
			continue
		}
		for i := range values {
			values[i].Source = source
		}
		categories = append(categories, values...)
	}
	return map[string]interface{}{"categories": categories, "errors": failures}, nil
}

func nativeDetail(action string, params map[string]json.RawMessage) (nativeClientResults, error) {
	result := newNativeResults()
	kind := nativeString(params, "kind")
	if action == "collections.songs" {
		kind = "collection"
	}
	id := nativeString(params, "id")
	source := nativeString(params, "source")
	if id == "" {
		return result, errors.New("missing collection id")
	}
	var songs []model.Song
	var err error
	if kind == "collection" {
		if db == nil {
			return result, errors.New("library is not initialized")
		}
		var collection *Collection
		collection, err = loadCollection(id)
		if err == nil {
			songs, err = loadCollectionSongs(collection)
		}
	} else {
		var fn func(string) ([]model.Song, error)
		switch kind {
		case "album":
			fn = core.GetAlbumDetailFunc(source)
		case "playlist":
			fn = core.GetPlaylistDetailFunc(source)
		case "toplist":
			fn = core.GetTopListSongsFunc(source)
		default:
			return result, errors.New("invalid detail kind")
		}
		if fn == nil {
			return result, fmt.Errorf("%s does not support %s", source, kind)
		}
		songs, err = fn(id)
		for i := range songs {
			songs[i].Source = source
		}
	}
	if err != nil {
		return result, err
	}
	result.Songs = nativeSongs(filterSongsForDisplay(songs, core.GetWebSettings()))
	return result, nil
}

func nativeLyric(params map[string]json.RawMessage) (interface{}, error) {
	song, err := decodeNativeSong(string(params["song"]))
	if err != nil {
		return nil, err
	}
	var text string
	if isLocalMusicSource(song.Source) {
		track, err := localMusicTrackByID(song.ID)
		if err != nil {
			return nil, err
		}
		text, err = readLocalMusicLyrics(track.absPath)
		if err != nil {
			return nil, err
		}
	} else {
		text, err = resilientNativeLyrics(song, filepath.Join("data", "cache", "native-lyrics"))
		if err != nil {
			return nil, err
		}
	}
	return map[string]string{"text": formatLyricForMode(text, "auto")}, nil
}

func nativeSaveSettings(params map[string]json.RawMessage) (interface{}, error) {
	patch := params["settings"]
	if len(patch) == 0 {
		return nil, errors.New("missing settings")
	}
	settings := core.GetWebSettings()
	if err := json.Unmarshal(patch, &settings); err != nil {
		return nil, errors.New("invalid settings")
	}
	if err := core.SaveWebSettings(settings); err != nil {
		return nil, err
	}
	return publicWebSettingsPayload(), nil
}
