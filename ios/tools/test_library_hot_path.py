"""Source guards supplement (not replace) real Swift/XCTest and device profiling."""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1] / "NiceVideos"

def source(name):
    return re.sub(r"//[^\n]*", "", (ROOT / name).read_text(encoding="utf-8"))

class LibraryHotPathTests(unittest.TestCase):
    def test_active_root_has_no_foreground_scan_or_progress_subscription(self):
        app = source("NiceVideosApp.swift")
        self.assertIn("LibraryRootView(store: store)", app)
        self.assertNotIn("@StateObject private var store", app)
        root = source("LibraryRootView.swift")
        self.assertNotIn("reconcileFiles", root)
        self.assertNotIn("$progress", root)

    def test_list_model_only_observes_metadata(self):
        model = source("LocalLibraryModel.swift")
        self.assertIn("store.$records.removeDuplicates()", model)
        for symbol in ("$progress", "FileManager", "verifiedFile", "Data(contentsOf", "reconcileFiles"):
            self.assertNotIn(symbol, model)

    def test_rows_do_not_search_store_or_reformat_size(self):
        ui = source("BatchDeletionViews.swift").split("struct TransfersView:")[0]
        for symbol in ("store.isPendingDeletion", "store.completed", "ByteCountFormatter", ".sizeLabel", "PendingDeletionSection()"):
            self.assertNotIn(symbol, ui)
        self.assertIn("LocalVideoRowLabel", ui)
        self.assertIn(".equatable()", ui)
        self.assertIn('"已观看"', ui)
        self.assertIn('"未观看"', ui)

    def test_toolbar_placement_and_snapshot_confirmation(self):
        ui = source("BatchDeletionViews.swift").split("struct TransfersView:")[0]
        toolbar = ui.split(".toolbar {", 1)[1].split(".safeAreaInset", 1)[0]
        self.assertLess(toolbar.index("PendingDeleteToolbarButton"), toolbar.index('Button("选择")'))
        self.assertIn('Button("删除待删除", role: .destructive)', ui)
        self.assertIn("confirmed = records", ui)
        self.assertIn("store.deletePendingVideos(snapshot)", ui)

    def test_completion_and_watch_metadata_are_optional(self):
        core = source("Core.swift")
        self.assertIn("var downloadedAt: Date?", core)
        self.assertIn("var watched: Bool?", core)
        store = source("VideoStore.swift")
        finish = store.split("didFinishDownloadingTo location:")[1].split("didCompleteWithError")[0]
        self.assertIn("downloadedAt = Date()", finish)
        self.assertIn("reconcileFiles(ids: Set(unfinishedCache.map", store)

    def test_player_order_matches_library_and_watch_gate_requires_video(self):
        self.assertIn("LocalLibraryOrder.newestFirst", source("PlaylistPlaybackModel.swift"))
        gate = source("LibraryPolicies.swift")
        self.assertIn("allowed, isPlaying, hasVideo", gate)
        watcher = source("WatchedPlaybackEngine.swift")
        self.assertIn("snapshot.hasVideo", watcher)
        self.assertIn("self.allowed && !self.stopped", watcher)

if __name__ == "__main__":
    unittest.main()
