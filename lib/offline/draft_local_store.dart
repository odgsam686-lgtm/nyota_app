// lib/offline/draft_local_store.dart
import 'dart:io';
import 'package:flutter/foundation.dart';
import '../hive_helper.dart';
import '../models/draft_local_model.dart';
import 'draft_state.dart';

/// Offline-only local repository for DraftLocalModel.
/// Hive-backed CRUD only (no business logic, no network).
class DraftLocalStore {
  static final ValueNotifier<int> changes = ValueNotifier<int>(0);

  static void _notifyChanges() {
    changes.value = changes.value + 1;
  }

  List<DraftLocalModel> getAll() {
    final box = HiveHelper.draftsBox;
    return box.values
        .map((e) => DraftLocalModel.fromMap(Map<String, dynamic>.from(e)))
        .toList();
  }

  DraftLocalModel? getById(String id) {
    final box = HiveHelper.draftsBox;
    final raw = box.get(id);
    if (raw == null) return null;
    return DraftLocalModel.fromMap(Map<String, dynamic>.from(raw));
  }

  List<DraftLocalModel> getByStates(List<DraftState> states) {
    final items = getAll()
        .where((d) => states.contains(d.state))
        .toList();
    items.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    return items;
  }

  void upsert(DraftLocalModel draft) {
    final box = HiveHelper.draftsBox;
    box.put(draft.id, draft.toMap());
    _notifyChanges();
  }

  void deleteById(String id) {
    final box = HiveHelper.draftsBox;
    box.delete(id);
    _notifyChanges();
  }

  void deleteWithFiles(DraftLocalModel draft) {
    final box = HiveHelper.draftsBox;
    box.delete(draft.id);

    final mediaFile = File(draft.mediaLocalPath);
    if (mediaFile.existsSync()) {
      mediaFile.deleteSync();
    }

    final thumbPath = draft.thumbnailLocalPath;
    if (thumbPath != null && thumbPath.isNotEmpty) {
      final thumbFile = File(thumbPath);
      if (thumbFile.existsSync()) {
        thumbFile.deleteSync();
      }
    }
    _notifyChanges();
  }

  void clear() {
    final box = HiveHelper.draftsBox;
    box.clear();
    _notifyChanges();
  }
}
