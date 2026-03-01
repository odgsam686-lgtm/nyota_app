import 'dart:io';
import 'package:video_player/video_player.dart';
import 'storage_url.dart';
import '../services/crashlytics_logger.dart';

bool isLocalMediaPath(String raw) {
  if (raw.isEmpty) return false;
  return File(raw).existsSync();
}

String resolveMediaUrl(String raw) {
  if (raw.isEmpty) return raw;
  if (raw.startsWith('http://') || raw.startsWith('https://')) return raw;
  return storagePublicUrl('posts', raw);
}

String? _pickVariantPath(
  Map<String, dynamic> variants,
  List<String> preferredKeys,
) {
  for (final key in preferredKeys) {
    final value = variants[key];
    if (value is String && value.isNotEmpty) return value;
  }
  return null;
}

Future<String> resolveBestVideoUrl({
  required String mediaPath,
  Map<String, dynamic>? variants,
}) async {
  try {
    if (mediaPath.isEmpty) return mediaPath;
    if (isLocalMediaPath(mediaPath)) return mediaPath;

    if (variants == null || variants.isEmpty) {
      CrashlyticsLogger.log('video_resolver:no_variants path=$mediaPath');
      return resolveMediaUrl(mediaPath);
    }

    // Cost policy: always serve 720p when available.
    final chosen = _pickVariantPath(variants, const ['720', '360', '1080']);
    final resolved = resolveMediaUrl(chosen ?? mediaPath);
    CrashlyticsLogger.log(
        'video_resolver:resolved path=$mediaPath chosen=${chosen ?? mediaPath}');
    return resolved;
  } catch (e, s) {
    await CrashlyticsLogger.recordNonFatal(
      e,
      s,
      reason: 'video_resolver',
    );
    return resolveMediaUrl(mediaPath);
  }
}

VideoPlayerController createVideoController(String raw) {
  if (isLocalMediaPath(raw)) {
    return VideoPlayerController.file(File(raw));
  }
  return VideoPlayerController.network(resolveMediaUrl(raw));
}
