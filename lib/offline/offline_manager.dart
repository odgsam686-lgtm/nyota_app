// lib/offline/offline_manager.dart
import '../services/draft_publish_service.dart';
import 'draft_local_store.dart';
import 'draft_state.dart';
import '../models/draft_local_model.dart';

/// Local-only draft orchestration (no UI, no storage, no network).
class DraftOfflineManager {
  /// Attempts to move from [current] to [next], enforcing allowed transitions.
  static DraftState transition({
    required DraftState current,
    required DraftState next,
  }) {
    if (!DraftStateMachine.canTransition(current, next)) {
      return current;
    }
    return next;
  }

  /// Returns a safe state after a crash or app restart.
  /// Normalization rules:
  /// - uploading -> queued
  /// - publishPending -> queued
  /// - other states unchanged
  /// This does not persist anything; caller is responsible for storing it.
  static DraftState normalizeAfterCrash(DraftState state) {
    switch (state) {
      case DraftState.uploading:
      case DraftState.publishPending:
        return DraftState.queued;
      case DraftState.localOnly:
      case DraftState.queued:
      case DraftState.uploaded:
      case DraftState.published:
      case DraftState.deletePending:
      case DraftState.failed:
        return state;
    }
  }

  /// Normalizes drafts after crash and persists changes.
  static void normalizeDraftsOnStartup() {
    final store = DraftLocalStore();
    final drafts = store.getAll();
    for (final d in drafts) {
      final normalized = normalizeAfterCrash(d.state);
      if (normalized != d.state &&
          DraftStateMachine.canTransition(d.state, normalized)) {
        store.upsert(d.copyWith(state: normalized));
      }
    }
  }

  /// Publishes a draft and updates local state.
  static Future<DraftPublishResult> publishDraft({
    required DraftLocalModel draft,
    DraftLocalStore? store,
  }) async {
    final localStore = store ?? DraftLocalStore();
    final queued = _persistTransition(
      draft: draft,
      next: DraftState.queued,
      store: localStore,
    );
    final uploading = _persistTransition(
      draft: queued,
      next: DraftState.uploading,
      store: localStore,
    );

    DraftPublishResult result;
    try {
      result = await DraftPublishService.publishDraft(uploading);
    } catch (e) {
      result = DraftPublishResult(success: false, errorMessage: e.toString());
    }

    if (result.success) {
      final uploaded = _persistTransition(
        draft: uploading,
        next: DraftState.uploaded,
        store: localStore,
      );
      final pending = _persistTransition(
        draft: uploaded,
        next: DraftState.publishPending,
        store: localStore,
      );
      _persistTransition(
        draft: pending,
        next: DraftState.published,
        store: localStore,
      );
    } else {
      _persistTransition(
        draft: uploading,
        next: DraftState.failed,
        store: localStore,
      );
    }

    return result;
  }

  static DraftLocalModel _persistTransition({
    required DraftLocalModel draft,
    required DraftState next,
    required DraftLocalStore store,
  }) {
    if (!DraftStateMachine.canTransition(draft.state, next)) {
      return draft;
    }
    final updated = draft.copyWith(state: next, updatedAt: DateTime.now());
    store.upsert(updated);
    return updated;
  }

  /// Publishes all queued/failed drafts sequentially (single pass).
  static Future<void> flushQueuedDrafts() async {
    final store = DraftLocalStore();
    final drafts = store.getAll()
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));

    for (final d in drafts) {
      if (d.state == DraftState.queued || d.state == DraftState.failed) {
        await publishDraft(draft: d, store: store);
      }
    }
  }

  /// Applies a failure event and returns the next state plus retry count.
  static DraftRetryResult fail({
    required DraftState current,
    required int retryCount,
    String? errorMessage,
  }) {
    final next = DraftStateMachine.canTransition(current, DraftState.failed)
        ? DraftState.failed
        : current;
    return DraftRetryResult(
      state: next,
      retryCount: retryCount + 1,
      errorMessage: errorMessage,
    );
  }

  /// Resets a failed draft back to queued for a manual retry.
  static DraftRetryResult retry({
    required DraftState current,
    required int retryCount,
  }) {
    final next = DraftStateMachine.canTransition(current, DraftState.queued)
        ? DraftState.queued
        : current;
    return DraftRetryResult(state: next, retryCount: retryCount);
  }
}

/// Lightweight retry info for local orchestration.
class DraftRetryResult {
  final DraftState state;
  final int retryCount;
  final String? errorMessage;

  DraftRetryResult({
    required this.state,
    required this.retryCount,
    this.errorMessage,
  });
}
