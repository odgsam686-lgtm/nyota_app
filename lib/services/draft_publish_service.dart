// lib/services/draft_publish_service.dart
import 'dart:io';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:flutter/foundation.dart';
import '../models/draft_local_model.dart';
import 'media_upload_service.dart';

/// Result of a draft publish attempt.
class DraftPublishResult {
  final bool success;
  final String? postId;
  final String? errorMessage;

  DraftPublishResult({
    required this.success,
    this.postId,
    this.errorMessage,
  });
}

/// Publishes a local draft to Supabase (no UI, no Hive).
class DraftPublishService {
  static Future<void> _copyUserLocationToPostLocation({
    required SupabaseClient supabase,
    required String firebaseUid,
    required String postId,
  }) async {
    try {
      final row = await supabase
          .from('user_locations')
          .select('latitude, longitude, zone')
          .eq('user_id', firebaseUid)
          .maybeSingle();

      if (row == null) {
        debugPrint(
            'DraftPublishService post_locations skipped: no user_locations for user=$firebaseUid');
        return;
      }

      double? toDouble(dynamic value) {
        if (value is double) return value;
        if (value is num) return value.toDouble();
        return double.tryParse(value?.toString() ?? '');
      }

      final latitude = toDouble(row['latitude']);
      final longitude = toDouble(row['longitude']);
      final zone = row['zone']?.toString();

      if (latitude == null || longitude == null) {
        debugPrint(
            'DraftPublishService post_locations skipped: invalid coordinates user=$firebaseUid row=$row');
        return;
      }

      final payload = <String, dynamic>{
        'post_id': postId,
        'latitude': latitude,
        'longitude': longitude,
      };
      if (zone != null && zone.trim().isNotEmpty) {
        payload['zone'] = zone.trim();
      }

      await supabase.from('post_locations').upsert(
            payload,
            onConflict: 'post_id',
          );

      debugPrint(
          'DraftPublishService post_locations upsert post=$postId lat=$latitude lng=$longitude zone=${payload['zone']}');
    } catch (e) {
      debugPrint(
          'DraftPublishService post_locations error post=$postId user=$firebaseUid error=$e');
    }
  }

  /// Uploads media/thumbnail and inserts a post.
  static Future<DraftPublishResult> publishDraft(
    DraftLocalModel draft,
  ) async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) {
        return DraftPublishResult(
          success: false,
          errorMessage: 'User not authenticated',
        );
      }

      final mediaFile = File(draft.mediaLocalPath);
      if (!mediaFile.existsSync()) {
        return DraftPublishResult(
          success: false,
          errorMessage: 'Media file not found locally',
        );
      }

      final supabase = Supabase.instance.client;

      // Upload media (and thumbnail if supported by the service)
      final mediaResult = await MediaUploadService.uploadMedia(
        file: mediaFile,
        isVideo: draft.isVideo,
        userId: user.uid,
        thumbnailFilePath: draft.thumbnailLocalPath,
      );

      final mediaPath = mediaResult['media_path']?.toString();
      final thumbnailPath = mediaResult['thumbnail_path']?.toString();

      if (mediaPath == null || mediaPath.isEmpty) {
        return DraftPublishResult(
          success: false,
          errorMessage: 'Upload failed: missing media_path',
        );
      }

      Map<String, String>? videoVariants;
      if (draft.isVideo) {
        final lastSlash = mediaPath.lastIndexOf('/');
        final baseDir = lastSlash == -1 ? mediaPath : mediaPath.substring(0, lastSlash);
        final variantsDir = '$baseDir/variants';
        videoVariants = {
          '360': '$variantsDir/360p.mp4',
          '720': '$variantsDir/720p.mp4',
          '1080': '$variantsDir/1080p.mp4',
        };
      }

      final payload = <String, dynamic>{
        'seller_id': user.uid,
        'media_path': mediaPath,
        // media_url is NOT NULL in posts; we store the storage path here.
        'media_url': mediaPath,
        'media_type': draft.isVideo ? 'video' : 'image',
        'is_video': draft.isVideo,
        'description': draft.description,
        'likes': 0,
      };
      if (thumbnailPath != null && thumbnailPath.isNotEmpty) {
        payload['thumbnail_path'] = thumbnailPath;
      }
      if (videoVariants != null) {
        payload['video_variants'] = videoVariants;
      }

      debugPrint("DB insert posts payload=$payload");
      final insert =
          await supabase.from('posts').insert(payload).select().single();

      final postId = insert['id']?.toString();
      if (postId != null && postId.isNotEmpty) {
        await _copyUserLocationToPostLocation(
          supabase: supabase,
          firebaseUid: user.uid,
          postId: postId,
        );
      }

      return DraftPublishResult(success: true, postId: postId);
    } catch (e) {
      return DraftPublishResult(
        success: false,
        errorMessage: e.toString(),
      );
    }
  }
}
