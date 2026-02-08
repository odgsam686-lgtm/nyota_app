// Local-only draft state machine definitions (no storage, no UI, no network).

/// Explicit states for a draft lifecycle (offline-first).
enum DraftState {
  /// Draft exists only on device. No upload attempted.
  localOnly,

  /// Draft is ready to be uploaded when sync is enabled.
  queued,

  /// Draft is currently uploading (reserved for future sync).
  uploading,

  /// Draft media and metadata are fully uploaded.
  uploaded,

  /// Publish requested, waiting for completion.
  publishPending,

  /// Draft has been published successfully.
  published,

  /// Deletion requested, waiting for completion.
  deletePending,

  /// Draft is in a failed state and needs manual retry.
  failed,
}

/// Allowed transitions for the local state machine.
class DraftStateMachine {
  /// Returns true if [from] can transition to [to].
  static bool canTransition(DraftState from, DraftState to) {
    if (from == to) return true;

    switch (from) {
      case DraftState.localOnly:
        return to == DraftState.queued ||
            to == DraftState.deletePending ||
            to == DraftState.failed;
      case DraftState.queued:
        return to == DraftState.uploading ||
            to == DraftState.deletePending ||
            to == DraftState.failed;
      case DraftState.uploading:
        return to == DraftState.uploaded ||
            to == DraftState.failed ||
            to == DraftState.deletePending;
      case DraftState.uploaded:
        return to == DraftState.publishPending ||
            to == DraftState.deletePending ||
            to == DraftState.failed;
      case DraftState.publishPending:
        return to == DraftState.published || to == DraftState.failed;
      case DraftState.published:
        return false;
      case DraftState.deletePending:
        return false;
      case DraftState.failed:
        return to == DraftState.queued ||
            to == DraftState.deletePending ||
            to == DraftState.failed;
    }
  }
}
