"""Interaction wiring guards, not a replacement for physical iPhone touch tests."""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]

class PlayerDeleteButtonTests(unittest.TestCase):
    def setUp(self):
        self.player = re.sub(r'//[^\n]*', '', (ROOT/'NiceVideos/PlaybackScreen.swift').read_text())
        self.playlist = (ROOT/'NiceVideos/PlaylistPlaybackModel.swift').read_text()
        self.delete = self.player.split('private var transportDeleteButton:', 1)[1].split('private var playlistSheet:', 1)[0]
        self.favorite = self.player.split('private var transportFavoriteButton:', 1)[1].split('private var transportDeleteButton:', 1)[0]

    def test_mark_is_not_disabled_by_queued_or_scrub_state(self):
        self.assertIn('.disabled(!canInteract)', self.delete)
        self.assertNotIn('canNavigate', self.delete)
        self.assertNotIn('if !queued', self.delete)
        self.assertNotIn('.disabled(queued', self.delete)
        self.assertIn('.disabled(!canInteract)', self.favorite)

    def test_label_has_full_slot_hit_area_inside_button(self):
        for code in [self.delete, self.favorite]:
            label = code.split('} label: {', 1)[1].split('.disabled', 1)[0]
            self.assertIn('.frame(minWidth: 44, maxWidth: .infinity, minHeight: 52)', label)
            self.assertIn('.contentShape(Rectangle())', label)

    def test_success_failure_and_repeat_have_feedback(self):
        self.assertIn('Text(queued ? "待删除" : "删除")', self.delete)
        self.assertIn('success ? .success : .error', self.delete)
        for message in ['已加入待删除', '已在待删除列表', '未加入待删除']:
            self.assertIn(message, self.playlist)
        self.assertIn('playbackActionNotice', self.player)

    def test_press_protection_uses_native_button_not_drag_gesture(self):
        self.assertIn('configuration.isPressed', self.player)
        self.assertIn('controls.setControlPressed(token, pressed: pressed, at: now)', self.player)
        self.assertIn('onPressChanged(pressToken, false)', self.player)
        self.assertNotIn('DragGesture', self.player)
        self.assertNotIn('highPriorityGesture', self.player)

    def test_backdrop_tap_is_not_installed_on_controls_parent(self):
        self.assertIn('.background {', self.player)
        self.assertRegex(self.player, r'\.onTapGesture \{ revealControls\(\) \}\s*\}\s*\.buttonStyle')
        self.assertNotRegex(self.player, r'\.onTapGesture \{ revealControls\(\) \}\s*\.accessibilityIdentifier')

    def test_action_rejects_stale_request_and_never_deletes_files(self):
        self.assertIn('let displayedRequestID = request.id', self.delete)
        self.assertIn('expectedRequestID: displayedRequestID', self.delete)
        mark = self.playlist.split('func markCurrentForDeletion(', 1)[1].split('private func transition(', 1)[0]
        self.assertIn('current.id == expectedRequestID', mark)
        self.assertIn('store.markForDeletion(id)', mark)
        for forbidden in ['deleteAllPendingVideos', 'removeFromDevice', 'player.close()', 'engine.stop()', 'localPlaylistRecords']:
            self.assertNotIn(forbidden, mark)

if __name__ == '__main__':
    unittest.main()
