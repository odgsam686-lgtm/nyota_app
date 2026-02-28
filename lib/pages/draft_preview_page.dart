import 'dart:io';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:video_player/video_player.dart';
import '../models/post_model.dart';
import '../utils/media_resolver.dart';

class DraftPreviewPage extends StatefulWidget {
  final PostModel draft;

  const DraftPreviewPage({super.key, required this.draft});

  @override
  State<DraftPreviewPage> createState() => _DraftPreviewPageState();
}

class _DraftPreviewPageState extends State<DraftPreviewPage> {
  bool _loading = false;
  VideoPlayerController? _controller;
  bool _isPlaying = true;

  @override
  void initState() {
    super.initState();

    if (widget.draft.isVideo) {
      dynamic rawVariants;
      try {
        rawVariants = (widget.draft as dynamic).videoVariants;
      } catch (_) {}
      final Map<String, dynamic>? variants =
          rawVariants is Map ? Map<String, dynamic>.from(rawVariants) : null;
      _initVideoController(widget.draft.mediaUrl, variants);
    }
  }

  Future<void> _initVideoController(
    String mediaPath,
    Map<String, dynamic>? variants,
  ) async {
    final resolvedUrl = await resolveBestVideoUrl(
      mediaPath: mediaPath,
      variants: variants,
    );

    final controller = createVideoController(resolvedUrl);
    _controller = controller;

    await controller.initialize();

    if (!mounted) return;

    // Forcer la première frame
    await controller.play();
    await Future.delayed(const Duration(milliseconds: 300));
    await controller.pause();
    await controller.seekTo(Duration.zero);

    setState(() {});
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  // ✅ TAP PLAY / PAUSE
  void _togglePlay() {
    if (_controller == null) return;

    setState(() {
      if (_controller!.value.isPlaying) {
        _controller!.pause();
        _isPlaying = false;
      } else {
        _controller!.play();
        _isPlaying = true;
      }
    });
  }

  // ✅ CONFIRMATION AVANT SUPPRESSION
  Future<void> _confirmDelete() async {
    final confirm = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        return AlertDialog(
          title: const Text("Confirmation"),
          content: const Text(
            "Voulez-vous vraiment supprimer ce brouillon ? Cette action est irréversible.",
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text("Annuler"),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
              onPressed: () => Navigator.pop(context, true),
              child: const Text("Supprimer"),
            ),
          ],
        );
      },
    );

    if (confirm == true) {
      _deleteDraft();
    }
  }

  // ✅ PUBLIER LE BROUILLON
  Future<void> _publishDraft() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    setState(() => _loading = true);

    try {
      final postInsert = await Supabase.instance.client.from('posts').insert({
        "seller_id": user.uid,
        "seller_name": user.email ?? "vendeur",
        "description": widget.draft.description,
        "media_url": widget.draft.mediaUrl,
        "is_video": widget.draft.isVideo,
        "created_at": DateTime.now().toIso8601String(),
        "likes": 0,
      }).select('id').single();

      final postId = postInsert['id']?.toString();
      debugPrint("draft publish post insert ok post_id=$postId");
      if (postId != null && postId.isNotEmpty) {
        await _copyUserLocationToPostLocation(
          firebaseUid: user.uid,
          postId: postId,
        );
      }

      await Supabase.instance.client
          .from('drafts')
          .delete()
          .eq('id', widget.draft.id);

      setState(() => _loading = false);

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("✅ Brouillon publié avec succès")),
      );

      Navigator.pop(context, true);
    } catch (e) {
      setState(() => _loading = false);
      debugPrint("❌ publishDraft error: $e");
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Erreur lors de la publication")),
      );
    }
  }

  Future<void> _copyUserLocationToPostLocation({
    required String firebaseUid,
    required String postId,
  }) async {
    try {
      final supabase = Supabase.instance.client;
      final row = await supabase
          .from('user_locations')
          .select('latitude, longitude, zone')
          .eq('user_id', firebaseUid)
          .maybeSingle();

      if (row == null) {
        debugPrint(
            'draft post_locations skipped: no user_locations for user=$firebaseUid');
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
            'draft post_locations skipped: invalid coordinates user=$firebaseUid row=$row');
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
          'draft post_locations upsert post=$postId lat=$latitude lng=$longitude zone=${payload['zone']}');
    } catch (e) {
      debugPrint('draft post_locations error post=$postId user=$firebaseUid $e');
    }
  }

  // ✅ SUPPRESSION RÉELLE DU BROUILLON
  Future<void> _deleteDraft() async {
    setState(() => _loading = true);

    try {
      await Supabase.instance.client
          .from('drafts')
          .delete()
          .eq('id', widget.draft.id);

      setState(() => _loading = false);

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("🗑 Brouillon supprimé")),
      );

      Navigator.pop(context, true);
    } catch (e) {
      setState(() => _loading = false);
      debugPrint("❌ deleteDraft error: $e");
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Erreur suppression")),
      );
    }
  }

  // ✅ UI
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,

      appBar: AppBar(
        backgroundColor: Colors.black,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white),
          onPressed: () => Navigator.pop(context, false),
        ),
        title: const Text("Brouillon"),
        actions: [
          TextButton(
            onPressed: _loading ? null : _publishDraft,
            child: _loading
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white),
                  )
                : const Text(
                    "Publier",
                    style:
                        TextStyle(color: Colors.greenAccent, fontSize: 16),
                  ),
          ),
        ],
      ),

      body: Column(
        children: [
          const SizedBox(height: 12),

          // ✅ PREVIEW MEDIA AVEC VIDEO TIKTOK STYLE
          Expanded(
            child: Center(
              child: widget.draft.isVideo
                  ? _controller != null && _controller!.value.isInitialized
                      ? GestureDetector(
                          onTap: _togglePlay,
                          child: Stack(
                            alignment: Alignment.center,
                            children: [
                              AspectRatio(
                                aspectRatio:
                                    _controller!.value.aspectRatio,
                                child: VideoPlayer(_controller!),
                              ),

                              if (!_controller!.value.isPlaying)
                                const Icon(
                                  Icons.play_circle_fill,
                                  color: Colors.white,
                                  size: 80,
                                ),

                              Positioned(
                                bottom: 20,
                                left: 20,
                                right: 20,
                                child: VideoProgressIndicator(
                                  _controller!,
                                  allowScrubbing: true,
                                  colors: const VideoProgressColors(
                                    playedColor: Colors.white,
                                    backgroundColor: Colors.grey,
                                    bufferedColor: Colors.grey,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        )
                      : const CircularProgressIndicator(color: Colors.white)
                  : ClipRRect(
                      borderRadius: BorderRadius.circular(16),
                        child: isLocalMediaPath(widget.draft.mediaUrl)
                            ? Image.file(
                                File(widget.draft.mediaUrl),
                                fit: BoxFit.cover,
                                width: double.infinity,
                              )
                            : Image.network(
                                resolveMediaUrl(widget.draft.mediaUrl),
                                fit: BoxFit.cover,
                                width: double.infinity,
                              ),
                    ),
            ),
          ),

          // ✅ DESCRIPTION
          if (widget.draft.description.isNotEmpty)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                widget.draft.description,
                style:
                    const TextStyle(color: Colors.white, fontSize: 16),
              ),
            ),

          // ✅ BOUTON SUPPRIMER AVEC CONFIRMATION
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: SizedBox(
                width: double.infinity,
                height: 50,
                child: ElevatedButton.icon(
                  onPressed: _loading ? null : _confirmDelete,
                  icon: const Icon(Icons.delete),
                  label: const Text("Supprimer le brouillon"),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.red,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
