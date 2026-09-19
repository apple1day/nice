package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"sync"
	"testing"
)

const testUploadID = "11111111-2222-4333-8444-555555555555"

func uploadRequest(name string, data []byte) *http.Request {
	r := httptest.NewRequest(http.MethodPost, "/api/upload-file?"+url.Values{"name": {name}}.Encode(), bytes.NewReader(data))
	r.Header.Set("Content-Type", "application/octet-stream")
	r.Header.Set("X-Nice-Upload-ID", testUploadID)
	r.Header.Set("X-Nice-Upload-Bytes", strconv.Itoa(len(data)))
	return r
}
func performUpload(h http.Handler, r *http.Request) *httptest.ResponseRecorder {
	w := httptest.NewRecorder()
	h.ServeHTTP(w, r)
	return w
}
func assertNoUploadParts(t *testing.T, root string) {
	t.Helper()
	parts, _ := filepath.Glob(filepath.Join(root, ".nice-upload-*.part"))
	if len(parts) != 0 {
		t.Fatalf("leaked partials: %v", parts)
	}
}
func TestNativeUploadRoundTripAndReceipt(t *testing.T) {
	root := t.TempDir()
	h := newNativeUploadHandler(root, 1024)
	name := "中文 a+b%#?.MP4"
	data := []byte{0, 1, 2, 3, 4, 5}
	w := performUpload(h, uploadRequest(name, data))
	if w.Code != 201 {
		t.Fatalf("%d: %s", w.Code, w.Body)
	}
	var receipt nativeUploadReceipt
	if err := json.Unmarshal(w.Body.Bytes(), &receipt); err != nil {
		t.Fatal(err)
	}
	if receipt.Name != name || receipt.Size != int64(len(data)) || receipt.UploadID != testUploadID || receipt.Version != 1 {
		t.Fatal(receipt)
	}
	stored, err := os.ReadFile(filepath.Join(root, name))
	if err != nil || !bytes.Equal(stored, data) {
		t.Fatal("wrong stored bytes", err)
	}
	assertNoUploadParts(t, root)
}
func TestNativeUploadNeverOverwrites(t *testing.T) {
	root := t.TempDir()
	h := newNativeUploadHandler(root, 1024)
	_ = os.WriteFile(filepath.Join(root, "a.mp4"), []byte("original"), 0600)
	w := performUpload(h, uploadRequest("a.mp4", []byte("new")))
	if w.Code != 409 {
		t.Fatal(w.Code)
	}
	data, _ := os.ReadFile(filepath.Join(root, "a.mp4"))
	if string(data) != "original" {
		t.Fatal("overwritten")
	}
	assertNoUploadParts(t, root)
}
func TestNativeUploadRejectsSymlinkAndDirectory(t *testing.T) {
	root := t.TempDir()
	outside := filepath.Join(t.TempDir(), "missing")
	_ = os.Symlink(outside, filepath.Join(root, "link.mp4"))
	_ = os.Mkdir(filepath.Join(root, "dir.mp4"), 0700)
	for _, name := range []string{"link.mp4", "dir.mp4"} {
		if w := performUpload(newNativeUploadHandler(root, 1024), uploadRequest(name, []byte("x"))); w.Code != 409 {
			t.Fatal(name, w.Code)
		}
	}
	if _, err := os.Stat(outside); !os.IsNotExist(err) {
		t.Fatal("followed symlink")
	}
}
func TestNativeUploadRejectsBadNames(t *testing.T) {
	for _, name := range []string{"", "../x.mp4", "a/b.mp4", `a\b.mp4`, ".hidden.mp4", "x.m3u8", "x.html", "x\n.mp4"} {
		root := t.TempDir()
		w := performUpload(newNativeUploadHandler(root, 1024), uploadRequest(name, []byte("x")))
		if w.Code != 400 {
			t.Fatal(name, w.Code)
		}
		entries, _ := os.ReadDir(root)
		if len(entries) != 0 {
			t.Fatal("created a file")
		}
	}
}
func TestNativeUploadLengthAndLimit(t *testing.T) {
	for _, tc := range []struct {
		size          string
		contentLength int64
		limit         int64
		status        int
	}{
		{"5", 3, 1024, 400}, {"5", -1, 1024, 400}, {"2", -1, 1024, 400},
		{"0", 3, 1024, 400}, {"3", 3, 2, 413}, {"bad", 3, 1024, 400},
	} {
		root := t.TempDir()
		r := uploadRequest("a.mp4", []byte("abc"))
		r.Header.Set("X-Nice-Upload-Bytes", tc.size)
		r.ContentLength = tc.contentLength
		w := performUpload(newNativeUploadHandler(root, tc.limit), r)
		if w.Code != tc.status {
			t.Fatalf("%+v: %d", tc, w.Code)
		}
		if _, err := os.Stat(filepath.Join(root, "a.mp4")); !os.IsNotExist(err) {
			t.Fatal("published incomplete")
		}
		assertNoUploadParts(t, root)
	}
}

type brokenUploadReader struct{}

func (brokenUploadReader) Read([]byte) (int, error) { return 0, errors.New("network interrupted") }
func TestNativeUploadInterruptedOrCancelled(t *testing.T) {
	root := t.TempDir()
	h := newNativeUploadHandler(root, 1024)
	r := uploadRequest("a.mp4", []byte("abc"))
	r.Body = io.NopCloser(brokenUploadReader{})
	if w := performUpload(h, r); w.Code != 400 {
		t.Fatal(w.Code)
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	r = uploadRequest("b.mp4", []byte("abc")).WithContext(ctx)
	if w := performUpload(h, r); w.Code != 400 {
		t.Fatal(w.Code)
	}
	entries, _ := os.ReadDir(root)
	if len(entries) != 0 {
		t.Fatal(entries)
	}
}
func TestNativeUploadConcurrentSameName(t *testing.T) {
	root := t.TempDir()
	h := newNativeUploadHandler(root, 1024)
	var wg sync.WaitGroup
	codes := make(chan int, 2)
	for _, body := range []string{"AAA", "BBB"} {
		wg.Add(1)
		go func(body string) {
			defer wg.Done()
			codes <- performUpload(h, uploadRequest("same.mp4", []byte(body))).Code
		}(body)
	}
	wg.Wait()
	close(codes)
	count := map[int]int{}
	for c := range codes {
		count[c]++
	}
	if count[201] != 1 || count[409] != 1 {
		t.Fatal(count)
	}
	data, _ := os.ReadFile(filepath.Join(root, "same.mp4"))
	if string(data) != "AAA" && string(data) != "BBB" {
		t.Fatal(string(data))
	}
	assertNoUploadParts(t, root)
}
func TestNativeUploadHeadAndLegacyRouter(t *testing.T) {
	root := t.TempDir()
	legacy := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(202) })
	h := withNativeUploads(legacy, root)
	r := httptest.NewRequest("HEAD", "/api/upload-file?name=a.mp4", nil)
	w := performUpload(h, r)
	if w.Code != 204 || w.Header().Get("X-Nice-Upload-Version") != "1" {
		t.Fatal(w.Code)
	}
	if w = performUpload(h, httptest.NewRequest("GET", "/api/videos", nil)); w.Code != 202 {
		t.Fatal("legacy changed")
	}
	if w = performUpload(h, httptest.NewRequest("DELETE", "/api/upload-file?name=a.mp4", nil)); w.Code != 405 {
		t.Fatal(w.Code)
	}
}
