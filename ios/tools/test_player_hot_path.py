"""Source-level guards for player hot paths. Not a substitute for iOS XCTest."""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]


def source(name: str) -> str:
    text = (ROOT / "NiceVideos" / name).read_text(encoding="utf-8")
    return re.sub(r"//[^\n]*", "", text)


class PlayerHotPathTests(unittest.TestCase):
    def setUp(self) -> None:
        self.player = source("PlaybackScreen.swift")
        self.playlist = source("PlaylistPlaybackModel.swift")

    def test_player_has_no_vertical_paging_or_deferred_switch(self) -> None:
        for symbol in ("DragGesture", "GestureState", "pagingPreview", "pageAnimating", "asyncAfter"):
            self.assertNotIn(symbol, self.player)
        self.assertIn(".onTapGesture { toggleControls() }", self.player)

    def test_playlist_does_not_call_full_library_file_checks(self) -> None:
        for symbol in ("localPlaylistRecords", "verifiedFile", "reconcileFiles", "FileManager",
                       "attributesOfItem", "Data(contentsOf", "validateLocalFile"):
            self.assertNotIn(symbol, self.playlist)

    def test_neighbor_button_reads_only_cached_metadata(self) -> None:
        body = self.playlist.split("func neighbor(", 1)[1].split("func canMove(", 1)[0]
        self.assertIn("neighbors[direction]", body)
        for symbol in ("store.", ".map", ".filter", "resolveRequest", "candidates("):
            self.assertNotIn(symbol, body)

    def test_progress_drag_state_is_isolated(self) -> None:
        progress = self.player.split("private struct PlaybackProgressView:", 1)[1].split("struct PlaybackScreen:", 1)[0]
        parent = self.player.split("private struct PlaylistPlayerView:", 1)[1]
        self.assertIn("@State private var draftSeconds", progress)
        self.assertNotIn("draftSeconds", parent)
        self.assertNotIn("store.", progress)
        self.assertNotIn("playlist.", progress)
        self.assertIn("set: { draftSeconds = $0 }", progress)
        self.assertIn("if !editing", progress)
        self.assertIn("model.seek(to: target)", progress)

    def test_seek_keeps_same_engine_without_file_checks(self) -> None:
        seek = self.player.split("func seek(to value:", 1)[1].split("private func receive", 1)[0]
        self.assertIn("engine.seek(to: value)", seek)
        for symbol in ("store.", "playlist.", "load(", "stop(", "FileManager", "validate"):
            self.assertNotIn(symbol, seek)

    def test_portrait_and_landscape_keep_navigation_buttons(self) -> None:
        for direction in ("previous", "next"):
            for compact in ("false", "true"):
                self.assertIn(f"navigationButton(.{direction}, compact: {compact})", self.player)
        self.assertIn('"previousVideoButton"', self.player)
        self.assertIn('"nextVideoButton"', self.player)

    def test_favorite_and_pending_badges_do_not_scan_records(self) -> None:
        self.assertIn("playlist.currentEntry?.isFavorite", self.player)
        self.assertIn("playlist.currentEntry?.pendingDeletionOrder", self.player)
        self.assertNotIn("store.isFavorite(", self.player)
        self.assertNotIn("store.isPendingDeletion(", self.player)

    def test_target_validation_and_deletion_lease_are_preserved(self) -> None:
        self.assertIn("try store.localPlaybackRequest(for: $0)", self.playlist)
        self.assertIn("try store.transitionPlayback(from: current, to: next) { player.close() }", self.playlist)

    def test_metadata_cache_tracks_record_changes_not_playback_ticks(self) -> None:
        self.assertIn("store.$records.removeDuplicates().sink", self.playlist)
        self.assertIn("self?.updateMetadata(records)", self.playlist)
        self.assertIn("recordSubscription?.cancel()", self.playlist)
        self.assertNotIn("$seconds", self.playlist)
        self.assertNotIn("$progress", self.playlist)


if __name__ == "__main__":
    unittest.main()
