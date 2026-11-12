package web

// MusicDL's metadata import boundary. No external file or media URL is opened by
// this parser. Provider links are handled separately by a finite host allowlist.
import (
	"crypto/sha256"
	"encoding/csv"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/url"
	"path"
	"sort"
	"strconv"
	"strings"
	"unicode"

	"gorm.io/gorm"
	"gorm.io/gorm/clause"
)

const importMaxTracks = 5000

type importTrack struct {
	ID         string `json:"id"`
	Title      string `json:"title"`
	Artist     string `json:"artist"`
	Album      string `json:"album"`
	Duration   int    `json:"duration"`
	Source     string `json:"source"`
	SourceID   string `json:"sourceID"`
	PlaylistID string `json:"playlistID"`
	ISRC       string `json:"isrc"`
	Cover      string `json:"cover"`
	LocalPath  string `json:"localPath"`
}

func importIdentity(t importTrack) string {
	key := t.Source + ":" + t.SourceID
	if t.SourceID == "" {
		key = strings.ToLower(strings.TrimSpace(t.Title)) + "\n" + strings.ToLower(strings.TrimSpace(t.Artist)) + "\n" + t.LocalPath
	}
	h := sha256.Sum256([]byte(key))
	return hex.EncodeToString(h[:16])
}

func validateImportTracks(tracks []importTrack) ([]importTrack, error) {
	if len(tracks) == 0 {
		return nil, errors.New("没有可识别曲目，请检查歌名、歌手或文件格式")
	}
	if len(tracks) > importMaxTracks {
		return nil, errors.New("单次最多导入 5000 首，请拆分歌单")
	}
	for i := range tracks {
		t := &tracks[i]
		t.Title = strings.TrimSpace(t.Title)
		t.Artist = strings.TrimSpace(t.Artist)
		if t.Title == "" {
			return nil, fmt.Errorf("第 %d 首缺少歌名", i+1)
		}
		for _, s := range []string{t.Title, t.Artist, t.Album, t.Source, t.SourceID, t.PlaylistID, t.ISRC, t.Cover, t.LocalPath} {
			if len(s) > 4096 || strings.ContainsRune(s, 0) {
				return nil, fmt.Errorf("第 %d 首字段过长或包含非法字符", i+1)
			}
		}
		if t.Duration < 0 {
			t.Duration = 0
		}
		if t.Duration > 86400 {
			return nil, errors.New("歌曲时长超出限制")
		}
		t.ID = importIdentity(*t)
	}
	return tracks, nil
}

func parseImportText(text, format string) ([]importTrack, error) {
	if len(text) > 5<<20 {
		return nil, errors.New("歌单文件不能超过 5 MB")
	}
	text = strings.TrimPrefix(text, "\ufeff")
	tracks := []importTrack{}
	switch strings.ToLower(format) {
	case "csv":
		r := csv.NewReader(strings.NewReader(text))
		r.FieldsPerRecord = -1
		header, err := r.Read()
		if err != nil {
			return nil, errors.New("CSV 表头无效")
		}
		indices := map[string]int{}
		for i, h := range header {
			indices[strings.ToLower(strings.TrimSpace(h))] = i
		}
		get := func(row []string, keys ...string) string {
			for _, k := range keys {
				if i, ok := indices[k]; ok && i < len(row) {
					return row[i]
				}
			}
			return ""
		}
		for line := 2; ; line++ {
			row, err := r.Read()
			if err == io.EOF {
				break
			}
			if err != nil {
				return nil, fmt.Errorf("CSV 第 %d 行格式错误", line)
			}
			if len(row) != len(header) {
				return nil, fmt.Errorf("CSV 第 %d 行列数与表头不一致", line)
			}
			d, _ := strconv.Atoi(get(row, "duration", "时长"))
			tracks = append(tracks, importTrack{Title: get(row, "title", "name", "track name", "歌名", "歌曲名称"), Artist: get(row, "artist", "artists", "artist name(s)", "歌手"), Album: get(row, "album", "album name", "专辑"), Duration: d, ISRC: get(row, "isrc"), Source: get(row, "source", "platform"), SourceID: get(row, "sourceid", "source_id"), PlaylistID: get(row, "playlistid", "playlist_id"), Cover: get(row, "cover"), LocalPath: get(row, "localpath", "path")})
			if len(tracks) > importMaxTracks {
				return nil, errors.New("单次最多导入 5000 首")
			}
		}
	case "json":
		var rows []map[string]json.RawMessage
		if json.Unmarshal([]byte(text), &rows) != nil {
			var wrapper struct {
				Tracks []map[string]json.RawMessage `json:"tracks"`
				Songs  []map[string]json.RawMessage `json:"songs"`
			}
			if json.Unmarshal([]byte(text), &wrapper) != nil {
				return nil, errors.New("JSON 格式错误")
			}
			rows = wrapper.Tracks
			if rows == nil {
				rows = wrapper.Songs
			}
		}
		for _, row := range rows {
			get := func(keys ...string) string {
				for _, k := range keys {
					var s string
					if json.Unmarshal(row[k], &s) == nil {
						return s
					}
					var a []string
					if json.Unmarshal(row[k], &a) == nil && len(a) > 0 {
						return strings.Join(a, " / ")
					}
				}
				return ""
			}
			d := 0
			_ = json.Unmarshal(row["duration"], &d)
			tracks = append(tracks, importTrack{Title: get("title", "name"), Artist: get("artist", "artists"), Album: get("album"), Duration: d, Source: get("source", "platform"), SourceID: get("sourceID", "source_id"), PlaylistID: get("playlistID", "playlist_id"), ISRC: get("isrc"), Cover: get("cover"), LocalPath: get("localPath", "path")})
			if len(tracks) > importMaxTracks {
				return nil, errors.New("单次最多导入 5000 首")
			}
		}
	case "m3u", "m3u8":
		if strings.Contains(strings.ToUpper(text), "#EXT-X-") {
			return nil, errors.New("这是 HLS 媒体流清单，不是可迁移的音乐歌单")
		}
		var pending importTrack
		for _, raw := range strings.Split(text, "\n") {
			line := strings.TrimSpace(raw)
			if line == "" {
				continue
			}
			if strings.HasPrefix(strings.ToUpper(line), "#EXTINF:") {
				parts := strings.SplitN(line[8:], ",", 2)
				pending = importTrack{}
				v, _ := strconv.ParseFloat(parts[0], 64)
				if v > 0 && v <= 86400 {
					pending.Duration = int(v)
				}
				if len(parts) == 2 {
					pending.Artist, pending.Title = splitImportLine(parts[1])
				}
				continue
			}
			if strings.HasPrefix(line, "#") {
				continue
			}
			pending.LocalPath = line
			if pending.Title == "" {
				pending.Title = strings.TrimSuffix(path.Base(strings.ReplaceAll(line, "\\", "/")), path.Ext(line))
			}
			tracks = append(tracks, pending)
			if len(tracks) > importMaxTracks {
				return nil, errors.New("单次最多导入 5000 首")
			}
			pending = importTrack{}
		}
	case "txt", "text":
		for _, line := range strings.Split(text, "\n") {
			line = strings.TrimSpace(line)
			if line == "" {
				continue
			}
			a, t := splitImportLine(line)
			tracks = append(tracks, importTrack{Title: t, Artist: a})
			if len(tracks) > importMaxTracks {
				return nil, errors.New("单次最多导入 5000 首")
			}
		}
	default:
		return nil, errors.New("请选择 CSV、TXT、JSON、M3U 或 M3U8 文件")
	}
	return validateImportTracks(tracks)
}

func splitImportLine(s string) (string, string) {
	for _, sep := range []string{" - ", " – ", " — ", "\t"} {
		if p := strings.SplitN(strings.TrimSpace(s), sep, 2); len(p) == 2 {
			return strings.TrimSpace(p[0]), strings.TrimSpace(p[1])
		}
	}
	return "", strings.TrimSpace(s)
}

// Only compare paths against the existing library. Never resolve, read or
// download a path supplied by an imported playlist.
func normalizedImportPath(raw string) string {
	s := strings.Trim(strings.TrimSpace(raw), "\"")
	if strings.Contains(s, "://") {
		u, e := url.Parse(s)
		if e != nil || u.Scheme != "file" || u.Host != "" {
			return ""
		}
		s = u.Path
	}
	if decoded, e := url.PathUnescape(s); e == nil {
		s = decoded
	}
	s = strings.ReplaceAll(s, "\\", "/")
	s = strings.TrimPrefix(s, "/")
	if len(s) > 2 && s[1] == ':' {
		s = s[2:]
	}
	return strings.ToLower(strings.TrimPrefix(path.Clean("/"+s), "/"))
}

func importLocalCandidates(raw string) ([]nativeClientSong, error) {
	p := normalizedImportPath(raw)
	if p == "" {
		return []nativeClientSong{}, nil
	}
	tracks, _, _, err := scanLocalMusicTracks()
	if err != nil {
		return nil, err
	}
	var exact, fallback []*localMusicTrack
	for _, t := range tracks {
		r := normalizedImportPath(t.RelPath)
		if r == p || strings.HasSuffix(p, "/"+r) {
			exact = append(exact, t)
		} else if path.Base(r) == path.Base(p) {
			fallback = append(fallback, t)
		}
	}
	if len(exact) == 0 {
		exact = fallback
	}
	return nativeSongs(localMusicTracksToSongs(exact)), nil
}

type importCommitResult struct {
	Added      int `json:"added"`
	Duplicates int `json:"duplicates"`
}

// Every batch is all-or-nothing. Unique constraints also protect retries after
// a response is lost or the app terminates between SQLite commit and checkpoint.
func commitImportSongs(params map[string]json.RawMessage) (importCommitResult, error) {
	result := importCommitResult{}
	id, err := nativeRouteID(params)
	if err != nil {
		return result, err
	}
	var payload []nativeClientSong
	if json.Unmarshal(params["songs"], &payload) != nil || len(payload) == 0 || len(payload) > 200 {
		return result, errors.New("每批需要 1–200 首歌曲")
	}
	if db == nil {
		return result, errors.New("音乐库尚未就绪")
	}
	err = db.Transaction(func(tx *gorm.DB) error {
		var collection Collection
		if err := tx.First(&collection, id).Error; err != nil {
			return errors.New("歌单不存在")
		}
		if !collection.isManual() {
			return errors.New("只能编辑自己创建的歌单")
		}
		var existing []SavedSong
		if err := tx.Where("collection_id = ?", id).Find(&existing).Error; err != nil {
			return err
		}
		ordinal := 0
		isrcIDs := map[string]bool{}
		placeholderOrder := map[string]int{}
		for _, s := range existing {
			extra := decodeSongExtraMap(s.Extra)
			n, _ := strconv.Atoi(extra["musicdl_playlist_order"])
			if n > ordinal {
				ordinal = n
			}
			if s.Source == "import-metadata" {
				placeholderOrder[s.SongID] = n
			}
			if v := extra["isrc"]; v != "" && s.Source != "import-metadata" {
				isrcIDs[strings.ToUpper(v)+"|"+importFold(s.Name)+"|"+importFold(s.Artist)] = true
			}
		}
		for _, p := range payload {
			if p.ID == "" || p.Source == "" || p.Name == "" || len(p.Extra) > 64<<10 || len(p.ID) > 4096 || len(p.Name) > 4096 {
				return errors.New("歌曲数据不完整或过长")
			}
			extra := decodeSongExtraMap(p.Extra)
			if extra == nil {
				extra = map[string]string{}
			}
			// A later manual match replaces only this import's metadata placeholder.
			replacementOrder := 0
			if key := extra["musicdl_import_key"]; key != "" && p.Source != "import-metadata" {
				replacementOrder = placeholderOrder[key]
				if err := tx.Where("collection_id = ? AND source = ? AND song_id = ?", id, "import-metadata", key).Delete(&SavedSong{}).Error; err != nil {
					return err
				}
			}
			if isrc := strings.ToUpper(extra["isrc"]); isrc != "" && isrcIDs[isrc+"|"+importFold(p.Name)+"|"+importFold(p.Artist)] {
				result.Duplicates++
				continue
			}
			ordinal++
			order := ordinal
			if replacementOrder > 0 {
				order = replacementOrder
			}
			extra["musicdl_playlist_order"] = strconv.Itoa(order)
			extra["album"] = p.Album
			extra["album_id"] = p.AlbumID
			extra["link"] = p.Link
			b, _ := json.Marshal(extra)
			s := SavedSong{CollectionID: collection.ID, SongID: p.ID, Source: p.Source, Name: p.Name, Artist: p.Artist, Cover: p.Cover, Duration: p.Duration, Extra: string(b)}
			r := tx.Clauses(clause.OnConflict{DoNothing: true}).Create(&s)
			if r.Error != nil {
				return r.Error
			}
			if r.RowsAffected == 0 {
				result.Duplicates++
			} else {
				result.Added++
				if v := extra["isrc"]; v != "" && p.Source != "import-metadata" {
					isrcIDs[strings.ToUpper(v)+"|"+importFold(p.Name)+"|"+importFold(p.Artist)] = true
				}
			}
		}
		return nil
	})
	if err != nil {
		return importCommitResult{}, err
	}
	return result, nil
}

func sortImportedSongs(rows []SavedSong) {
	// Old rows retain their original newest-first order. New batches append in
	// source order without changing the schema or rewriting existing records.
	sort.SliceStable(rows, func(i, j int) bool {
		a, _ := strconv.Atoi(decodeSongExtraMap(rows[i].Extra)["musicdl_playlist_order"])
		b, _ := strconv.Atoi(decodeSongExtraMap(rows[j].Extra)["musicdl_playlist_order"])
		if a == 0 && b == 0 {
			return false
		}
		if a == 0 {
			return true
		}
		if b == 0 {
			return false
		}
		return a < b
	})
}

func importFold(s string) string {
	return strings.Map(func(r rune) rune {
		if unicode.IsLetter(r) || unicode.IsDigit(r) {
			return unicode.ToLower(r)
		}
		return -1
	}, s)
}
