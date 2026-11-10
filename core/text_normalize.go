package core

import (
	"strings"
	"sync"

	"github.com/guohuiyuan/music-lib/model"
	"github.com/liuzl/gocc"
	"golang.org/x/text/unicode/norm"
)

var (
	chineseConverterOnce sync.Once
	chineseConverter     *gocc.OpenCC
	chineseConverterErr  error
)

// normalizeVariantText removes invisible filename characters and folds common
// Traditional/Simplified Chinese variants to a stable comparison form.
func normalizeVariantText(value string) string {
	value = strings.Map(func(r rune) rune {
		switch r {
		case '\u200b', '\u200c', '\u200d', '\ufeff':
			return -1
		default:
			return r
		}
	}, value)
	value = norm.NFKC.String(strings.TrimSpace(value))
	if value == "" {
		return ""
	}

	chineseConverterOnce.Do(func() {
		chineseConverter, chineseConverterErr = gocc.New("t2s")
	})
	if chineseConverterErr != nil || chineseConverter == nil {
		return value
	}
	converted, err := chineseConverter.Convert(value)
	if err != nil || converted == "" {
		return value
	}
	return converted
}

// NormalizeSearchQuery folds width, invisible characters and Chinese variants,
// while retaining spaces and punctuation meaningful to provider search APIs.
func NormalizeSearchQuery(value string) string {
	return strings.Join(strings.Fields(normalizeVariantText(value)), " ")
}

// SearchMatchText is for metadata comparison, never provider IDs or signed URLs.
func SearchMatchText(value string) string { return NormalizeText(normalizeVariantText(value)) }

// NormalizeSongForDownload returns a copy with normalized display metadata for
// filename templates. Lookup IDs and source-specific extra data stay untouched.
func NormalizeSongForDownload(song *model.Song) *model.Song {
	if song == nil {
		return nil
	}
	normalized := *song
	normalized.Name = normalizeVariantText(normalized.Name)
	normalized.Artist = normalizeVariantText(normalized.Artist)
	normalized.Album = normalizeVariantText(normalized.Album)
	return &normalized
}
