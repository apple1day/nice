package main

import (
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"unicode"
	"unicode/utf8"
)

// Native uploads are create-only. They never use ParseMultipartForm or expose
// partially received videos. The existing browser multipart endpoint is unchanged.
const nativeUploadMaxBytes int64 = 20 << 30

var uploadIDPattern = regexp.MustCompile(`^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$`)
var nativeUploadExtensions = map[string]bool{
	".mp4": true, ".m4v": true, ".mov": true, ".mkv": true, ".avi": true,
	".webm": true, ".ogg": true, ".flv": true, ".wmv": true, ".ts": true,
}

type nativeUploadReceipt struct {
	Version  int    `json:"version"`
	UploadID string `json:"uploadID"`
	Name     string `json:"name"`
	Size     int64  `json:"size"`
}

func validNativeUploadName(name string) bool {
	if name == "" || len(name) > 240 || !utf8.ValidString(name) ||
		strings.HasPrefix(name, ".") || strings.ContainsAny(name, `/\\`) ||
		filepath.Base(name) != name || strings.IndexFunc(name, unicode.IsControl) >= 0 {
		return false
	}
	return nativeUploadExtensions[strings.ToLower(filepath.Ext(name))]
}

func nativeUploadJSON(w http.ResponseWriter, status int, value any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(value)
}

func nativeUploadError(w http.ResponseWriter, status int, message string) {
	nativeUploadJSON(w, status, map[string]string{"error": message})
}

func newNativeUploadHandler(root string, maxBytes int64) http.Handler {
	// At most two incoming writers per server; the app submits files serially.
	slots := make(chan struct{}, 2)
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("X-Nice-Upload-Version", "1")
		w.Header().Set("X-Nice-Upload-Max-Bytes", strconv.FormatInt(maxBytes, 10))
		if r.Method != http.MethodPost && r.Method != http.MethodHead {
			w.Header().Set("Allow", "POST, HEAD")
			nativeUploadError(w, http.StatusMethodNotAllowed, "method not allowed")
			return
		}
		names, ok := r.URL.Query()["name"]
		if !ok || len(names) != 1 || !validNativeUploadName(names[0]) {
			nativeUploadError(w, http.StatusBadRequest, "非法视频文件名或格式")
			return
		}
		name := names[0]
		target := filepath.Join(root, name)
		// Lstat rejects files, directories AND dangling symlinks without following them.
		if _, err := os.Lstat(target); err == nil {
			nativeUploadError(w, http.StatusConflict, "服务器已存在同名项目，未覆盖；请先核对服务器文件")
			return
		} else if !os.IsNotExist(err) {
			nativeUploadError(w, http.StatusInternalServerError, "无法检查服务器目标路径")
			return
		}
		if r.Method == http.MethodHead {
			w.WriteHeader(http.StatusNoContent)
			return
		}
		if r.Header.Get("Content-Type") != "application/octet-stream" || r.Header.Get("Content-Encoding") != "" {
			nativeUploadError(w, http.StatusUnsupportedMediaType, "请发送未压缩的完整文件内容")
			return
		}
		uploadID := r.Header.Get("X-Nice-Upload-ID")
		expected, err := strconv.ParseInt(r.Header.Get("X-Nice-Upload-Bytes"), 10, 64)
		if !uploadIDPattern.MatchString(uploadID) || err != nil || expected <= 0 {
			nativeUploadError(w, http.StatusBadRequest, "上传标识或文件大小无效")
			return
		}
		if expected > maxBytes {
			nativeUploadError(w, http.StatusRequestEntityTooLarge, "视频超过服务器单文件上传上限")
			return
		}
		if r.ContentLength >= 0 && r.ContentLength != expected {
			nativeUploadError(w, http.StatusBadRequest, "请求长度与声明文件大小不一致")
			return
		}
		select {
		case slots <- struct{}{}:
			defer func() { <-slots }()
		default:
			nativeUploadError(w, http.StatusTooManyRequests, "服务器正在接收其他视频，请稍后重试")
			return
		}
		// .part is not a supported video extension, so list/download-all ignore it.
		temp, err := os.CreateTemp(root, ".nice-upload-*.part")
		if err != nil {
			nativeUploadError(w, http.StatusInsufficientStorage, "服务器无法创建临时文件，请检查空间和权限")
			return
		}
		defer func() { _ = temp.Close(); _ = os.Remove(temp.Name()) }()
		defer r.Body.Close()
		count, err := io.CopyBuffer(temp, http.MaxBytesReader(w, r.Body, expected), make([]byte, 64*1024))
		if err != nil || count != expected || r.Context().Err() != nil {
			var diskError *os.PathError
			if errors.As(err, &diskError) {
				nativeUploadError(w, http.StatusInsufficientStorage, "服务器写入失败，请检查空间和权限")
				return
			}
			nativeUploadError(w, http.StatusBadRequest, "上传中断或文件长度不完整，未保存到视频列表")
			return
		}
		if err = temp.Sync(); err != nil {
			nativeUploadError(w, http.StatusInsufficientStorage, "服务器写入失败，请检查剩余空间")
			return
		}
		if err = temp.Close(); err != nil {
			nativeUploadError(w, http.StatusInternalServerError, "服务器关闭上传文件失败")
			return
		}
		// An atomic, exclusive publication on the SAME filesystem. Unlike Rename,
		// Link cannot overwrite a concurrently created target (including symlinks).
		if err = os.Link(temp.Name(), target); err != nil {
			if os.IsExist(err) {
				nativeUploadError(w, http.StatusConflict, "服务器已存在同名项目，未覆盖")
			} else {
				nativeUploadError(w, http.StatusInternalServerError, "服务器文件发布失败，请确认文件系统支持硬链接")
			}
			return
		}
		// Persist the directory entry where supported before acknowledging success.
		if directory, openErr := os.Open(root); openErr == nil {
			_ = directory.Sync()
			_ = directory.Close()
		}
		nativeUploadJSON(w, http.StatusCreated, nativeUploadReceipt{1, uploadID, name, count})
	})
}

// Wrapped around the existing router in main; no changes to existing endpoints.
func withNativeUploads(next http.Handler, root string) http.Handler {
	uploads := newNativeUploadHandler(root, nativeUploadMaxBytes)
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/api/upload-file" {
			uploads.ServeHTTP(w, r)
			return
		}
		next.ServeHTTP(w, r)
	})
}
