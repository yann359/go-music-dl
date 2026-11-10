package web

// Opt-in integration audit. Every result comes from the registered provider;
// normal unit tests never depend on external services or personal credentials.
import (
	"encoding/json"
	"os"
	"sync"
	"testing"
	"time"

	"github.com/guohuiyuan/go-music-dl/core"
)

func TestNativeSearchLive(t *testing.T) {
	output := os.Getenv("MUSICDL_SEARCH_AUDIT")
	if output == "" {
		t.Skip("set MUSICDL_SEARCH_AUDIT to an output JSON path for real provider requests")
	}
	initCollectionDBForTest(t)
	type observation struct {
		Query        string   `json:"query"`
		Kind         string   `json:"kind"`
		Source       string   `json:"source"`
		Milliseconds int64    `json:"milliseconds"`
		Songs        int      `json:"songs"`
		Collections  int      `json:"collections"`
		Errors       []string `json:"errors,omitempty"`
		DetailSongs  int      `json:"detail_songs,omitempty"`
		DetailMS     int64    `json:"detail_ms,omitempty"`
		DetailFailed bool     `json:"detail_failed,omitempty"`
		Samples      []string `json:"samples,omitempty"`
	}
	queries := []string{"周杰伦", "周杰伦 晴天", "Mine Mine", "陈奕迅", "zzMusicDLNoMatch9f473a21"}
	kinds := []string{"song", "album", "playlist"}
	if os.Getenv("MUSICDL_SEARCH_QUALITY") != "" {
		queries = queries[2:]
		kinds = kinds[:1]
	}
	if os.Getenv("MUSICDL_SEARCH_BASELINE") != "" {
		queries = queries[:1]
		kinds = kinds[:1]
	}
	sources := append(core.GetMusicPlatformNames(), "local")
	var rows []observation
	var mu sync.Mutex
	jobs := make(chan observation)
	var workers sync.WaitGroup
	started := time.Now()
	var firstResult int64
	for i := 0; i < 3; i++ {
		workers.Add(1)
		go func() {
			defer workers.Done()
			for row := range jobs {
				params := map[string]json.RawMessage{}
				for key, value := range map[string]interface{}{"q": row.Query, "type": row.Kind, "sources": []string{row.Source}} {
					params[key], _ = json.Marshal(value)
				}
				begin := time.Now()
				result, err := nativeSearch(params)
				row.Milliseconds = time.Since(begin).Milliseconds()
				row.Songs = len(result.Songs)
				if os.Getenv("MUSICDL_SEARCH_QUALITY") != "" {
					for i, song := range result.Songs {
						if i >= 3 {
							break
						}
						row.Samples = append(row.Samples, song.Name+" / "+song.Artist)
					}
				}
				row.Collections = len(result.Playlists)
				row.Errors = result.Errors
				if err != nil {
					row.Errors = append(row.Errors, err.Error())
				}
				if os.Getenv("MUSICDL_SEARCH_DETAILS") != "" && row.Query == "周杰伦" && row.Kind != "song" && row.Source != "local" && len(result.Playlists) > 0 {
					detailStart := time.Now()
					detailParams := map[string]json.RawMessage{}
					for key, value := range map[string]string{"id": result.Playlists[0].ID, "source": row.Source, "kind": row.Kind} {
						detailParams[key], _ = json.Marshal(value)
					}
					detail, detailErr := nativeDetail("detail", detailParams)
					row.DetailMS = time.Since(detailStart).Milliseconds()
					row.DetailSongs = len(detail.Songs)
					row.DetailFailed = detailErr != nil
				}

				mu.Lock()
				if firstResult == 0 && row.Songs+row.Collections > 0 {
					firstResult = time.Since(started).Milliseconds()
				}
				rows = append(rows, row)
				mu.Unlock()
				t.Logf("real-api kind=%s source=%s ms=%d songs=%d collections=%d failed=%t", row.Kind, row.Source, row.Milliseconds, row.Songs, row.Collections, len(row.Errors) > 0)
			}
		}()
	}
	for _, q := range queries {
		for _, kind := range kinds {
			for _, source := range sources {
				if source == "local" && kind == "album" {
					continue
				}
				jobs <- observation{Query: q, Kind: kind, Source: source}
			}
		}
	}
	close(jobs)
	workers.Wait()
	report := map[string]interface{}{"at": time.Now().UTC(), "parallel": 3, "first_result_ms": firstResult, "total_ms": time.Since(started).Milliseconds(), "rows": rows, "credentials": "isolated test database; no personal account credentials loaded"}
	if os.Getenv("MUSICDL_SEARCH_DETAILS") != "" {
		params := map[string]json.RawMessage{"q": json.RawMessage(`"周杰伦 晴天"`), "sources": json.RawMessage(`["kugou"]`)}
		originalResult, _ := nativeSearch(params)
		if len(originalResult.Songs) > 0 {
			original := originalResult.Songs[0]
			rawSong, _ := json.Marshal(original)
			candidateResult, candidateErr := nativeSwitchCandidates(map[string]json.RawMessage{"song": rawSong})
			flow := map[string]interface{}{"candidate_search_failed": candidateErr != nil, "original_source": original.Source, "original_name": original.Name, "original_artist": original.Artist}
			if candidateErr == nil {
				data, _ := json.Marshal(candidateResult)
				var decoded struct {
					Candidates []nativeSwitchCandidate `json:"candidates"`
				}
				_ = json.Unmarshal(data, &decoded)
				flow["candidates"] = len(decoded.Candidates)
				var probes []map[string]interface{}
				for i, candidate := range decoded.Candidates {
					if i >= 6 {
						break
					}
					rawCandidate, _ := json.Marshal(candidate.Song)
					begin := time.Now()
					_, probeErr := nativeValidateSwitch(map[string]json.RawMessage{"original": rawSong, "song": rawCandidate})
					probes = append(probes, map[string]interface{}{"source": candidate.Song.Source, "name": candidate.Song.Name, "milliseconds": time.Since(begin).Milliseconds(), "verified": probeErr == nil})
				}
				flow["audio_probes"] = probes
			}
			report["switch_source"] = flow
		}
	}

	raw, err := json.MarshalIndent(report, "", "  ")
	if err != nil {
		t.Fatal(err)
	}
	if err = os.WriteFile(output, raw, 0600); err != nil {
		t.Fatal(err)
	}
}
