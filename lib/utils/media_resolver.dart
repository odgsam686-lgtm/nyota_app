import 'dart:io';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:video_player/video_player.dart';
import 'storage_url.dart';

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
  if (mediaPath.isEmpty) return mediaPath;
  if (isLocalMediaPath(mediaPath)) return mediaPath;

  if (variants == null || variants.isEmpty) {
    return resolveMediaUrl(mediaPath);
  }

  final connectivity = await Connectivity().checkConnectivity();
  List<String> preference;
  switch (connectivity) {
    case ConnectivityResult.wifi:
    case ConnectivityResult.ethernet:
    case ConnectivityResult.vpn:
      preference = const ['1080', '720', '360'];
      break;
    case ConnectivityResult.mobile:
      preference = const ['360', '720', '1080'];
      break;
    case ConnectivityResult.bluetooth:
    case ConnectivityResult.other:
      preference = const ['720', '360', '1080'];
      break;
    case ConnectivityResult.none:
      return resolveMediaUrl(mediaPath);
  }

  final chosen = _pickVariantPath(variants, preference);
  return resolveMediaUrl(chosen ?? mediaPath);
}

VideoPlayerController createVideoController(String raw) {
  if (isLocalMediaPath(raw)) {
    return VideoPlayerController.file(File(raw));
  }
  return VideoPlayerController.network(resolveMediaUrl(raw));
}
