package web

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"mime/multipart"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/guohuiyuan/go-music-dl/core"
)

const nativeClientOrigin = "http://127.0.0.1:37777"

var nativeClientHTTP = &http.Client{Timeout: 90 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return errors.New("native API redirects are disabled") }}

func nativeRouteID(params map[string]json.RawMessage) (string, error) {
	id := nativeString(params, "id")
	value, err := strconv.ParseUint(id, 10, 32)
	if err != nil || value == 0 {
		return "", errors.New("invalid resource id")
	}
	return strconv.FormatUint(value, 10), nil
}

func nativeJSONRoute(action string, params map[string]json.RawMessage) (interface{}, error) {
	method, path := http.MethodGet, ""
	query := url.Values{}
	var body interface{}
	var err error
	resourceID := func() string { var id string; id, err = nativeRouteID(params); return id }
	switch action {
	case "collections.list":
		path = "/collections"
		query.Set("include_imported", "1")
	case "collections.create":
		method = http.MethodPost
		path = "/collections"
		body = params
	case "collections.import":
		method = http.MethodPost
		path = "/collections/import"
		body = params
	case "collections.update":
		method = http.MethodPut
		path = "/collections/" + resourceID()
		values := map[string]json.RawMessage{}
		for _, key := range []string{"name", "description", "cover"} {
			if value, ok := params[key]; ok {
				values[key] = value
			}
		}
		body = values
	case "collections.delete":
		method = http.MethodDelete
		path = "/collections/" + resourceID()
	case "collections.add":
		method = http.MethodPost
		path = "/collections/" + resourceID() + "/songs"
		var song map[string]interface{}
		if parseErr := json.Unmarshal(params["song"], &song); parseErr != nil {
			return nil, errors.New("invalid song")
		}
		if extra, ok := song["extra"].(string); ok {
			var value interface{}
			if json.Unmarshal([]byte(extra), &value) == nil {
				song["extra"] = value
			}
		}
		body = song
	case "collections.remove":
		method = http.MethodDelete
		path = "/collections/" + resourceID() + "/songs"
		var song map[string]interface{}
		if parseErr := json.Unmarshal(params["song"], &song); parseErr != nil {
			return nil, errors.New("invalid song")
		}
		body = map[string]interface{}{"songs": []interface{}{song}}
	case "local.list":
		path = "/local_music"
		for _, key := range []string{"offset", "limit", "refresh", "collection_id"} {
			if value := nativeString(params, key); value != "" {
				query.Set(key, value)
			}
		}
	case "local.delete":
		method = http.MethodDelete
		path = "/local_music"
		query.Set("id", nativeString(params, "id"))
	case "local.reindex":
		method = http.MethodPost
		path = "/local_music/reindex"
	case "downloads.list":
		path = "/api/downloads/queue"
		for _, key := range []string{"page", "status"} {
			if value := nativeString(params, key); value != "" {
				query.Set(key, value)
			}
		}
	case "downloads.enqueue":
		method = http.MethodPost
		path = "/api/downloads/queue"
		var songs []map[string]interface{}
		if parseErr := json.Unmarshal(params["songs"], &songs); parseErr != nil {
			return nil, errors.New("invalid download songs")
		}
		for _, song := range songs {
			if extra, ok := song["extra"]; ok {
				if _, ok := extra.(string); !ok {
					encoded, _ := json.Marshal(extra)
					song["extra"] = string(encoded)
				}
			}
		}
		body = map[string]interface{}{"request_id": nativeString(params, "request_id"), "songs": songs}
	case "downloads.action":
		method = http.MethodPost
		command := nativeString(params, "action")
		if command != "retry" && command != "cancel" {
			return nil, errors.New("unsupported download action")
		}
		path = "/api/downloads/queue/" + resourceID() + "/" + command
	case "downloads.remove":
		method = http.MethodDelete
		path = "/api/downloads/queue/" + resourceID()
	case "downloads.clear":
		method = http.MethodDelete
		path = "/api/downloads/queue"
	case "downloads.records":
		path = "/api/downloads/records"
		query.Set("page", strconv.Itoa(max(1, nativeInt(params, "page", 1))))
	case "qr.create", "qr.check":
		source := nativeString(params, "source")
		if !nativeMembership(source, coreQRLoginSources()) {
			return nil, errors.New("unsupported QR login source")
		}
		path = "/qr_login/" + url.PathEscape(source)
		if action == "qr.create" {
			method = http.MethodPost
		} else {
			query.Set("key", nativeString(params, "key"))
		}
	case "ai.index":
		path = "/api/ai/index"
	case "ai.state":
		path = "/api/ai/player/state"
		query.Set("client_id", nativeString(params, "client_id"))
	case "ai.publish":
		method = http.MethodPost
		path = "/api/ai/player/state"
		body = params
	case "ai.command":
		method = http.MethodPost
		path = "/api/ai/player/command"
		body = params
	case "ai.play":
		method = http.MethodPost
		path = "/api/ai/player/play"
		body = params
	default:
		return nil, fmt.Errorf("unsupported native action: %s", action)
	}
	if err != nil {
		return nil, err
	}
	var reader io.Reader
	if body != nil {
		encoded, err := json.Marshal(body)
		if err != nil {
			return nil, err
		}
		reader = bytes.NewReader(encoded)
	}
	request, err := http.NewRequest(method, nativeClientOrigin+RoutePrefix+path+nativeQuerySuffix(query), reader)
	if err != nil {
		return nil, err
	}
	request.Header.Set("Content-Type", "application/json")
	request.Header.Set("X-Requested-With", "XMLHttpRequest")
	request.Header.Set("Origin", nativeClientOrigin)
	return nativePerformJSON(request)
}

func coreQRLoginSources() []string { return core.GetQRLoginSourceNames() }

func nativeQuerySuffix(query url.Values) string {
	if len(query) == 0 {
		return ""
	}
	return "?" + query.Encode()
}

func nativePerformJSON(request *http.Request) (interface{}, error) {
	response, err := nativeClientHTTP.Do(request)
	if err != nil {
		return nil, errors.New("本地功能服务暂不可用，请重试")
	}
	defer response.Body.Close()
	encoded, err := io.ReadAll(io.LimitReader(response.Body, (16<<20)+1))
	if err != nil {
		return nil, errors.New("could not read native API response")
	}
	if len(encoded) > 16<<20 {
		return nil, errors.New("native API response exceeds 16 MB")
	}
	var data interface{}
	if len(encoded) == 0 && response.StatusCode >= 200 && response.StatusCode < 300 {
		return map[string]string{"status": "ok"}, nil
	}
	if err = json.Unmarshal(encoded, &data); err != nil {
		return nil, fmt.Errorf("native API returned non-JSON (HTTP %d)", response.StatusCode)
	}
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		if payload, ok := data.(map[string]interface{}); ok {
			if message, ok := payload["error"].(string); ok {
				return nil, errors.New(message)
			}
		}
		return nil, fmt.Errorf("native API HTTP %d", response.StatusCode)
	}
	return data, nil
}

func nativeImportFile(params map[string]json.RawMessage) (interface{}, error) {
	path, err := filepath.EvalSymlinks(nativeString(params, "path"))
	if err != nil {
		return nil, errors.New("import file does not exist")
	}
	tempRoot, err := filepath.EvalSymlinks(os.TempDir())
	if err != nil {
		return nil, err
	}
	relative, err := filepath.Rel(tempRoot, path)
	if err != nil || filepath.IsAbs(relative) || relative == ".." || strings.HasPrefix(relative, ".."+string(filepath.Separator)) {
		return nil, errors.New("native imports must be copied into the app temporary directory first")
	}
	info, err := os.Stat(path)
	if err != nil || !info.Mode().IsRegular() {
		return nil, errors.New("invalid import file")
	}
	if info.Size() <= 0 || info.Size() > 512<<20 {
		return nil, errors.New("import file must be between 1 byte and 512 MB")
	}
	file, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer file.Close()
	pipeReader, pipeWriter := io.Pipe()
	writer := multipart.NewWriter(pipeWriter)
	defer pipeReader.Close()
	go func() {
		part, err := writer.CreateFormFile("file", filepath.Base(path))
		if err == nil {
			_, err = io.Copy(part, file)
		}
		if err == nil {
			err = writer.Close()
		}
		pipeWriter.CloseWithError(err)
	}()
	request, err := http.NewRequest(http.MethodPost, nativeClientOrigin+RoutePrefix+"/local_music/upload", pipeReader)
	if err != nil {
		return nil, err
	}
	request.Header.Set("Content-Type", writer.FormDataContentType())
	request.Header.Set("X-Requested-With", "XMLHttpRequest")
	request.Header.Set("Origin", nativeClientOrigin)
	return nativePerformJSON(request)
}
