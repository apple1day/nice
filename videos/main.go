package main

import (
	"archive/zip"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"
)

// ---------- 配置 ----------
var (
	videoDir  string
	staticDir string
	dataDir   string
	port      string
)

// videoMeta 描述一个视频文件
type videoMeta struct {
	Name         string `json:"name"`
	Size         int64  `json:"size"`
	ContentType  string `json:"contentType"`
	URL          string `json:"url"`                    // 播放地址
	DownloadURL  string `json:"downloadUrl"`            // 下载地址
	Downloaded   bool   `json:"downloaded"`             // 是否已被下载过
	DownloadedAt string `json:"downloadedAt,omitempty"` // 最近一次下载时间
}

// 允许作为视频的文件扩展名
var videoExts = map[string]string{
	".mp4":  "video/mp4",
	".webm": "video/webm",
	".ogg":  "video/ogg",
	".mov":  "video/quicktime",
	".m4v":  "video/x-m4v",
	".avi":  "video/x-msvideo",
	".mkv":  "video/x-matroska",
	".flv":  "video/x-flv",
	".wmv": "video/x-ms-wmv",
	".ts":   "video/mp2t",
	".m3u8": "application/vnd.apple.mpegurl",
}

func init() {
	loadDotEnv() // 先加载 .env 文件，再读取环境变量
	// /Users/even/mine/down  测试用目录
	videoDir = getEnv("VIDEO_DIR", "/Users/even/mine/down")
	staticDir = getEnv("STATIC_DIR", "./static")
	dataDir = getEnv("DATA_DIR", "./data")
	port = getEnv("PORT", "8106")

	for _, d := range []string{videoDir, staticDir, dataDir} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			log.Fatalf("无法创建目录 %s: %v", d, err)
		}
	}
	loadDownloadRecords()
}

// loadDotEnv 加载可执行目录下的 .env 文件（KEY=VALUE 格式，# 开头为注释）。
// 已存在的环境变量优先，不会被 .env 覆盖。
func loadDotEnv() {
	b, err := os.ReadFile(".env")
	if err != nil {
		return // 没有 .env 就直接用系统环境变量/默认值
	}
	for _, line := range strings.Split(string(b), "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		k, v, ok := strings.Cut(line, "=")
		if !ok {
			continue
		}
		k = strings.TrimSpace(k)
		v = strings.Trim(strings.TrimSpace(v), `"'`) // 去掉值两边可能的引号
		if k != "" && os.Getenv(k) == "" {
			os.Setenv(k, v)
		}
	}
}

func getEnv(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

// safePath 将请求的文件名限制在 videoDir 内，防止路径穿越
func safePath(name string) (string, bool) {
	base := filepath.Base(name) // 丢弃任何目录成分
	if base == "." || base == string(os.PathSeparator) || base == "" {
		return "", false
	}
	full := filepath.Join(videoDir, base)
	// 再次确认结果仍在 videoDir 内
	absVideo, _ := filepath.Abs(videoDir)
	absFull, _ := filepath.Abs(full)
	if !strings.HasPrefix(absFull, absVideo) {
		return "", false
	}
	return full, true
}

// ---------- 下载记录 ----------

// downloadRecord 记录某个视频被下载过一次
type downloadRecord struct {
	Name string `json:"name"`
	Time string `json:"time"`
}

var (
	dlMu      sync.Mutex
	dlRecords = map[string]downloadRecord{}
)

func downloadLogPath() string {
	return filepath.Join(dataDir, "downloads.json")
}

// loadDownloadRecords 启动时加载历史下载记录
func loadDownloadRecords() {
	b, err := os.ReadFile(downloadLogPath())
	if err != nil {
		if !os.IsNotExist(err) {
			log.Printf("[DOWNLOAD] 读取下载记录失败: %v", err)
		}
		return
	}
	var m map[string]downloadRecord
	if err := json.Unmarshal(b, &m); err != nil {
		log.Printf("[DOWNLOAD] 解析下载记录失败: %v", err)
		return
	}
	if m != nil {
		dlMu.Lock()
		dlRecords = m
		dlMu.Unlock()
	}
	log.Printf("[DOWNLOAD] 已加载 %d 条下载记录", len(dlRecords))
}

// saveDownloadRecords 原子落盘下载记录（调用方需持有 dlMu）
func saveDownloadRecords() {
	b, err := json.MarshalIndent(dlRecords, "", "  ")
	if err != nil {
		log.Printf("[DOWNLOAD] 序列化下载记录失败: %v", err)
		return
	}
	tmp := downloadLogPath() + ".tmp"
	if err := os.WriteFile(tmp, b, 0o644); err != nil {
		log.Printf("[DOWNLOAD] 写入下载记录失败: %v", err)
		return
	}
	if err := os.Rename(tmp, downloadLogPath()); err != nil {
		log.Printf("[DOWNLOAD] 替换下载记录失败: %v", err)
	}
}

// markDownloaded 标记若干视频为已下载
func markDownloaded(names ...string) {
	if len(names) == 0 {
		return
	}
	now := time.Now().Format(time.RFC3339)
	dlMu.Lock()
	defer dlMu.Unlock()
	for _, n := range names {
		dlRecords[n] = downloadRecord{Name: n, Time: now}
	}
	saveDownloadRecords()
}

// downloadInfo 返回视频是否已下载及其下载时间
func downloadInfo(name string) (bool, string) {
	dlMu.Lock()
	defer dlMu.Unlock()
	rec, ok := dlRecords[name]
	return ok, rec.Time
}

func contentTypeOf(name string) string {
	ext := strings.ToLower(filepath.Ext(name))
	if ct, ok := videoExts[ext]; ok {
		return ct
	}
	return "application/octet-stream"
}

// ---------- 业务处理 ----------

// listVideos 返回视频列表
func listVideos(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	entries, err := os.ReadDir(videoDir)
	if err != nil {
		http.Error(w, "无法读取视频目录", http.StatusInternalServerError)
		return
	}
	videos := make([]videoMeta, 0)
	for _, name := range listVideoNames(entries) {
		info, err := os.Stat(filepath.Join(videoDir, name))
		if err != nil {
			continue
		}
		downloaded, at := downloadInfo(name)
		videos = append(videos, videoMeta{
			Name:         name,
			Size:         info.Size(),
			ContentType:  contentTypeOf(name),
			URL:          "/api/stream/" + url.PathEscape(name),
			DownloadURL:  "/api/download/" + url.PathEscape(name),
			Downloaded:   downloaded,
			DownloadedAt: at,
		})
	}
	// 按名称排序，保持稳定
	sort.Slice(videos, func(i, j int) bool {
		return videos[i].Name < videos[j].Name
	})
	writeJSON(w, map[string]any{"videos": videos})
}

// listVideoNames 从目录项中筛选出视频文件名（按名称排序）
func listVideoNames(entries []os.DirEntry) []string {
	names := make([]string, 0, len(entries))
	for _, e := range entries {
		if e.IsDir() {
			continue
		}
		name := e.Name()
		if _, ok := videoExts[strings.ToLower(filepath.Ext(name))]; ok {
			names = append(names, name)
		}
	}
	sort.Strings(names)
	return names
}

// listAllVideoNames 读取视频目录下的全部视频文件名
func listAllVideoNames() ([]string, error) {
	entries, err := os.ReadDir(videoDir)
	if err != nil {
		return nil, err
	}
	return listVideoNames(entries), nil
}

// streamVideo 流式播放，支持 HTTP Range，供 <video> 标签使用
func streamVideo(w http.ResponseWriter, r *http.Request) {
	name := strings.TrimPrefix(r.URL.Path, "/api/stream/")
	path, ok := safePath(name)
	if !ok {
		http.Error(w, "非法文件名", http.StatusBadRequest)
		return
	}
	f, err := os.Open(path)
	if err != nil {
		http.Error(w, "视频不存在", http.StatusNotFound)
		return
	}
	defer f.Close()

	info, err := f.Stat()
	if err != nil {
		http.Error(w, "读取文件信息失败", http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", contentTypeOf(name))
	w.Header().Set("Accept-Ranges", "bytes")
	w.Header().Set("Cache-Control", "no-cache")
	http.ServeContent(w, r, name, info.ModTime(), f)
}

// downloadVideo 以附件形式下载
func downloadVideo(w http.ResponseWriter, r *http.Request) {
	name := strings.TrimPrefix(r.URL.Path, "/api/download/")
	path, ok := safePath(name)
	if !ok {
		http.Error(w, "非法文件名", http.StatusBadRequest)
		return
	}
	f, err := os.Open(path)
	if err != nil {
		http.Error(w, "视频不存在", http.StatusNotFound)
		return
	}
	defer f.Close()

	info, err := f.Stat()
	if err != nil {
		http.Error(w, "读取文件信息失败", http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", contentTypeOf(name))
	w.Header().Set("Content-Disposition", fmt.Sprintf("attachment; filename=\"%s\"", name))
	w.Header().Set("Accept-Ranges", "bytes")
	markDownloaded(name)
	log.Printf("[DOWNLOAD] 记录下载: %s", name)
	http.ServeContent(w, r, name, info.ModTime(), f)
}

// downloadAllVideos 把全部视频打包成 zip 一次性下载，并标记为已下载
func downloadAllVideos(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	names, err := listAllVideoNames()
	if err != nil {
		http.Error(w, "无法读取视频目录", http.StatusInternalServerError)
		return
	}
	if len(names) == 0 {
		http.Error(w, "没有可下载的视频", http.StatusNotFound)
		return
	}

	zipName := "videos-" + time.Now().Format("20060102-150405") + ".zip"
	w.Header().Set("Content-Type", "application/zip")
	w.Header().Set("Content-Disposition", fmt.Sprintf("attachment; filename=\"%s\"", zipName))
	w.Header().Set("Cache-Control", "no-cache")

	zw := zip.NewWriter(w)
	defer zw.Close()

	packed := make([]string, 0, len(names))
	var lastErr error
	for _, name := range names {
		path, ok := safePath(name)
		if !ok {
			continue
		}
		f, err := os.Open(path)
		if err != nil {
			log.Printf("[DOWNLOAD-ALL] 跳过（无法打开）: %s 错误: %v", name, err)
			continue
		}
		info, err := f.Stat()
		if err != nil {
			f.Close()
			continue
		}
		fh, err := zip.FileInfoHeader(info)
		if err != nil {
			f.Close()
			continue
		}
		fh.Name = name
		fh.Method = zip.Store // 视频已压缩，直接存储，避免无谓的 CPU 开销
		dw, err := zw.CreateHeader(fh)
		if err != nil {
			f.Close()
			lastErr = err
			break
		}
		if _, err := io.Copy(dw, f); err != nil {
			f.Close()
			lastErr = err
			break
		}
		f.Close()
		packed = append(packed, name)
	}

	markDownloaded(packed...)
	log.Printf("[DOWNLOAD-ALL] 打包完成: %d/%d 个文件，zip=%s", len(packed), len(names), zipName)
	if lastErr != nil {
		log.Printf("[DOWNLOAD-ALL] 打包中断: %v", lastErr)
	}
}

// uploadVideo 上传视频到视频目录
func uploadVideo(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	if err := r.ParseMultipartForm(2 << 30); err != nil { // 最大 2GB
		http.Error(w, "解析上传表单失败", http.StatusBadRequest)
		return
	}
	files := r.MultipartForm.File["file"]
	if len(files) == 0 {
		http.Error(w, "未找到上传文件", http.StatusBadRequest)
		return
	}
	uploaded := make([]string, 0, len(files))
	for _, header := range files {
		ext := strings.ToLower(filepath.Ext(header.Filename))
		if _, ok := videoExts[ext]; !ok {
			writeJSON(w, map[string]any{"error": "不支持的文件类型: " + header.Filename})
			return
		}
		dst, ok := safePath(header.Filename)
		if !ok {
			http.Error(w, "非法文件名", http.StatusBadRequest)
			return
		}
		src, err := header.Open()
		if err != nil {
			http.Error(w, "打开上传文件失败", http.StatusInternalServerError)
			return
		}
		out, err := os.Create(dst)
		if err != nil {
			src.Close()
			http.Error(w, "保存文件失败", http.StatusInternalServerError)
			return
		}
		if _, err := io.Copy(out, src); err != nil {
			src.Close()
			out.Close()
			http.Error(w, "写入文件失败", http.StatusInternalServerError)
			return
		}
		src.Close()
		out.Close()
		uploaded = append(uploaded, header.Filename)
	}
	writeJSON(w, map[string]any{"uploaded": uploaded})
}

// deleteVideo 删除视频
func deleteVideo(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodDelete {
		log.Printf("[DELETE] 方法不允许: %s %s", r.Method, r.URL.Path)
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	name := strings.TrimPrefix(r.URL.Path, "/api/videos/")
	log.Printf("[DELETE] 收到删除请求 raw=%q decoded=%q", r.URL.Path, name)
	path, ok := safePath(name)
	if !ok {
		log.Printf("[DELETE] 非法文件名被拒绝: %q", name)
		writeJSONErr(w, "非法文件名", http.StatusBadRequest)
		return
	}
	log.Printf("[DELETE] 解析到目标文件: %s", path)
	if err := os.Remove(path); err != nil {
		if os.IsNotExist(err) {
			log.Printf("[DELETE] 文件不存在: %s", path)
			writeJSONErr(w, "视频不存在", http.StatusNotFound)
			return
		}
		// 打印底层错误，方便定位（权限不足 / 文件被占用等）
		log.Printf("[DELETE] 删除失败: %s 错误: %v", path, err)
		writeJSONErr(w, "删除失败: "+err.Error(), http.StatusInternalServerError)
		return
	}
	log.Printf("[DELETE] 删除成功: %s", path)
	writeJSON(w, map[string]any{"deleted": name})
}

// writeJSONErr 返回带错误信息的 JSON，便于前端直接展示
func writeJSONErr(w http.ResponseWriter, msg string, code int) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(code)
	json.NewEncoder(w).Encode(map[string]any{"error": msg})
}

func writeJSON(w http.ResponseWriter, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	json.NewEncoder(w).Encode(v)
}

// statusRecorder 记录响应状态码，供日志使用
type statusRecorder struct {
	http.ResponseWriter
	status int
}

func (r *statusRecorder) WriteHeader(code int) {
	r.status = code
	r.ResponseWriter.WriteHeader(code)
}

// logRequest 记录每个请求的方法、路径与状态码
func logRequest(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		rec := &statusRecorder{ResponseWriter: w, status: http.StatusOK}
		next.ServeHTTP(rec, r)
		log.Printf("[ACCESS] %s %s -> %d", r.Method, r.URL.Path, rec.status)
	})
}

// 允许前端跨域（前后端分离时若分开部署可用）
func cors(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Access-Control-Allow-Origin", "*")
		w.Header().Set("Access-Control-Allow-Methods", "GET, POST, DELETE, OPTIONS")
		w.Header().Set("Access-Control-Allow-Headers", "Content-Type")
		if r.Method == http.MethodOptions {
			w.WriteHeader(http.StatusNoContent)
			return
		}
		next.ServeHTTP(w, r)
	})
}

// spa 静态文件服务，未匹配到文件时回退到 index.html
func spaHandler() http.Handler {
	fileServer := http.FileServer(http.Dir(staticDir))
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// 前端资源每次都校验，避免改了 js/css 后浏览器还用旧缓存
		w.Header().Set("Cache-Control", "no-cache, must-revalidate")
		// 只处理非 /api 路径
		if strings.HasPrefix(r.URL.Path, "/api/") {
			http.NotFound(w, r)
			return
		}
		p := filepath.Join(staticDir, filepath.Clean(r.URL.Path))
		if info, err := os.Stat(p); err != nil || info.IsDir() {
			// 回退到 index.html（单页应用）
			data, err := os.ReadFile(filepath.Join(staticDir, "index.html"))
			if err != nil {
				http.NotFound(w, r)
				return
			}
			w.Header().Set("Content-Type", "text/html; charset=utf-8")
			w.Write(data)
			return
		}
		fileServer.ServeHTTP(w, r)
	})
}

func main() {
	mux := http.NewServeMux()
	mux.HandleFunc("/api/videos", listVideos)
	mux.HandleFunc("/api/videos/", deleteVideo) // DELETE /api/videos/{name}
	mux.HandleFunc("/api/stream/", streamVideo)
	mux.HandleFunc("/api/download/", downloadVideo)
	mux.HandleFunc("/api/download-all", downloadAllVideos) // 一键下载全部（zip 打包）
	mux.HandleFunc("/api/upload", uploadVideo)
	mux.Handle("/", spaHandler())

	handler := logRequest(cors(withNativeUploads(mux, videoDir)))

	addr := ":" + port
	log.Printf("视频站点已启动: http://localhost%s", addr)
	log.Printf("视频目录: %s", videoDir)
	log.Printf("前端目录: %s", staticDir)
	if err := http.ListenAndServe(addr, handler); err != nil {
		log.Fatalf("服务启动失败: %v", err)
	}
}
