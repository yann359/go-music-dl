package web

import (
	"strings"

	"github.com/guohuiyuan/go-music-dl/core"
	"github.com/guohuiyuan/music-lib/model"
)

func nativeSearchRelevance(song model.Song, query string) int {
	name, artist, album := core.SearchMatchText(song.Name), core.SearchMatchText(song.Artist), core.SearchMatchText(song.Album)
	needle := core.SearchMatchText(query)
	score := 0
	if name == needle {
		score += 100
	}
	if artist == needle {
		score += 80
	}
	if name+artist == needle || artist+name == needle {
		score += 120
	}
	for _, token := range strings.Fields(query) {
		word := core.SearchMatchText(token)
		if word == "" {
			continue
		}
		if strings.Contains(name, word) {
			score += 15
		}
		if strings.Contains(artist, word) {
			score += 12
		}
		if strings.Contains(album, word) {
			score += 3
		}
	}
	return score
}
