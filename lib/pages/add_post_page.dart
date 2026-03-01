// lib/pages/add_post_page.dart
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:nyota_app/services/media_upload_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../utils/storage_url.dart';
import 'package:path_provider/path_provider.dart';
import 'package:video_player/video_player.dart';
import 'package:nyota_app/offline/draft_local_store.dart';
import 'package:nyota_app/models/draft_local_model.dart';
import 'package:nyota_app/offline/draft_state.dart';
import 'package:nyota_app/offline/local_thumbnail_service.dart';


// --- CLASSIFICATION AUTO (reprise pour brouillon) ---
const Map<String, List<String>> categoryKeywords = {
  "telephone": [
    "phone",
    "iphone",
    "samsung",
    "xiaomi",
    "tecno",
    "itel",
    "huawei",
    "android",
    "chargeur",
    "cable",
    "coque",
  ],
  "vetements": [
    "shirt",
    "pants",
    "jean",
    "dress",
    "shoe",
    "bag",
    "tshirt",
    "jacket",
    "chemise",
    "pantalon",
    "robe",
    "chaussure",
    "sandale",
    "basket",
  ],
  "cosmetique": [
    "parfum",
    "creme",
    "lotion",
    "huile",
    "maquillage",
    "beaute",
    "savon",
  ],
  "electromenager": [
    "tv",
    "laptop",
    "speaker",
    "pc",
    "ordinateur",
    "mixeur",
    "ventilateur",
    "frigo",
    "refrigerateur",
    "cuiseur",
    "fer",
  ],
  "alimentation": [
    "food",
    "rice",
    "oil",
    "milk",
    "jus",
    "boisson",
    "riz",
    "huile",
    "lait",
    "sucre",
    "farine",
  ],
  "accessoires": [
    "watch",
    "bracelet",
    "earbuds",
    "airpods",
    "montre",
    "lunette",
    "bijou",
  ],
};

String autoDetectCategory(String description) {
  final text = description.toLowerCase().trim();
  if (text.isEmpty) return "divers";
  for (final entry in categoryKeywords.entries) {
    if (entry.value.any((kw) => text.contains(kw))) return entry.key;
  }
  return "divers";
}

/// Page pour créer / enregistrer en brouillon / publier une publication (image ou vidéo)
class AddPostPage extends StatefulWidget {
  const AddPostPage({super.key});

  @override
  State<AddPostPage> createState() => _AddPostPageState();
}

class _AddPostPageState extends State<AddPostPage>
    with WidgetsBindingObserver {
  final ImagePicker _picker = ImagePicker();

  File? _selectedFile; // fichier temporaire local (copie fiable)
  bool _isVideo = false;
  bool _loading = false;
  bool _pickingMedia = false;
  bool _showMediaOptions = false;
  VideoPlayerController? _videoController;
  bool _isPlaying = true;

  final TextEditingController _descriptionCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    debugPrint("draft lifecycle: $state");
  }

  // -----------------------------
  // Helpers
  // -----------------------------
  Future<File> _writeBytesToTempFile(Uint8List bytes, String ext) async {
    final tmpDir = await getTemporaryDirectory();
    final filename = 'nyota_${DateTime.now().millisecondsSinceEpoch}.$ext';
    final file = File('${tmpDir.path}/$filename');
    await file.writeAsBytes(bytes, flush: true);
    return file;
  }

  /// Upload en binaire — plus fiable sur certains appareils Android (Tecno / Itel)
  Future<String?> _uploadToSupabase(File file) async {
    try {
      final ext = file.path.split('.').last;
      final fileName = "nyota_${DateTime.now().millisecondsSinceEpoch}.$ext";
      final bytes = await file.readAsBytes();

      final uid = FirebaseAuth.instance.currentUser!.uid;
      final supabase = Supabase.instance.client;
      final fileNameWithPath = "posts/$uid/$fileName";

      await supabase.storage
          .from('posts')
          .uploadBinary(fileNameWithPath, bytes);

      final publicUrl =
          storagePublicUrl('posts', fileNameWithPath);

      return publicUrl;
    } catch (e, s) {
      debugPrint("Upload error: $e");
      debugPrint("Stack: $s");
      return null;
    }
  }

  // -----------------------------
  // Pickers (gallery + camera)
  // -----------------------------
  Future<void> _pickImageFromGallery() async {
    if (_pickingMedia) return;
    if (mounted) {
      setState(() => _pickingMedia = true);
    }

    try {
      final XFile? picked =
          await _picker.pickImage(source: ImageSource.gallery);
      if (!mounted) return;
      if (picked == null) return;

      final bytes = await picked.readAsBytes();
      if (!mounted) return;
      final ext = picked.path.split('.').last;
      final tmp = await _writeBytesToTempFile(bytes, ext);

      if (!mounted) return;
      setState(() {
        _selectedFile = tmp;
        _isVideo = false;
      });
    } catch (e) {
      debugPrint("pick image error: $e");
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text("Erreur sélection image")));
      }
    } finally {
      if (mounted) {
        setState(() => _pickingMedia = false);
      }
    }
  }

  Future<void> _upsertPostLocationFromUserLocation({
    required String postId,
    required String firebaseUid,
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
            'post_locations skipped: no user_locations row for user=$firebaseUid');
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
            'post_locations skipped: invalid lat/lng for user=$firebaseUid row=$row');
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
          'post_locations upsert post=$postId lat=$latitude lng=$longitude zone=${payload['zone']}');
    } catch (e) {
      debugPrint('post_locations upsert error post=$postId user=$firebaseUid $e');
    }
  }

  Future<void> _pickVideoFromGallery() async {
    if (_pickingMedia) return;
    if (mounted) {
      setState(() => _pickingMedia = true);
    }

    try {
      final XFile? picked =
          await _picker.pickVideo(source: ImageSource.gallery);
      if (!mounted) return;
      if (picked == null) return;

      final bytes = await picked.readAsBytes();
      if (!mounted) return;
      final ext = picked.path.split('.').last;
      final tmp = await _writeBytesToTempFile(bytes, ext);

      if (_videoController != null) {
        await _videoController!.pause();
        await _videoController!.dispose();
        _videoController = null;
      }

      final controller = VideoPlayerController.file(tmp);
      await controller.initialize();
      controller.play();

      if (!mounted) return;
      setState(() {
        _selectedFile = tmp;
        _isVideo = true;
        _videoController = controller;
        _isPlaying = true;
      });
    } catch (e) {
      debugPrint("pick video error: $e");
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text("Erreur sélection vidéo")));
      }
    } finally {
      if (mounted) {
        setState(() => _pickingMedia = false);
      }
    }
  }

  Future<void> _captureImageWithCamera() async {
    if (_pickingMedia) return;
    if (mounted) {
      setState(() => _pickingMedia = true);
    }

    try {
      // ✅ Sécurité cycle de vie
      if (!mounted) return;

      debugPrint("draft camera open");
      final XFile? picked = await _picker.pickImage(
        source: ImageSource.camera,
        imageQuality: 85,
        preferredCameraDevice: CameraDevice.rear,
        requestFullMetadata: false,
      );

      // ✅ L'utilisateur a annulé
      debugPrint("draft camera returned");
      if (picked == null || picked.path.isEmpty) return;

      // ✅ Lecture sécurisée
      final bytes = await picked.readAsBytes();
      if (!mounted) return;
      if (bytes.isEmpty) return;

      final ext = picked.path.split('.').last;

      // ✅ Copie dans fichier temporaire (anti "Invalid image data")
      final tmp = await _writeBytesToTempFile(bytes, ext);

      // ✅ Nettoyage vidéo propre
      if (_videoController != null) {
        await _videoController!.pause();
        await _videoController!.dispose();
        _videoController = null;
      }

      if (!mounted) return;

      // ✅ Mise à jour UI sécurisée
      setState(() {
        _selectedFile = tmp;
        _isVideo = false;
        _isPlaying = false;
      });
      debugPrint("draft ui updated");
    } catch (e) {
      debugPrint("camera image error: $e");

      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Erreur caméra (image)")),
      );
    } finally {
      if (mounted) {
        setState(() => _pickingMedia = false);
      }
    }
  }

  Future<void> _captureVideoWithCamera() async {
    if (_pickingMedia) return;
    if (mounted) {
      setState(() => _pickingMedia = true);
    }

    try {
      if (!mounted) return;
      debugPrint("draft camera open");
      final XFile? picked = await _picker.pickVideo(
        source: ImageSource.camera,
        maxDuration: const Duration(minutes: 2),
      );
      debugPrint("draft camera returned");
      if (!mounted) return;
      if (picked == null) return;

      final bytes = await picked.readAsBytes();
      if (!mounted) return;
      final ext = picked.path.split('.').last;

      // 🔥 Copier dans un vrai fichier
      final tmp = await _writeBytesToTempFile(bytes, ext);

      // 🔥 Initialiser le lecteur vidéo
      if (_videoController != null) {
        await _videoController!.pause();
        await _videoController!.dispose();
        _videoController = null;
      }

      final controller = VideoPlayerController.file(tmp);
      await controller.initialize();
      controller.setLooping(true);

      if (!mounted) return;
      setState(() {
        _selectedFile = tmp;
        _isVideo = true;
        _isPlaying = false;
        _videoController = controller;
      });
      debugPrint("draft ui updated");
    } catch (e) {
      debugPrint("camera video error: $e");
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Erreur caméra (vidéo)")),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _pickingMedia = false);
      }
    }
  }

  // -----------------------------
  // Save draft (upload then insert into 'drafts')
  // -----------------------------
Future<void> _saveDraft() async {
  if (_selectedFile == null) return;

  setState(() => _loading = true);
  debugPrint("draft save local start");

  try {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) throw Exception("User not logged");

    String? thumbnailLocalPath;
    if (_isVideo) {
      thumbnailLocalPath =
          await LocalThumbnailService.generateLocalThumbnail(
        videoFile: _selectedFile!,
      );
    }

    final now = DateTime.now();
    final draftId = 'draft_${user.uid}_${now.millisecondsSinceEpoch}';
    final draft = DraftLocalModel(
      id: draftId,
      userId: user.uid,
      mediaLocalPath: _selectedFile!.path,
      thumbnailLocalPath: thumbnailLocalPath,
      isVideo: _isVideo,
      description: _descriptionCtrl.text.trim(),
      createdAt: now,
      updatedAt: now,
      state: DraftState.localOnly,
      metadata: const {},
    );

    DraftLocalStore().upsert(draft);
    debugPrint("draft save local done");

    if (mounted) Navigator.pop(context, true);
  } catch (e) {
    debugPrint("Draft error: $e");
  } finally {
    if (mounted) setState(() => _loading = false);
  }
}

  // -----------------------------
  // Publish (upload then insert into 'posts')
  // -----------------------------
 Future<void> _publish() async {
  if (_selectedFile == null) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text("Choisissez un média")),
    );
    return;
  }

  setState(() => _loading = true);

  try {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) throw Exception("User not logged");

    final supabase = Supabase.instance.client;

    // 1️⃣ Créer le post D'ABORD (pour obtenir postId)
    final description = _descriptionCtrl.text.trim();
    final category = autoDetectCategory(description);

    final postInsert = await supabase.from('posts').insert({
      "seller_id": user.uid,
      "description": description,
      "category": category,
      "is_video": _isVideo,
      "created_at": DateTime.now().toIso8601String(),
      "likes": 0,
    }).select().single();

    final String postId = postInsert['id'].toString();
    debugPrint("post publish insert ok post_id=$postId");

    await _upsertPostLocationFromUserLocation(
      postId: postId,
      firebaseUid: user.uid,
    );

    print("UPLOAD bucket=posts start user=${user.uid} isVideo=$_isVideo");
    // 2️⃣ Upload média (SUPABASE GÈRE LE THUMBNAIL)
    final mediaResult = await MediaUploadService.uploadMedia(
      file: _selectedFile!,
      isVideo: _isVideo,
      userId: postId, // 🔥 IMPORTANT
    );

    print("DB INSERT media_path=${mediaResult['media_path']}");

    // 3️⃣ Mettre à jour le post avec media + thumbnail + type
    final updatePayload = {
      "media_url": mediaResult['media_url'],
      "thumbnail_url": mediaResult['thumbnail_url'],
      "media_path": mediaResult['media_path'],
      "thumbnail_path": mediaResult['thumbnail_path'],
      "media_type": _isVideo ? "video" : "image",
      "is_video": _isVideo,
    };
    debugPrint("post update payload=$updatePayload");
    await supabase.from('posts').update(updatePayload).eq('id', postId);

    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text("Publié avec succès")),
    );
    Navigator.pop(context, true);
  } catch (e) {
    debugPrint("Publish error: $e");
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Erreur publication")),
      );
    }
  } finally {
    if (mounted) setState(() => _loading = false);
  }
}

  void _showMediaPickerSheet() {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) {
        return Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                "Choisir un média",
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 16),
              ListTile(
                leading: const Icon(Icons.photo),
                title: const Text("Galerie (Image)"),
                onTap: () {
                  Navigator.pop(context);
                  _pickImageFromGallery();
                },
              ),
              ListTile(
                leading: const Icon(Icons.video_library),
                title: const Text("Galerie (Vidéo)"),
                onTap: () {
                  Navigator.pop(context);
                  _pickVideoFromGallery();
                },
              ),
              ListTile(
                leading: const Icon(Icons.camera_alt),
                title: const Text("Caméra (Image)"),
                onTap: () async {
                  Navigator.pop(context);

                  await Future.delayed(const Duration(milliseconds: 400));

                  if (!mounted) return;

                  await _captureImageWithCamera();
                },
              ),
              ListTile(
                leading: const Icon(Icons.videocam),
                title: const Text("Caméra (Vidéo)"),
                onTap: () async {
                  Navigator.pop(context);
                  await Future.delayed(const Duration(milliseconds: 400));
                  if (!mounted) return;
                  await _captureVideoWithCamera();
                },
              ),
            ],
          ),
        );
      },
    );
  }

  // -----------------------------
// UI (VERSION PRO - SANS PUBLIER)
// -----------------------------
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Brouillon"),
        centerTitle: true,
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: TextButton.icon(
              onPressed: _loading ? null : _saveDraft,
              icon: const Icon(Icons.save, color: Colors.white),
              label: _loading
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        color: Colors.white,
                        strokeWidth: 2,
                      ),
                    )
                  : const Text(
                      "Enregistrer",
                      style: TextStyle(
                        color: Colors.green,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // DESCRIPTION
              TextField(
                controller: _descriptionCtrl,
                decoration: const InputDecoration(
                  labelText: "Description",
                  border: OutlineInputBorder(),
                ),
                maxLines: 3,
              ),

              const SizedBox(height: 16),

              // PREVIEW
              Container(
                height: 260,
                decoration: BoxDecoration(
                  color: Colors.black12,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: _selectedFile == null
                    ? const Center(child: Text("Aucun média sélectionné"))
                    : _isVideo && _videoController != null
                        ? GestureDetector(
                            onTap: () {
                              setState(() {
                                if (_videoController!.value.isPlaying) {
                                  _videoController!.pause();
                                  _isPlaying = false;
                                } else {
                                  _videoController!.play();
                                  _isPlaying = true;
                                }
                              });
                            },
                            child: Stack(
                              alignment: Alignment.center,
                              children: [
                                AspectRatio(
                                  aspectRatio:
                                      _videoController!.value.aspectRatio,
                                  child: VideoPlayer(_videoController!),
                                ),
                                if (!_videoController!.value.isPlaying)
                                  const Icon(Icons.play_circle_fill,
                                      color: Colors.white, size: 80),
                                Positioned(
                                  bottom: 10,
                                  left: 10,
                                  right: 10,
                                  child: VideoProgressIndicator(
                                    _videoController!,
                                    allowScrubbing: true,
                                  ),
                                ),
                              ],
                            ),
                          )
                        : ClipRRect(
                            borderRadius: BorderRadius.circular(12),
                            child: Image.file(
                              _selectedFile!,
                              fit: BoxFit.cover,
                              width: double.infinity,
                            ),
                          ),
              ),

              const SizedBox(height: 30),

              Stack(
                alignment: Alignment.center,
                children: [
                  if (_showMediaOptions)
                    GestureDetector(
                      onTap: () {
                        setState(() {
                          _showMediaOptions = false;
                        });
                      },
                      child: Container(
                        height: 220,
                        width: double.infinity,
                        color: Colors.black.withOpacity(0.4),
                      ),
                    ),
                  if (_showMediaOptions)
                    Column(
                      children: [
                        _mediaChoiceButton(
                          icon: Icons.photo,
                          label: "Galerie Image",
                          onTap: () {
                            setState(() => _showMediaOptions = false);
                            _pickImageFromGallery();
                          },
                        ),
                        _mediaChoiceButton(
                          icon: Icons.video_library,
                          label: "Galerie Vidéo",
                          onTap: () {
                            setState(() => _showMediaOptions = false);
                            _pickVideoFromGallery();
                          },
                        ),
                        _mediaChoiceButton(
                          icon: Icons.camera_alt,
                          label: "Caméra Image",
                          onTap: () {
                            setState(() => _showMediaOptions = false);
                            _captureImageWithCamera();
                          },
                        ),
                        _mediaChoiceButton(
                          icon: Icons.videocam,
                          label: "Caméra Vidéo",
                          onTap: () {
                            setState(() => _showMediaOptions = false);
                            _captureVideoWithCamera();
                          },
                        ),
                      ],
                    ),
                  FloatingActionButton(
                    onPressed: () {
                      setState(() {
                        _showMediaOptions = !_showMediaOptions;
                      });
                    },
                    child: Icon(_showMediaOptions ? Icons.close : Icons.add),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _videoController?.dispose();
    _descriptionCtrl.dispose();
    super.dispose();
  }
}

Widget _mediaChoiceButton({
  required IconData icon,
  required String label,
  required VoidCallback onTap,
}) {
  return Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: ElevatedButton.icon(
      icon: Icon(icon),
      label: Text(label),
      onPressed: onTap,
      style: ElevatedButton.styleFrom(
        minimumSize: const Size(220, 48),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(30),
        ),
      ),
    ),
  );
}

