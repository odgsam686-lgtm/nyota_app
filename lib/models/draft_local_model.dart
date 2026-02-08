// lib/models/draft_local_model.dart
import '../offline/draft_state.dart';

/// Offline-only draft model (no persistence, no network).
class DraftLocalModel {
  final String id;
  final String userId;
  final String mediaLocalPath;
  final String? thumbnailLocalPath;
  final bool isVideo;
  final String description;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DraftState state;
  final int retryCount;
  final String? errorMessage;

  /// Optional local-only metadata (duration, size, width, height, mime).
  final Map<String, dynamic> metadata;

  const DraftLocalModel({
    required this.id,
    required this.userId,
    required this.mediaLocalPath,
    required this.isVideo,
    required this.description,
    required this.createdAt,
    required this.updatedAt,
    required this.state,
    this.thumbnailLocalPath,
    this.retryCount = 0,
    this.errorMessage,
    this.metadata = const {},
  });

  DraftLocalModel copyWith({
    String? id,
    String? userId,
    String? mediaLocalPath,
    String? thumbnailLocalPath,
    bool? isVideo,
    String? description,
    DateTime? createdAt,
    DateTime? updatedAt,
    DraftState? state,
    int? retryCount,
    String? errorMessage,
    Map<String, dynamic>? metadata,
  }) {
    return DraftLocalModel(
      id: id ?? this.id,
      userId: userId ?? this.userId,
      mediaLocalPath: mediaLocalPath ?? this.mediaLocalPath,
      thumbnailLocalPath: thumbnailLocalPath ?? this.thumbnailLocalPath,
      isVideo: isVideo ?? this.isVideo,
      description: description ?? this.description,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      state: state ?? this.state,
      retryCount: retryCount ?? this.retryCount,
      errorMessage: errorMessage ?? this.errorMessage,
      metadata: metadata ?? this.metadata,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'user_id': userId,
      'media_local_path': mediaLocalPath,
      'thumbnail_local_path': thumbnailLocalPath,
      'is_video': isVideo,
      'description': description,
      'created_at': createdAt.toIso8601String(),
      'updated_at': updatedAt.toIso8601String(),
      'state': state.name,
      'retry_count': retryCount,
      'error_message': errorMessage,
      'metadata': metadata,
    };
  }

  factory DraftLocalModel.fromMap(Map<String, dynamic> map) {
    final stateName = map['state']?.toString();
    final parsedState = DraftState.values.firstWhere(
      (s) => s.name == stateName,
      orElse: () => DraftState.localOnly,
    );

    return DraftLocalModel(
      id: map['id']?.toString() ?? '',
      userId: map['user_id']?.toString() ?? '',
      mediaLocalPath: map['media_local_path']?.toString() ?? '',
      thumbnailLocalPath: map['thumbnail_local_path']?.toString(),
      isVideo: map['is_video'] == true,
      description: map['description']?.toString() ?? '',
      createdAt: DateTime.tryParse(map['created_at']?.toString() ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
      updatedAt: DateTime.tryParse(map['updated_at']?.toString() ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
      state: parsedState,
      retryCount: map['retry_count'] is int ? map['retry_count'] as int : 0,
      errorMessage: map['error_message']?.toString(),
      metadata: map['metadata'] is Map
          ? Map<String, dynamic>.from(map['metadata'] as Map)
          : const {},
    );
  }
}
