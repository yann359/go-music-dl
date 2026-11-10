package web

import (
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"regexp"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/guohuiyuan/go-music-dl/core"
	"github.com/guohuiyuan/music-lib/model"
)

type nativeSwitchCandidate struct {
	Song               nativeClientSong `json:"song"`
	Score              float64          `json:"score"`
	DurationDifference int              `json:"duration_difference"`
}

var nativeSwitchSearch = core.GetSearchFunc

var switchVersionEnglish = regexp.MustCompile(`(?i)\b(live|remix|demo|acoustic|instrumental|cover|remaster(?:ed)?|karaoke|sped|slowed)\b`)

func nativeVersionSignature(song *model.Song) string {
	text := strings.ToLower(core.NormalizeSearchQuery(song.Name + " " + song.Album))
	markers := map[string]bool{}
	for _, token := range switchVersionEnglish.FindAllString(text, -1) {
		if token == "remastered" {
			token = "remaster"
		}
		markers[token] = true
	}
	for token, category := range map[string]string{"现场": "live", "演唱会": "live", "翻唱": "cover", "伴奏": "instrumental", "纯音乐": "instrumental", "重制": "remaster", "混音": "remix", "加速": "sped", "慢速": "slowed"} {
		if strings.Contains(text, token) {
			markers[category] = true
		}
	}
	values := make([]string, 0, len(markers))
	for token := range markers {
		values = append(values, token)
	}
	sort.Strings(values)
	return strings.Join(values, ",")
}

func nativeSwitchMatch(original, candidate *model.Song) (float64, bool) {
	if original == nil || candidate == nil || core.SearchMatchText(original.Name) == "" || core.SearchMatchText(candidate.Name) == "" || candidate.ID == "" || original.Source == candidate.Source || nativeVersionSignature(original) != nativeVersionSignature(candidate) {
		return 0, false
	}
	name := core.SimilarityScore(core.SearchMatchText(original.Name), core.SearchMatchText(candidate.Name))
	if name < .84 {
		return 0, false
	}
	artist := 1.0
	if core.SearchMatchText(original.Artist) != "" {
		artist = core.SimilarityScore(core.SearchMatchText(original.Artist), core.SearchMatchText(candidate.Artist))
		if artist < .7 {
			return 0, false
		}
	}
	if original.Duration > 0 && candidate.Duration > 0 && !core.IsDurationClose(original.Duration, candidate.Duration) {
		return 0, false
	}
	return name*.7 + artist*.3, true
}

func nativeSwitchCandidates(params map[string]json.RawMessage) (interface{}, error) {
	original, err := decodeNativeSong(string(params["song"]))
	if err != nil {
		return nil, err
	}
	if strings.TrimSpace(original.Name) == "" {
		return nil, errors.New("缺少歌曲名称，无法匹配其他来源")
	}
	selected := nativeSelectedSources(params, core.GetMusicPlatformNames())
	jobs := make(chan string, len(selected))
	for _, source := range selected {
		if source != original.Source && core.IsMusicPlatform(source) {
			jobs <- source
		}
	}
	close(jobs)
	var candidates []nativeSwitchCandidate
	var failures []string
	var mu sync.Mutex
	var workers sync.WaitGroup
	for i := 0; i < 3; i++ {
		workers.Add(1)
		go func() {
			defer workers.Done()
			for source := range jobs {
				// Factories and legacy I/O both stay inside the source's bounded panic-safe pool.
				songs, callErr := nativeSourceCall(source, "switch-candidates", original.Name+"\x00"+original.Artist, func() ([]model.Song, error) {
					fn := nativeSwitchSearch(source)
					if fn == nil {
						return nil, errors.New("不支持搜索")
					}
					songs, err := fn(core.NormalizeSearchQuery(original.Name + " " + original.Artist))
					if (err != nil || len(songs) == 0) && original.Artist != "" {
						return fn(core.NormalizeSearchQuery(original.Name))
					}
					return songs, err
				})
				if callErr != nil {
					mu.Lock()
					failures = append(failures, source+"：暂时无法搜索")
					mu.Unlock()
					continue
				}
				var part []nativeSwitchCandidate
				for _, song := range songs {
					song.Source = source
					score, ok := nativeSwitchMatch(original, &song)
					if !ok {
						continue
					}
					difference := 0
					if original.Duration > 0 && song.Duration > 0 {
						difference = core.IntAbs(original.Duration - song.Duration)
					}
					part = append(part, nativeSwitchCandidate{Song: nativeSongs([]model.Song{song})[0], Score: score, DurationDifference: difference})
				}
				sort.SliceStable(part, func(i, j int) bool {
					if part[i].Score == part[j].Score {
						return part[i].DurationDifference < part[j].DurationDifference
					}
					return part[i].Score > part[j].Score
				})
				if len(part) > 5 {
					part = part[:5]
				}
				mu.Lock()
				candidates = append(candidates, part...)
				mu.Unlock()
			}
		}()
	}
	workers.Wait()
	sort.SliceStable(candidates, func(i, j int) bool {
		if candidates[i].Score == candidates[j].Score {
			if candidates[i].DurationDifference == candidates[j].DurationDifference {
				return candidates[i].Song.Source < candidates[j].Song.Source
			}
			return candidates[i].DurationDifference < candidates[j].DurationDifference
		}
		return candidates[i].Score > candidates[j].Score
	})
	if candidates == nil {
		candidates = []nativeSwitchCandidate{}
	}
	if failures == nil {
		failures = []string{}
	}
	return map[string]interface{}{"candidates": candidates, "errors": failures}, nil
}

var nativeSwitchHTTP = &http.Client{Timeout: 5 * time.Second}
var nativeSwitchDownload = core.GetDownloadFunc

func nativeValidateSwitch(params map[string]json.RawMessage) (interface{}, error) {
	original, err := decodeNativeSong(string(params["original"]))
	if err != nil {
		return nil, err
	}
	candidate, err := decodeNativeSong(string(params["song"]))
	if err != nil {
		return nil, err
	}
	if _, ok := nativeSwitchMatch(original, candidate); !ok {
		return nil, errors.New("歌名、歌手、时长或版本不匹配，请选择其他候选")
	}
	valid, err := nativeSourceCall(candidate.Source, "switch-validate", string(params["song"]), func() (bool, error) {
		fn := nativeSwitchDownload(candidate.Source)
		if fn == nil {
			return false, errors.New("此来源暂不支持播放解析")
		}
		// Preserve all source metadata; upstream ValidatePlayable discarded Extra.
		address, err := fn(candidate)
		if err != nil || address == "" {
			return false, errors.New("未取得有效音频地址，可能需要账号或会员")
		}
		request, err := core.BuildSourceRequest(http.MethodGet, address, candidate.Source, "bytes=0-511")
		if err != nil {
			return false, errors.New("音频请求无法创建")
		}
		response, err := nativeSwitchHTTP.Do(request)
		if err != nil {
			return false, errors.New("音频连接失败，请重试")
		}
		defer func() { _ = response.Body.Close() }()
		if response.StatusCode != 200 && response.StatusCode != 206 {
			return false, errors.New("音频服务器拒绝访问")
		}
		prefix, readErr := io.ReadAll(io.LimitReader(response.Body, 512))
		if readErr != nil || len(prefix) < 2 {
			return false, errors.New("音频内容不可读取")
		}
		if core.DetectAudioExtBySignature(prefix) == "" && !strings.HasPrefix(string(prefix), "#EXTM3U") {
			return false, errors.New("返回内容不是可识别的音频")
		}
		return true, nil
	})
	if err != nil {
		return nil, err
	}
	if !valid {
		return nil, errors.New("此候选暂不可播放")
	}
	return map[string]interface{}{"song": nativeSongs([]model.Song{*candidate})[0], "verified": true}, nil
}
