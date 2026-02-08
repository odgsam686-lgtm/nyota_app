import 'dart:io';
import 'package:video_thumbnail/video_thumbnail.dart';
import 'package:path_provider/path_provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../utils/storage_url.dart';

class VideoThumbnailService {
  /// 🎯 Génère + upload la miniature et retourne l’URL publique
  static Future<String?> generateAndUpload({
    required File videoFile,
    required String userId,
  }) async {
    try {
      // 1️⃣ Générer la miniature localement
      final tempDir = await getTemporaryDirectory();

      final thumbPath = await VideoThumbnail.thumbnailFile(
        video: videoFile.path,
        thumbnailPath: tempDir.path,
        imageFormat: ImageFormat.JPEG,
        maxHeight: 400,
        quality: 75,
      );

      if (thumbPath == null) return null;

      final thumbFile = File(thumbPath);

      // 2️⃣ Nom unique du fichier
      final fileName =
          'thumb_${userId}_${DateTime.now().millisecondsSinceEpoch}.jpg';

      // 3️⃣ Upload vers Supabase Storage
      final supabase = Supabase.instance.client;

      await supabase.storage
          .from('thumbnails') // ⚠️ bucket à créer
          .upload(fileName, thumbFile);

      // 4️⃣ Récupérer l’URL publique
      final url = storagePublicUrl('thumbnails', fileName);

      return url;
    } catch (e) {
      print("VideoThumbnailService error: $e");
      return null;
    }
  }
}
