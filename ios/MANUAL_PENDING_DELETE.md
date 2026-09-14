# v1.3 player navigation and manual pending deletion

This update changes two user-facing behaviors while preserving the existing local media files and manifest format.

## Player controls

Portrait keeps the existing compact control row. In landscape, the transport controls are ordered as:

`Previous video → Back 15s → Play/Pause → Delete → Forward 15s → Next video → Fullscreen`

The Previous/Next buttons reuse the same local playlist navigation as vertical swipe gestures. Reaching the first or last local item keeps the current video playing and shows the existing boundary notice.

## Pending deletion

The player Delete button now only adds the current local video to the persisted pending-deletion list. It never deletes a file immediately.

- There is no pending-deletion item limit.
- Adding the fourth or any later item never evicts/deletes an older item.
- The player Delete button becomes disabled with a checkmark after the current video is already queued.
- Removing a pending mark is done from the pending list rather than by toggling the player Delete button.
- Actual file deletion only happens after tapping the one-click delete action at the top of the local list and confirming.
- The confirmation uses a snapshot of the pending IDs, so videos queued after the dialog opens are not unexpectedly deleted.
- A video still being played is retained and remains pending until playback closes and deletion is retried.

No backend API, Bundle Identifier, downloaded file naming, or manifest version changes are required.
