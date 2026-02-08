import 'package:supabase_flutter/supabase_flutter.dart';

String storagePublicUrl(String bucket, String objectPath) {
  final p = objectPath.startsWith('/') ? objectPath.substring(1) : objectPath;

  final doublePrefix = '$bucket/$bucket/';
  final cleanPath = p.startsWith(doublePrefix)
      ? p.substring(bucket.length + 1)
      : p;

  return Supabase.instance.client.storage
      .from(bucket)
      .getPublicUrl(cleanPath);
}
