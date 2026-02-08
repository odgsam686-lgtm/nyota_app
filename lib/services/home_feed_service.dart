import 'package:supabase_flutter/supabase_flutter.dart';

class HomeFeedService {
  final SupabaseClient supabase = Supabase.instance.client;

  Future<List<Map<String, dynamic>>> fetchFeed() async {
    final res = await supabase
        .from('posts')
        .select()
        .order('created_at', ascending: false)
        .limit(50); // ⚠️ limite pour fluidité

    return List<Map<String, dynamic>>.from(res);
  }
}
