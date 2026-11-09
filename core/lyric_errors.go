package core

// Shared lyric decoding and retry classification for retained sources.
import (
	"context"
	"errors"
	"io"
	"regexp"
	"strings"
	"unicode/utf8"

	"golang.org/x/text/encoding/simplifiedchinese"
	"golang.org/x/text/encoding/unicode"
)

var lyricTimeMarkers = regexp.MustCompile(`\[\d+:\d+(?:\.\d+)?\]|<\d+:\d+(?:\.\d+)?>`)
var lyricHeaderLine = regexp.MustCompile(`^\[[A-Za-z]+:[^\]]*\]$`)

type LyricFailure struct {
	Kind string
	Err  error
}

func (e *LyricFailure) Error() string { return e.Kind + ": " + e.Err.Error() }
func (e *LyricFailure) Unwrap() error { return e.Err }

func LyricFailureKind(err error) string {
	if err == nil {
		return ""
	}
	var failure *LyricFailure
	if errors.As(err, &failure) {
		return failure.Kind
	}
	text := strings.ToLower(err.Error())
	// Legacy providers return wrapped string errors rather than typed statuses.
	if strings.Contains(text, "decrypt") || strings.Contains(text, "parse") || strings.Contains(text, "decode") {
		return "format"
	}
	if strings.Contains(text, "not found") || strings.Contains(text, "status 404") || strings.Contains(text, "empty") {
		return "missing"
	}
	if strings.Contains(text, "status 429") || strings.Contains(text, "status 5") {
		return "server"
	}
	if strings.Contains(text, "status 401") || strings.Contains(text, "status 403") {
		return "authorization"
	}
	var network interface{ Timeout() bool }
	if errors.Is(err, context.DeadlineExceeded) || errors.Is(err, io.EOF) || errors.Is(err, io.ErrUnexpectedEOF) || errors.As(err, &network) || strings.Contains(text, "connection reset") {
		return "network"
	}
	return "unavailable"
}
func LyricRetryable(err error) bool {
	kind := LyricFailureKind(err)
	return kind == "network" || kind == "server"
}

func DecodeLyricText(body []byte, contentType string) (string, error) {
	charset := strings.ToLower(contentType)
	var err error
	if len(body) >= 2 && ((body[0] == 0xff && body[1] == 0xfe) || (body[0] == 0xfe && body[1] == 0xff)) {
		body, err = unicode.UTF16(unicode.LittleEndian, unicode.UseBOM).NewDecoder().Bytes(body)
	} else if strings.Contains(charset, "gbk") || strings.Contains(charset, "gb18030") || strings.Contains(charset, "gb2312") {
		body, err = simplifiedchinese.GB18030.NewDecoder().Bytes(body)
	}
	if err != nil || !utf8.Valid(body) || strings.Contains(string(body), "\ufffd") {
		return "", &LyricFailure{"format", errors.New("unsupported or invalid lyric encoding")}
	}
	text := strings.TrimSpace(strings.TrimPrefix(string(body), "\ufeff"))
	lower := strings.ToLower(text)
	if strings.Contains(lower, "<html") || strings.HasPrefix(lower, "<!doctype") || strings.HasPrefix(lower, "<?xml") || strings.HasPrefix(text, "{") {
		return "", &LyricFailure{"format", errors.New("response is not lyric text")}
	}
	if text == "" {
		return "", nil
	}
	for _, line := range strings.Split(text, "\n") {
		line = strings.TrimSpace(line)
		if lyricHeaderLine.MatchString(line) {
			continue
		}
		if strings.TrimSpace(lyricTimeMarkers.ReplaceAllString(line, "")) != "" {
			return text, nil
		}
	}
	return "", &LyricFailure{"missing", errors.New("lyric has no text")}
}
