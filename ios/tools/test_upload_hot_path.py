"""Upload integration guards; complements Swift/Go tests, not a device test."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]

class UploadHotPathTests(unittest.TestCase):
    def test_upload_uses_file_task_and_separate_progress(self):
        text = (ROOT / 'NiceVideos/LocalUploadManager.swift').read_text()
        self.assertIn('session.uploadTask(with: request, fromFile: file)', text)
        self.assertIn('guard activeTask == nil', text)
        self.assertNotIn('Data(contentsOf:', text)
        self.assertNotIn('store.progress', text)
        self.assertIn('completionHandler(nil)', text)
        self.assertIn('LocalUploadWire.validateReceipt', text)

    def test_picker_reads_metadata_without_library_scan(self):
        text = (ROOT / 'NiceVideos/LocalUploadViews.swift').read_text()
        for forbidden in ('FileManager', 'verifiedFile', 'localPlaybackRequest', 'reconcileFiles'):
            self.assertNotIn(forbidden, text)
        self.assertIn('library.visibleRows', text)
        self.assertIn('row.record.taskToken', text)
        self.assertIn('确认上传到服务器', text)

    def test_backend_route_is_connected_without_changing_legacy_upload(self):
        main = (ROOT.parent / 'videos/main.go').read_text()
        self.assertIn('withNativeUploads(mux, videoDir)', main)
        self.assertIn('mux.HandleFunc("/api/upload", uploadVideo)', main)
        native = (ROOT.parent / 'videos/native_upload.go').read_text()
        self.assertIn('os.Link(temp.Name(), target)', native)
        self.assertIn('http.MaxBytesReader', native)
        self.assertIn('http.StatusCreated', native)

if __name__ == '__main__':
    unittest.main()
