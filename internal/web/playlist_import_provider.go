package web

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/guohuiyuan/go-music-dl/internal/spotify"
)

type importPlaylistRef struct{ Source, ID string }
type importPlaylistPage struct {
	Title    string        `json:"title"`
	Cover    string        `json:"cover"`
	Total    int           `json:"total"`
	Tracks   []importTrack `json:"tracks"`
	Next     int           `json:"next"`
	More     bool          `json:"more"`
	Revision string        `json:"revision,omitempty"`
}

var importDigits = regexp.MustCompile(`^[0-9]{1,20}$`)
var importSpotifyID = regexp.MustCompile(`^[A-Za-z0-9]{22}$`)

func parseImportPlaylistURL(raw, selected string) (importPlaylistRef, error) {
	bad := errors.New("不支持此链接，请粘贴所选平台的完整歌单链接；短链接、歌曲链接和私有地址不受支持")
	if len(raw) > 2048 {
		return importPlaylistRef{}, bad
	}
	u, e := url.Parse(raw)
	if e != nil || u.Scheme != "https" || u.User != nil || u.Port() != "" {
		return importPlaylistRef{}, bad
	}
	ref := importPlaylistRef{}
	switch strings.ToLower(u.Hostname()) {
	case "music.163.com":
		ref.Source = "netease"
		q := u.Query()
		p := u.Path
		if strings.HasPrefix(u.Fragment, "/playlist?") {
			v, parseErr := url.Parse(u.Fragment)
			if parseErr != nil {
				return ref, bad
			}
			p = v.Path
			q = v.Query()
		}
		if p != "/playlist" {
			return ref, bad
		}
		ref.ID = q.Get("id")
	case "y.qq.com":
		ref.Source = "qq"
		if u.Path == "/n/ryqq/playlist/"+pathLast(u.Path) {
			ref.ID = pathLast(u.Path)
		} else if u.Path == "/n2/m/share/details/taoge.html" {
			ref.ID = u.Query().Get("id")
		} else if u.Path == "/n/yqq/playlist/"+pathLast(u.Path) {
			ref.ID = strings.TrimSuffix(pathLast(u.Path), ".html")
		} else {
			return ref, bad
		}
	case "open.spotify.com":
		ref.Source = "spotify"
		p := strings.Split(strings.Trim(u.Path, "/"), "/")
		if len(p) == 3 && strings.HasPrefix(p[0], "intl-") {
			p = p[1:]
		}
		if len(p) != 2 || p[0] != "playlist" {
			return ref, bad
		}
		ref.ID = p[1]
	default:
		return ref, bad
	}
	if selected != "" && ref.Source != selected {
		return ref, errors.New("链接平台与所选平台不一致")
	}
	if (ref.Source == "spotify" && !importSpotifyID.MatchString(ref.ID)) || (ref.Source != "spotify" && !importDigits.MatchString(ref.ID)) {
		return ref, bad
	}
	return ref, nil
}
func pathLast(p string) string { v := strings.Split(p, "/"); return v[len(v)-1] }

// Only fixed HTTPS service endpoints. Never follow a redirect or send imported
// user credentials/cookies. A private/deleted/restricted playlist stays a failure.
var importHTTP = &http.Client{Timeout: 20 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return errors.New("歌单接口重定向已阻止") }}

func importGetJSON(endpoint, referer string, out interface{}) error {
	req, e := http.NewRequest(http.MethodGet, endpoint, nil)
	if e != nil {
		return e
	}
	req.Header.Set("User-Agent", "MusicDL/1.0")
	if referer != "" {
		req.Header.Set("Referer", referer)
	}
	r, e := importHTTP.Do(req)
	if e != nil {
		return errors.New("读取歌单超时或网络中断，已读取部分会保留，请重试")
	}
	defer r.Body.Close()
	if r.StatusCode == 429 {
		return errors.New("平台请求限流，请稍后重试")
	}
	if r.StatusCode != 200 {
		return fmt.Errorf("歌单接口 HTTP %d：可能已删除、无权限或暂时不可用", r.StatusCode)
	}
	d, e := io.ReadAll(io.LimitReader(r.Body, (8<<20)+1))
	if e != nil || len(d) > 8<<20 {
		return errors.New("歌单响应过大或读取失败")
	}
	if json.Unmarshal(d, out) != nil {
		return errors.New("平台返回格式发生变化，请改用文件导入")
	}
	return nil
}

func readImportPlaylistPage(params map[string]json.RawMessage) (importPlaylistPage, error) {
	page := importPlaylistPage{Tracks: []importTrack{}}
	ref, e := parseImportPlaylistURL(nativeString(params, "url"), nativeString(params, "source"))
	if e != nil {
		return page, e
	}
	offset := nativeInt(params, "offset", 0)
	if offset < 0 || offset >= importMaxTracks {
		return page, errors.New("超出单次 5000 首限制，请拆分歌单")
	}
	if ref.Source == "spotify" {
		p, songs, next, total, e := spotify.New("").ImportPlaylistPage(ref.ID, offset)
		if e != nil {
			return page, e
		}
		page.Title = p.Name
		page.Cover = p.Cover
		page.Total = total
		page.Next = next
		page.More = next < total
		page.Revision = p.Extra["snapshot_id"]
		for _, s := range songs {
			page.Tracks = append(page.Tracks, importTrack{Title: s.Name, Artist: s.Artist, Album: s.Album, Duration: s.Duration, Source: "spotify", SourceID: s.ID, PlaylistID: ref.ID, ISRC: s.Extra["isrc"], Cover: s.Cover})
		}
	} else if ref.Source == "netease" {
		var head struct {
			Code     int
			Playlist *struct {
				Name       string
				Cover      string `json:"coverImgUrl"`
				TrackCount int
				TrackIDs   []struct{ ID int64 }
			}
		}
		if e = importGetJSON("https://music.163.com/api/v6/playlist/detail?id="+ref.ID+"&n=0", "https://music.163.com/", &head); e != nil {
			return page, e
		}
		if head.Code != 200 || head.Playlist == nil {
			return page, errors.New("网易云歌单不可读取：可能为私有、已删除或需要授权")
		}
		h := head.Playlist
		manifest, _ := json.Marshal(h.TrackIDs)
		page.Revision = importIdentity(importTrack{Source: "netease", SourceID: string(manifest)})
		page.Title = h.Name
		page.Cover = h.Cover
		page.Total = h.TrackCount
		if page.Total < 0 || page.Title == "" {
			return page, errors.New("网易云歌单元数据不完整")
		}
		if page.Total > importMaxTracks {
			return page, errors.New("歌单超过 5000 首，请拆分后导入")
		}
		if len(h.TrackIDs) < h.TrackCount {
			return page, errors.New("平台没有开放完整曲目索引，不能将部分数据当作完整导入；请导出文件")
		}
		if offset > len(h.TrackIDs) {
			return page, errors.New("歌单已变化，请重新读取")
		}
		end := min(offset+50, len(h.TrackIDs))
		ids := []int64{}
		for _, t := range h.TrackIDs[offset:end] {
			ids = append(ids, t.ID)
		}
		if len(ids) > 0 {
			var detail struct {
				Code  int
				Songs []struct {
					ID      int64
					Name    string
					Artists []struct{ Name string }
					Album   struct {
						Name   string
						PicURL string
					}
					Duration int
				}
			}
			b, _ := json.Marshal(ids)
			if e = importGetJSON("https://music.163.com/api/song/detail?ids="+url.QueryEscape(string(b)), "https://music.163.com/", &detail); e != nil {
				return page, e
			}
			if detail.Code != 200 {
				return page, errors.New("网易云曲目读取失败，请稍后重试")
			}
			byID := map[int64]importTrack{}
			for _, s := range detail.Songs {
				a := []string{}
				for _, v := range s.Artists {
					a = append(a, v.Name)
				}
				byID[s.ID] = importTrack{Title: s.Name, Artist: strings.Join(a, " / "), Album: s.Album.Name, Duration: s.Duration / 1000, Cover: s.Album.PicURL}
			}
			for _, id := range ids {
				t, ok := byID[id]
				if !ok {
					t.Title = "不可用曲目 " + strconv.FormatInt(id, 10)
				}
				t.Source = "netease"
				t.SourceID = strconv.FormatInt(id, 10)
				t.PlaylistID = ref.ID
				page.Tracks = append(page.Tracks, t)
			}
		}
		page.Next = end
		page.More = end < h.TrackCount
	} else {
		var data struct {
			Code   int
			CDList []struct {
				Begin    *int            `json:"song_begin"`
				Modified json.RawMessage `json:"mtime"`
				Name     string          `json:"dissname"`
				Cover    string          `json:"logo"`
				Total    int             `json:"total_song_num"`
				Songs    []struct {
					ID       string                  `json:"songmid"`
					Name     string                  `json:"songname"`
					Album    string                  `json:"albumname"`
					AlbumID  string                  `json:"albummid"`
					Duration int                     `json:"interval"`
					Singers  []struct{ Name string } `json:"singer"`
				} `json:"songlist"`
			} `json:"cdlist"`
		}
		endpoint := "https://c.y.qq.com/qzone/fcg-bin/fcg_ucc_getcdinfo_byids_cp.fcg?type=1&json=1&utf8=1&onlysong=0&format=json&disstid=" + ref.ID + "&song_begin=" + strconv.Itoa(offset) + "&song_num=50"
		if e = importGetJSON(endpoint, "https://y.qq.com/", &data); e != nil {
			return page, e
		}
		if data.Code != 0 || len(data.CDList) != 1 {
			return page, errors.New("QQ 歌单不可读取：可能为私有、已删除或需要授权")
		}
		h := data.CDList[0]
		if h.Begin == nil || *h.Begin != offset {
			return page, errors.New("QQ 接口没有按请求返回正确分页")
		}
		page.Revision = string(h.Modified)
		page.Title = h.Name
		page.Cover = h.Cover
		page.Total = h.Total
		if page.Total < offset+len(h.Songs) || page.Title == "" {
			return page, errors.New("QQ 歌单元数据不完整")
		}
		if page.Total > importMaxTracks {
			return page, errors.New("歌单超过 5000 首，请拆分后导入")
		}
		if len(h.Songs) > 50 {
			return page, errors.New("QQ 接口未按分页返回，已停止以避免重复读取")
		}
		for i, s := range h.Songs {
			a := []string{}
			for _, v := range s.Singers {
				a = append(a, v.Name)
			}
			id := s.ID
			if id == "" {
				id = "unavailable-" + strconv.Itoa(offset+i)
			}
			name := s.Name
			if name == "" {
				name = "不可用曲目 " + id
			}
			cover := ""
			if s.AlbumID != "" {
				cover = "https://y.gtimg.cn/music/photo_new/T002R300x300M000" + url.PathEscape(s.AlbumID) + ".jpg"
			}
			page.Tracks = append(page.Tracks, importTrack{Title: name, Artist: strings.Join(a, " / "), Album: s.Album, Duration: s.Duration, Source: "qq", SourceID: id, PlaylistID: ref.ID, Cover: cover})
		}
		page.Next = offset + len(h.Songs)
		page.More = page.Next < page.Total
	}
	if page.More && page.Next <= offset {
		return page, errors.New("分页没有返回新曲目，请稍后重试")
	}
	if len(page.Tracks) > 0 {
		page.Tracks, e = validateImportTracks(page.Tracks)
	}
	return page, e
}
