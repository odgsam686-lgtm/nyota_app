// pages/profil_page.dart
import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:nyota_app/pages/add_post_page.dart';
import 'publication_preview_page.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../utils/storage_url.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:video_player/video_player.dart';
import 'package:nyota_app/pages/private_profile_menu.dart';
import 'package:video_thumbnail/video_thumbnail.dart';
import 'package:nyota_app/offline/draft_local_store.dart';
import 'package:nyota_app/models/draft_local_model.dart';
import 'package:nyota_app/offline/offline_manager.dart';
import 'package:nyota_app/offline/draft_state.dart';
import '../utils/media_resolver.dart';

// Assure-toi que ton PostModel est exactement comme tu l'as montré
import '../models/post_model.dart';
import '../pages/media_viewer_page.dart';
import '../services/profile_stats_service.dart';

final RouteObserver<PageRoute<dynamic>> routeObserver =
    RouteObserver<PageRoute<dynamic>>();

class ProfilPage extends StatefulWidget {
  const ProfilPage({super.key});

  @override
  State<ProfilPage> createState() => _ProfilPageState();
}

class _ProfilPageState extends State<ProfilPage> with RouteAware {
  final supabase = Supabase.instance.client;
  final picker = ImagePicker();
  final Set<String> _publishingDraftIds = {};
  bool _isOffline = false;
  late final StreamSubscription<ConnectivityResult> _connectivitySub;
  final Random _rand = Random();

  Map<String, dynamic>? userData;
  bool loading = true;
  bool showBusinessStats = false; // 👈 pour l’instant désactivé

  List<PostModel> products = []; // Publications (posts)
  List<PostModel> drafts = []; // Brouillons
  List<DraftLocalModel> localDrafts = [];

  int commandesRecues = 0;
  int commandesEnAttente = 0;
  int commandesNonRecues = 0;
  int pointsFidelite = 0;
  int followersCount = 0;
  int followingCount = 0;
  int creatorViews = 0;
  int creatorLikes = 0;

  bool isSeller = false;

  String? userId; // firebase uid (on garde FirebaseAuth)
  String fullName = "";
  String? displayName; // nom public
  String? bio;

  @override
  void initState() {
    super.initState();
    DraftOfflineManager.normalizeDraftsOnStartup();
    _initConnectivity();
    final user = FirebaseAuth.instance.currentUser;
    userId = user?.uid;
    debugPrint("✅ PROFIL OUVERT POUR userId = $userId");

    products = [];
    drafts = [];

    _initAndLoad(); // ✅ UN SEUL POINT D’ENTRÉE
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route is PageRoute) {
      routeObserver.subscribe(this, route);
    }
  }

  @override
  void didPopNext() {
    // ✅ Ajoute un petit délai ou vérifie si c'est nécessaire
    Future.delayed(const Duration(milliseconds: 500), () {
      if (mounted) {
        _loadDrafts();
        _loadPublications();
        _loadProfileStats();
      }
    });
    super.didPopNext();
  }

  @override
  void dispose() {
    routeObserver.unsubscribe(this);
    _connectivitySub.cancel();
    super.dispose();
  }

  void _initConnectivity() {
    final connectivity = Connectivity();
    connectivity.checkConnectivity().then((result) {
      if (!mounted) return;
      setState(() {
        _isOffline = result == ConnectivityResult.none;
      });
    });
    _connectivitySub =
        connectivity.onConnectivityChanged.listen((result) {
      if (!mounted) return;
      setState(() {
        _isOffline = result == ConnectivityResult.none;
      });
    });
  }

  Widget _statItem(String label, int value) {
    return Column(
      children: [
        Text(
          value.toString(),
          style: const TextStyle(
            color: Colors.white,
            fontSize: 16,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          label,
          style: const TextStyle(color: Colors.white70, fontSize: 12),
        ),
      ],
    );
  }

  Future<void> _initAndLoad() async {
  // 1. Vérification de l'utilisateur
  final fbUser = FirebaseAuth.instance.currentUser;
  if (fbUser == null) {
    if (mounted) {
      setState(() => loading = false);
    }
    return;
  }

  userId = fbUser.uid;

  try {
    // 2. Charger d'abord les données de base de l'utilisateur
    await _loadUserData();

    // Vérifier si l'écran est toujours affiché après la première requête réseau
    if (!mounted) return;

    // 3. Lancer les autres chargements EN PARALLÈLE pour gagner du temps
    // On utilise Future.wait pour que l'app soit plus rapide
    await Future.wait([
      _loadPublications(),
      _loadProfileStats(),
      _loadDrafts(),
    ]);

  } catch (e) {
    debugPrint("❌ Erreur lors de l'initialisation du profil: $e");
  } finally {
    // 4. Quoi qu'il arrive, on arrête le chargement si on est toujours sur la page
    if (mounted) {
      setState(() => loading = false);
    }
  }
}
  // ===========================
  // Helper safe select - compatible SDK versions
  // ===========================
  Future<List<dynamic>> _selectRows({
    required String table,
    required String columns,
    String? eqColumn,
    Object? eqValue,
    String? orderBy,
    bool ascending = true,
  }) async {
    dynamic query = Supabase.instance.client.from(table).select(columns);

    // ✅ FILTRE
    if (eqColumn != null && eqValue != null) {
      query = query.eq(eqColumn, eqValue);
    }

    // ✅ TRI
    if (orderBy != null) {
      query = query.order(orderBy, ascending: ascending);
    }

    final result = await query;

    return result is List ? result : [];
  }

  // ===========================
  // Load user data from Supabase users table
  // ===========================
 Future<void> _loadUserData() async {
  if (userId == null) return;

  try {
    final rows = await _selectRows(
      table: 'users',
      columns: '*',
      eqColumn: 'firebase_uid',
      eqValue: userId!,
    );

    // 1️⃣ SÉCURITÉ : On vérifie si l'utilisateur n'a pas quitté la page 
    // pendant que Supabase répondait (évite le crash setState)
    if (!mounted) return;

    if (rows.isEmpty) {
      userData = {
        'firebase_uid': userId!,
        'email': FirebaseAuth.instance.currentUser?.email,
        'first_name': '',
        'last_name': '',
        'display_name': null,
        'bio': null,
        'photo_url': null,
        'is_seller': false,
      };
    } else {
      userData = Map<String, dynamic>.from(rows.first as Map);
    }

    // Mise à jour des variables locales
    isSeller = userData?['is_seller'] == true;

    displayName = userData?['display_name'] ??
        "${userData?['first_name'] ?? ''} ${userData?['last_name'] ?? ''}"
            .trim();

    if (displayName == null || displayName!.isEmpty) {
      displayName = userData?['email'];
    }

    bio = userData?['bio'];

    // 2️⃣ SÉCURITÉ : On vérifie encore mounted avant de rafraîchir l'écran
    if (mounted) setState(() {});
    
  } catch (e) {
    debugPrint("❌ Erreur chargement user: $e");
    // Optionnel : on peut forcer l'arrêt du chargement ici aussi
    if (mounted) setState(() => loading = false);
  }
}

Future<Map<String, dynamic>> _fetchUserProfile() async {
  final firebaseUser = FirebaseAuth.instance.currentUser;
  if (firebaseUser == null) {
    throw Exception("Utilisateur non connecté");
  }

  final user = await Supabase.instance.client
      .from('users')
      .select()
      .eq('firebase_uid', firebaseUser.uid)
      .single();

  final profile = await Supabase.instance.client
      .from('public_profiles')
      .select('username')
      .eq('user_id', firebaseUser.uid)
      .maybeSingle();

  if (profile != null && profile['username'] != null) {
    user['username'] = profile['username'];
  }

  return user;
}

  String _normalizeUsername(String input) {
    final lower = input.toLowerCase();
    final noAccents = lower
        .replaceAll(RegExp(r'[àáâäãå]'), 'a')
        .replaceAll(RegExp(r'[ç]'), 'c')
        .replaceAll(RegExp(r'[èéêë]'), 'e')
        .replaceAll(RegExp(r'[ìíîï]'), 'i')
        .replaceAll(RegExp(r'[ñ]'), 'n')
        .replaceAll(RegExp(r'[òóôöõ]'), 'o')
        .replaceAll(RegExp(r'[ùúûü]'), 'u')
        .replaceAll(RegExp(r'[ýÿ]'), 'y');
    final cleaned = noAccents.replaceAll(RegExp(r'[^a-z0-9]'), '');
    return cleaned;
  }

  String _randomDigits(int count) {
    final buffer = StringBuffer();
    for (int i = 0; i < count; i++) {
      buffer.write(_rand.nextInt(10));
    }
    return buffer.toString();
  }

  Future<String> _generateUniqueUsername(String displayName, String uid) async {
    final base = _normalizeUsername(displayName);
    final root = base.isNotEmpty ? base : 'user';

    for (int i = 0; i < 6; i++) {
      final candidate = i == 0 ? root : '$root${_randomDigits(4)}';
      final res = await supabase
          .from('public_profiles')
          .select('user_id')
          .eq('username', candidate)
          .limit(1);

      if (res.isEmpty || res.first['user_id'] == uid) {
        return candidate;
      }
    }

    return '$root${DateTime.now().millisecondsSinceEpoch % 100000}';
  }


  Future<String?> generateAndUploadThumbnail(File videoFile, String postId) async {
  // 1. Créer le fichier image dans le téléphone
  final thumbnailPath = await VideoThumbnail.thumbnailFile(
    video: videoFile.path,
    imageFormat: ImageFormat.JPEG,
    maxWidth: 400, // On limite la taille pour la grille
    quality: 75,
  );

  if (thumbnailPath != null) {
    File file = File(thumbnailPath);
    // 2. Upload sur Supabase dans un dossier /thumbnails
    final fileName = 'thumb_$postId.jpg';
    await supabase.storage.from('posts_media').upload('thumbnails/$fileName', file);
    
    // 3. Récupérer l'URL
    return storagePublicUrl('posts_media', 'thumbnails/$fileName');
  }
  return null;
}

  Future<void> _loadProfileStats() async {
    if (userId == null) return;

    try {
      final stats = await ProfileStatsService.loadStats(userId!);

      if (!mounted) return;

      setState(() {
        followersCount = stats.followers;
        followingCount = stats.following;
        creatorViews = stats.views;
        creatorLikes = stats.likes;
      });
    } catch (e) {
      debugPrint("❌ ERREUR LOAD STATS PROFIL PRIVÉ: $e");
    }
  }

  // ===========================
  // Load publications (posts) for current user
  // ===========================
  Future<void> _loadPublications() async {
    debugPrint("📌 LOAD PUBLICATIONS POUR userId = $userId");
    final currentUser = FirebaseAuth.instance.currentUser;
    if (currentUser == null) return;
    try {
      final rows = await _selectRows(
        table: 'posts',
        columns:
            'id, seller_id, seller_name, media_url, thumbnail_path, is_video, description, created_at',
        eqColumn: 'seller_id',
        eqValue: userId,
        orderBy: 'created_at',
        ascending: false,
      );

      debugPrint("📦 POSTS REÇUS: ${rows.length}");
      for (final r in rows) {
        debugPrint("➡️ POST seller_id = ${r['seller_id']}");
      }

      products = rows.map<PostModel>((r) {
        final row = Map<String, dynamic>.from(r as Map);
        return _rowToPostModel(row);
      }).toList();

      if (mounted) setState(() {});
    } catch (e) {
      debugPrint("Erreur _loadPublications: $e");
    }
    await _loadProfileStats(); // ✅ ICI EXACTEMENT
  }

  // ===========================
  // Load drafts
  // ===========================
 Future<void> _loadDrafts() async {
    final store = DraftLocalStore();
    localDrafts = store.getByStates([
      DraftState.localOnly,
      DraftState.queued,
      DraftState.uploading,
      DraftState.failed,
    ]);
    if (mounted) setState(() {});
  }
  // ===========================
  // Pick & upload avatar to Supabase storage
  // ===========================
  File? _pendingAvatar;
  bool _uploadingAvatar = false;
  String? _avatarUrlUI;

  Future<void> _pickAndUploadPhoto(ImageSource source) async {
    final XFile? file = await picker.pickImage(
      source: source,
      imageQuality: 70,
      maxWidth: 1024,
    );

    if (file == null || userId == null) return;

    final ext = file.path.split('.').last;
    final fileName = "${userId!}_${DateTime.now().millisecondsSinceEpoch}.$ext";
    final avatarFile = File(file.path);

    try {
      // 1) Upload storage
      try {
        await supabase.storage.from('avatars').upload(
              fileName,
              avatarFile,
              fileOptions: const FileOptions(upsert: true),
            );
      } catch (e) {
        debugPrint("ERREUR upload storage avatar: $e");
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text("Erreur upload storage: $e")),
          );
        }
        return;
      }

      final avatarUrl = storagePublicUrl('avatars', fileName);

      // 2) Update users (ne pas bloquer UI si public_profiles échoue)
      try {
        await supabase.from('users').update({
          'photo_url': avatarUrl,
        }).eq('firebase_uid', userId!);
      } catch (e) {
        debugPrint("ERREUR update users photo_url: $e");
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text("Erreur update users: $e")),
          );
        }
      }

      // ✅ UI refresh immédiat (cache-bust)
      if (mounted) {
        setState(() {
          userData ??= {};
          userData!['photo_url'] = avatarUrl;
          _avatarUrlUI =
              "$avatarUrl?v=${DateTime.now().millisecondsSinceEpoch}";
        });
      }

      // 3) Sync public_profiles (séparé)
      try {
        final profile = await supabase
            .from('public_profiles')
            .select('username, display_name, bio')
            .eq('user_id', userId!)
            .maybeSingle();
        final existingUsername = profile?['username']?.toString().trim();
        final usernameToSave = (existingUsername == null ||
                existingUsername.isEmpty)
            ? await _generateUniqueUsername(displayName ?? userId!, userId!)
            : existingUsername;

        await supabase.from('public_profiles').upsert({
          'user_id': userId!,
          'username': usernameToSave,
          'avatar_url': avatarUrl,
          'display_name': displayName ?? profile?['display_name'],
          'bio': bio ?? profile?['bio'],
          'updated_at': DateTime.now().toIso8601String(),
        });
      } catch (e) {
        debugPrint("ERREUR upsert public_profiles avatar: $e");
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text("Erreur public_profiles: $e")),
          );
        }
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("✅ Photo mise à jour")),
        );
      }
    } catch (e) {
      debugPrint("ERREUR upload avatar (global): $e");
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Erreur upload photo: $e")),
        );
      }
    }
  }

  Future<void> _showAvatarConfirmDialog() async {
    if (_pendingAvatar == null) return;

    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        return AlertDialog(
          title: const Text("Confirmer la photo"),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ClipOval(
                child: Image.file(
                  _pendingAvatar!,
                  width: 120,
                  height: 120,
                  fit: BoxFit.cover,
                ),
              ),
              const SizedBox(height: 12),
              const Text("Voulez-vous utiliser cette photo comme avatar ?"),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () {
                setState(() => _pendingAvatar = null);
                Navigator.pop(context);
              },
              child: const Text("Annuler"),
            ),
            ElevatedButton(
              onPressed: _uploadingAvatar ? null : _confirmUploadAvatar,
              child: const Text("Confirmer"),
            ),
          ],
        );
      },
    );
  }

  Future<void> _confirmUploadAvatar() async {
    if (_pendingAvatar == null || userId == null) return;

    setState(() => _uploadingAvatar = true);

    final ext = _pendingAvatar!.path.split('.').last;
    final name = "${userId!}.${DateTime.now().millisecondsSinceEpoch}.$ext";

    try {
      await supabase.storage.from('avatars').upload(
            name,
            _pendingAvatar!,
            fileOptions: const FileOptions(upsert: true),
          );

      final avatarUrl = storagePublicUrl('avatars', name);

      await supabase.from('users').update({
        'photo_url': avatarUrl,
      }).eq('firebase_uid', userId!);

      if (!mounted) return;

      setState(() {
        userData ??= {};
        userData!['photo_url'] = avatarUrl;
        _pendingAvatar = null;
        _uploadingAvatar = false;
      });

      Navigator.pop(context);

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("✅ Photo de profil mise à jour")),
      );
    } catch (e) {
      setState(() => _uploadingAvatar = false);

      debugPrint("Erreur upload avatar: $e");

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Erreur: $e")),
      );
    }
  }

  Future<void> _deleteAvatar() async {
    if (userId == null) return;

    try {
      // 1) Update users
      try {
        await supabase.from('users').update({
          'photo_url': null,
        }).eq('firebase_uid', userId!);
      } catch (e) {
        debugPrint("ERREUR update users delete avatar: $e");
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text("Erreur update users: $e")),
          );
        }
      }

      if (mounted) {
        setState(() {
          userData?['photo_url'] = null;
          _avatarUrlUI = null;
        });
      }

      // 2) Sync public_profiles
      try {
        final profile = await supabase
            .from('public_profiles')
            .select('username, display_name, bio')
            .eq('user_id', userId!)
            .maybeSingle();
        final existingUsername = profile?['username']?.toString().trim();
        final usernameToSave = (existingUsername == null ||
                existingUsername.isEmpty)
            ? await _generateUniqueUsername(displayName ?? userId!, userId!)
            : existingUsername;

        await supabase.from('public_profiles').upsert({
          'user_id': userId!,
          'username': usernameToSave,
          'avatar_url': null,
          'display_name': displayName ?? profile?['display_name'],
          'bio': bio ?? profile?['bio'],
          'updated_at': DateTime.now().toIso8601String(),
        });
      } catch (e) {
        debugPrint("ERREUR upsert public_profiles delete avatar: $e");
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text("Erreur public_profiles: $e")),
          );
        }
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("✅ Photo de profil supprimée")),
        );
      }
    } catch (e) {
      debugPrint("ERREUR suppression avatar (global): $e");
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Erreur suppression avatar: $e")),
        );
      }
    }
  }

  void _showAvatarOptionsSheet() {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_library),
              title: const Text("Galerie"),
              onTap: () {
                Navigator.pop(context);
                _pickAndUploadPhoto(ImageSource.gallery);
              },
            ),
            ListTile(
              leading: const Icon(Icons.photo_camera),
              title: const Text("Appareil photo"),
              onTap: () {
                Navigator.pop(context);
                _pickAndUploadPhoto(ImageSource.camera);
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete),
              title: const Text("Supprimer la photo"),
              onTap: () {
                Navigator.pop(context);
                _deleteAvatar();
              },
            ),
            ListTile(
              leading: const Icon(Icons.close),
              title: const Text("Annuler"),
              onTap: () => Navigator.pop(context),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _editDisplayName() async {
    final controller = TextEditingController(text: displayName);
    bool saving = false;
    String? errorText;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (_) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            void validate(String value) {
              final trimmed = value.trim();
              if (trimmed.isEmpty || trimmed.length < 2) {
                errorText = "Minimum 2 caractères";
              } else if (trimmed.length > 30) {
                errorText = "Maximum 30 caractères";
              } else {
                errorText = null;
              }
            }

            validate(controller.text);

            return Padding(
              padding: EdgeInsets.only(
                left: 16,
                right: 16,
                top: 16,
                bottom: MediaQuery.of(context).viewInsets.bottom + 16,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    "Modifier le nom",
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  TextField(
                    controller: controller,
                    onChanged: (v) {
                      setModalState(() {
                        validate(v);
                      });
                    },
                    decoration: InputDecoration(
                      hintText: "Entrez votre nom",
                      errorText: errorText,
                    ),
                  ),
                  const SizedBox(height: 12),
                  ElevatedButton(
                    onPressed: (errorText != null || saving)
                        ? null
                        : () async {
                            final value = controller.text.trim();
                            setModalState(() => saving = true);
                            try {
                              await supabase.from('users').update({
                                'display_name': value,
                              }).eq('firebase_uid', userId!);

                              final profile = await supabase
                                  .from('public_profiles')
                                  .select('username')
                                  .eq('user_id', userId!)
                                  .maybeSingle();
                              final existingUsername =
                                  profile?['username']?.toString().trim();
                              final usernameToSave = (existingUsername == null ||
                                      existingUsername.isEmpty)
                                  ? await _generateUniqueUsername(
                                      value, userId!)
                                  : existingUsername;

                              await supabase.from('public_profiles').upsert({
                                'user_id': userId!,
                                'display_name': value,
                                'username': usernameToSave,
                                'updated_at': DateTime.now().toIso8601String(),
                              });

                              if (!mounted) return;
                              setState(() {
                                displayName = value;
                              });
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                    content: Text("✅ Nom mis à jour")),
                              );
                              Navigator.pop(context);
                            } catch (e) {
                              if (mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(content: Text("Erreur: $e")),
                                );
                              }
                            } finally {
                              if (mounted) {
                                setModalState(() => saving = false);
                              }
                            }
                          },
                    child: Text(saving ? "Enregistrement..." : "Enregistrer"),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _editBio() async {
    final controller = TextEditingController(text: bio);
    bool saving = false;
    String? errorText;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (_) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            void validate(String value) {
              final trimmed = value.trim();
              if (trimmed.length > 120) {
                errorText = "Maximum 120 caractères";
              } else {
                errorText = null;
              }
            }

            validate(controller.text);

            return Padding(
              padding: EdgeInsets.only(
                left: 16,
                right: 16,
                top: 16,
                bottom: MediaQuery.of(context).viewInsets.bottom + 16,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    "Modifier la bio",
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  TextField(
                    controller: controller,
                    maxLength: 120,
                    onChanged: (v) {
                      setModalState(() {
                        validate(v);
                      });
                    },
                    decoration: InputDecoration(
                      hintText: "Parlez de vous",
                      errorText: errorText,
                    ),
                  ),
                  const SizedBox(height: 12),
                  ElevatedButton(
                    onPressed: (errorText != null || saving)
                        ? null
                        : () async {
                            final value = controller.text.trim();
                            setModalState(() => saving = true);
                            try {
                              await supabase.from('users').update({
                                'bio': value,
                              }).eq('firebase_uid', userId!);

                              final profile = await supabase
                                  .from('public_profiles')
                                  .select('username')
                                  .eq('user_id', userId!)
                                  .maybeSingle();
                              final existingUsername =
                                  profile?['username']?.toString().trim();
                              final usernameToSave = (existingUsername == null ||
                                      existingUsername.isEmpty)
                                  ? await _generateUniqueUsername(
                                      displayName ?? userId!, userId!)
                                  : existingUsername;

                              await supabase.from('public_profiles').upsert({
                                'user_id': userId!,
                                'bio': value,
                                'username': usernameToSave,
                                'updated_at': DateTime.now().toIso8601String(),
                              });

                              if (!mounted) return;
                              setState(() {
                                bio = value;
                              });
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                    content: Text("✅ Bio mise à jour")),
                              );
                              Navigator.pop(context);
                            } catch (e) {
                              if (mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(content: Text("Erreur: $e")),
                                );
                              }
                            } finally {
                              if (mounted) {
                                setModalState(() => saving = false);
                              }
                            }
                          },
                    child: Text(saving ? "Enregistrement..." : "Enregistrer"),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  void _openEditSheet({
    required String title,
    required String initialValue,
    required Function(String) onSave,
  }) {
    final controller = TextEditingController(text: initialValue);

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return DraggableScrollableSheet(
          initialChildSize: 0.35,
          minChildSize: 0.25,
          maxChildSize: 0.9,
          expand: false,
          builder: (context, scrollController) {
            return Container(
              padding: EdgeInsets.only(
                left: 16,
                right: 16,
                top: 16,
                bottom: MediaQuery.of(context).viewInsets.bottom + 16,
              ),
              decoration: const BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
              ),
              child: SingleChildScrollView(
                controller: scrollController,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: controller,
                      autofocus: true,
                      maxLines: null,
                      decoration: const InputDecoration(
                        hintText: "Écrire ici...",
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Align(
                      alignment: Alignment.centerRight,
                      child: ElevatedButton(
                        onPressed: () {
                          onSave(controller.text.trim());
                          Navigator.pop(context);
                        },
                        child: const Text("Enregistrer"),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

// ===========================
  // Activate seller flow -> update users table
  // ===========================
  void _activateSellerFlow() {
    final shopCtrl = TextEditingController();
    final phoneCtrl = TextEditingController(text: userData?["phone"] ?? "");
    final emailCtrl = TextEditingController(
        text: FirebaseAuth.instance.currentUser?.email ?? "");
    final addressCtrl = TextEditingController(text: userData?["address"] ?? "");

    bool accepted = false;

    showDialog(
      context: context,
      barrierDismissible: false, // Empêche de fermer en cliquant à côté pendant l'opération
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setStateDialog) {
          // La condition pour activer le bouton
          bool isFormValid = accepted &&
              shopCtrl.text.trim().isNotEmpty &&
              phoneCtrl.text.trim().isNotEmpty &&
              addressCtrl.text.trim().isNotEmpty;

          return AlertDialog(
            title: const Text("Activer le profil vendeur"),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                      "Conditions :\n- Commission 10% (MVP2)\n- Coordonnées obligatoires\n",
                      style: TextStyle(fontSize: 13, color: Colors.grey)),
                  TextField(
                      controller: shopCtrl,
                      onChanged: (_) => setStateDialog(() {}), // Force la vérification du bouton
                      decoration: const InputDecoration(labelText: "Nom de boutique *")),
                  TextField(
                      controller: phoneCtrl,
                      onChanged: (_) => setStateDialog(() {}),
                      keyboardType: TextInputType.phone,
                      decoration: const InputDecoration(labelText: "Téléphone *")),
                  TextField(
                      controller: emailCtrl,
                      enabled: false,
                      decoration: const InputDecoration(
                          labelText: "Email (non modifiable)")),
                  TextField(
                      controller: addressCtrl,
                      onChanged: (_) => setStateDialog(() {}),
                      decoration: const InputDecoration(labelText: "Localisation *")),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Checkbox(
                          value: accepted,
                          activeColor: Colors.deepPurple,
                          onChanged: (v) =>
                              setStateDialog(() => accepted = v ?? false)),
                      const Expanded(
                        child: Text("J'accepte les conditions de vente",
                            style: TextStyle(fontSize: 12)),
                      ),
                    ],
                  )
                ],
              ),
            ),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text("Annuler", style: TextStyle(color: Colors.red))),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: isFormValid ? Colors.deepPurple : Colors.grey,
                  foregroundColor: Colors.white,
                ),
                onPressed: isFormValid
                    ? () async {
                        try {
                          // 1️⃣ Mise à jour table 'users'
                          await supabase.from('users').update({
                            "is_seller": true,
                            "shop_name": shopCtrl.text.trim(),
                            "phone": phoneCtrl.text.trim(),
                            "address": addressCtrl.text.trim(),
                          }).eq('firebase_uid', userId!);

                          // 2️⃣ Mise à jour table 'public_profiles'
                          await supabase
                              .from('public_profiles')
                              .update({'is_seller': true})
                              .eq('user_id', userId!);

                          // 3️⃣ Recharger les données et l'UI
                          await _loadUserData();
                          
                          if (!mounted) return;

                          // 4️⃣ Fermer le dialogue
                          if (Navigator.canPop(ctx)) {
                            Navigator.pop(ctx);
                          }

                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text("Profil vendeur activé !")),
                          );
                        } catch (e) {
                          debugPrint("❌ Erreur activation vendeur: $e");
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text("Erreur : $e")),
                          );
                        }
                      }
                    : null, // Reste null (gris) si le formulaire est invalide
                child: const Text("Activer"),
              )
            ],
          );
        },
      ),
    );
  }

  // ===========================
  // Parse date flexible (timestamp/int/ISO string)
  // ===========================
  DateTime _parseDateTime(dynamic val) {
    if (val == null) return DateTime.fromMillisecondsSinceEpoch(0);
    if (val is DateTime) return val;
    if (val is int) {
      // seconds vs ms
      if (val.toString().length == 10)
        return DateTime.fromMillisecondsSinceEpoch(val * 1000);
      return DateTime.fromMillisecondsSinceEpoch(val);
    }
    if (val is String) {
      try {
        return DateTime.parse(val);
      } catch (_) {
        final n = int.tryParse(val);
        if (n != null) return _parseDateTime(n);
      }
    }
    return DateTime.fromMillisecondsSinceEpoch(0);
  }

  // ===========================
  // Convert row -> PostModel
  // ===========================
  PostModel _rowToPostModel(Map<String, dynamic> row, {bool isDraft = false}) {
    final id = row['id']?.toString() ?? '';
    final sellerId = isDraft ? (row['user_id']?.toString() ?? '') : (row['seller_id']?.toString() ?? '');
    final sellerName = row['seller_name']?.toString() ?? '';
    final mediaUrl = row['media_url']?.toString();
    final isVideo = row['is_video'] == true;
    final description = row['description']?.toString() ?? '';
    final createdAt = _parseDateTime(row['created_at']);
    final thumb = row['thumbnail_path'] ?? row['thumbnail_url'];

    return PostModel(
      id: id,
      sellerId: sellerId,
      sellerName: sellerName,
      mediaUrl: mediaUrl ?? '',
      thumbnailUrl: thumb?.toString(),
      isVideo: isVideo,
      description: description,
      timestamp: createdAt,
      likes: row['likes'] ?? 0,
    );
  }
Future<void> _publishFromDraft(PostModel draft) async {
    setState(() => loading = true);
    try {
      // 1. Récupérer le profil pour avoir les infos à jour
      final profile = await supabase.from('public_profiles').select().eq('user_id', userId!).maybeSingle();

      // 2. Insérer dans 'posts'
      await supabase.from('posts').insert({
        'seller_id': userId,
        'seller_name': profile?['username'] ?? displayName,
        'username': profile?['username'],
        'avatar_url': profile?['avatar_url'],
        'media_url': draft.mediaUrl,
        'thumbnail_url': draft.thumbnailUrl, // ✅ On récupère la miniature du brouillon
        'is_video': draft.isVideo,
        'description': draft.description,
        'created_at': DateTime.now().toIso8601String(),
        'likes': 0,
      });

      // 3. Supprimer le brouillon
      await supabase.from('drafts').delete().eq('id', draft.id);

      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Publié avec succès !")));
      _loadDrafts();
      _loadPublications();
    } catch (e) {
      debugPrint("Erreur publication: $e");
    } finally {
      setState(() => loading = false);
    }
  }
  // ===========================
  // UI
  // ===========================
 @override
Widget build(BuildContext context) {
  return FutureBuilder<Map<String, dynamic>>(
    future: _fetchUserProfile(),
    builder: (context, snapshot) {
      if (!snapshot.hasData) {
        return const Scaffold(
          body: Center(child: CircularProgressIndicator()),
        );
      }

      final userData = snapshot.data!;
      final bool isSeller = userData['is_seller'] == true;

      return Scaffold(
        appBar: AppBar(
          actions: [
            IconButton(
              icon: const Icon(Icons.more_vert),
              onPressed: () {
                showModalBottomSheet(
                  context: context,
                  shape: const RoundedRectangleBorder(
                    borderRadius:
                        BorderRadius.vertical(top: Radius.circular(20)),
                  ),
                  builder: (_) => const PrivateProfileMenu(),
                );
              },
            ),
          ],
        ),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            /// 🔹 AVATAR
            Center(
              child: Stack(
                children: [
                  GestureDetector(
                    onTap: () {
                      final photoUrl =
                          _avatarUrlUI ?? userData['photo_url'];
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => AvatarFullScreenPage(
                            photoUrl: photoUrl,
                            onDelete: _deleteAvatar,
                          ),
                        ),
                      );
                    },
                    child: CircleAvatar(
                      radius: 55,
                      backgroundImage: (userData['photo_url'] != null)
                          ? NetworkImage(
                              _avatarUrlUI ?? userData['photo_url'],
                            )
                          : const AssetImage("assets/images/avatar.png")
                              as ImageProvider,
                    ),
                  ),
                  Positioned(
                    bottom: 0,
                    right: 0,
                    child: GestureDetector(
                      onTap: _showAvatarOptionsSheet,
                      child: Container(
                        width: 28,
                        height: 28,
                        decoration: BoxDecoration(
                          color: Colors.black,
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white, width: 2),
                        ),
                        child: const Icon(
                          Icons.add,
                          color: Colors.white,
                          size: 16,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 12),

            /// 🔹 NOM (capsule)
            Center(
              child: GestureDetector(
                onTap: _editDisplayName,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.05),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        () {
                          final display =
                              (userData['display_name'] as String?)?.trim();
                          if (display != null && display.isNotEmpty) {
                            return display;
                          }
                          return "+ Ajouter un nom";
                        }(),
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: (userData['display_name'] as String?)
                                      ?.trim()
                                      .isNotEmpty ==
                                  true
                              ? Colors.black
                              : Colors.black54,
                        ),
                      ),
                      const SizedBox(width: 8),
                      const Icon(Icons.chevron_right,
                          size: 18, color: Colors.black54),
                      const SizedBox(width: 2),
                      const Icon(Icons.edit,
                          size: 16, color: Colors.black54),
                    ],
                  ),
                ),
              ),
            ),

            const SizedBox(height: 6),

            /// 🔹 EMAIL (petit gris)
            Center(
              child: Text(
                userData['email'] ?? "",
                style: const TextStyle(
                  fontSize: 12,
                  color: Colors.black54,
                ),
              ),
            ),

            const SizedBox(height: 6),

            /// 🔹 BIO (capsule)
            Center(
              child: GestureDetector(
                onTap: _editBio,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.05),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    () {
                      final bioText =
                          (userData['bio'] as String?)?.trim() ?? "";
                      if (bioText.isNotEmpty) {
                        return "Mon activité est $bioText";
                      }
                      return "+ Ajouter une bio";
                    }(),
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      color: (userData['bio'] as String?)?.trim().isNotEmpty ==
                              true
                          ? Colors.black87
                          : Colors.black54,
                    ),
                  ),
                ),
              ),
            ),

            const SizedBox(height: 20),

            /// 🔹 STATS
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _stat("Abonnés", followersCount),
                const SizedBox(width: 30),
                _stat("Suivis", followingCount),
                const SizedBox(width: 30),
                _stat("Vues", creatorViews),
                const SizedBox(width: 30),
                _stat("Likes", creatorLikes),
              ],
            ),

            const SizedBox(height: 20),

            /// 🔥 LE POINT CLÉ
            if (!isSeller)
              ElevatedButton.icon(
                icon: const Icon(Icons.store),
                label: const Text("Activer Vendre"),
                onPressed: _activateSellerFlow,
              )
            else
              _sellerPanel(),

            if (false) ...[
              const SizedBox(height: 20),
              const Text(
                "Brouillons",
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              ...localDrafts.map((d) {
                final typeLabel = d.isVideo ? "Vidéo" : "Image";
                final created = d.createdAt;
                final createdText =
                    "${created.day}/${created.month}/${created.year}";
                final hasLocalThumb =
                    d.isVideo && d.thumbnailLocalPath != null;
                final stateName = d.state.name;
                final isUploading = stateName == "uploading";
                final isPublished = stateName == "published";
                final isFailed = stateName == "failed";
                final isQueued = stateName == "queued";
                final canPublish = !isUploading && !isPublished;
                final errorText =
                    (isFailed && (d.errorMessage?.isNotEmpty ?? false))
                        ? "Erreur: ${d.errorMessage}"
                        : null;
                return Card(
                  child: ListTile(
                    leading: hasLocalThumb
                        ? Image.file(
                            File(d.thumbnailLocalPath!),
                            width: 56,
                            height: 56,
                            fit: BoxFit.cover,
                          )
                        : Icon(d.isVideo ? Icons.videocam : Icons.image),
                    title: Text(
                      d.description.isNotEmpty ? d.description : "Sans description",
                    ),
                    subtitle: Text(
                      errorText == null
                          ? "$typeLabel • $createdText"
                          : "$typeLabel • $createdText\n$errorText",
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _buildDraftStateBadge(
                          stateName: stateName,
                          isUploading: isUploading,
                          isFailed: isFailed,
                          isPublished: isPublished,
                          isQueued: isQueued,
                        ),
                        const SizedBox(width: 8),
                        TextButton(
                          onPressed: (!canPublish ||
                                  _publishingDraftIds.contains(d.id))
                              ? null
                              : () async {
                                  if (_isOffline) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      const SnackBar(
                                        content: Text(
                                          "Publication en attente de connexion",
                                        ),
                                      ),
                                    );
                                    return;
                                  }
                                  setState(() {
                                    _publishingDraftIds.add(d.id);
                                  });
                                  try {
                                    final result =
                                        await DraftOfflineManager.publishDraft(
                                            draft: d);
                                    if (result.success) {
                                      if (mounted) setState(() {});
                                    } else if (mounted) {
                                      ScaffoldMessenger.of(context).showSnackBar(
                                        SnackBar(
                                          content: Text(
                                            result.errorMessage ??
                                                "Échec publication",
                                          ),
                                        ),
                                      );
                                    }
                                  } finally {
                                    if (mounted) {
                                      setState(() {
                                        _publishingDraftIds.remove(d.id);
                                      });
                                    }
                                  }
                                },
                          child: _publishingDraftIds.contains(d.id) ||
                                  isUploading
                              ? const Text("Envoi...")
                              : Text(
                                  _isOffline
                                      ? "Mettre en file"
                                      : (isFailed ? "Réessayer" : "Publier"),
                                ),
                        ),
                      ],
                    ),
                    onLongPress: () async {
                      final confirm = await showDialog<bool>(
                        context: context,
                        builder: (_) => AlertDialog(
                          title: const Text("Supprimer ce brouillon ?"),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(context, false),
                              child: const Text("Annuler"),
                            ),
                            ElevatedButton(
                              onPressed: () => Navigator.pop(context, true),
                              child: const Text("Supprimer"),
                            ),
                          ],
                        ),
                      );

                      if (confirm == true) {
                        DraftLocalStore().deleteWithFiles(d);
                        if (mounted) setState(() {});
                      }
                    },
                  ),
                );
              }).toList(),
            ],

            const SizedBox(height: 40),
          ],
        ),
      );
    },
  );
}


  Widget _stat(String title, int value) {
    return Column(children: [
      Text("$value",
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
      Text(title)
    ]);
  }

  Widget _buildDraftStateBadge({
    required String stateName,
    required bool isUploading,
    required bool isFailed,
    required bool isPublished,
    required bool isQueued,
  }) {
    String label = stateName;
    Color bg = Colors.grey.shade300;
    Color fg = Colors.black87;

    if (isUploading) {
      label = "Envoi...";
      bg = Colors.orange.shade200;
    } else if (isFailed) {
      label = "Échec";
      bg = Colors.red.shade200;
    } else if (isPublished) {
      label = "Publié";
      bg = Colors.green.shade200;
    } else if (isQueued) {
      label = "En attente";
      bg = Colors.grey.shade300;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        label,
        style: TextStyle(fontSize: 12, color: fg),
      ),
    );
  }

  Widget _sellerPanel() {
    return SizedBox(
      height: 450,
      child: DefaultTabController(
        length: 2,
        child: Column(children: [
          Container(
            decoration: BoxDecoration(
                color: Colors.grey.shade200,
                borderRadius: BorderRadius.circular(10)),
            child: const TabBar(
                labelColor: Colors.deepPurple,
                unselectedLabelColor: Colors.black54,
                indicatorColor: Colors.deepPurple,
                tabs: [
                  Tab(text: "Publications"),
                  Tab(text: "Brouillons"),
                ]),
          ),
          Expanded(
              child: TabBarView(children: [
            _buildPublicationsList(context),
            _buildDraftsList()
          ])),
        ]),
      ),
    );
  }

 Widget _buildPublicationsList(BuildContext context) {
  if (products.isEmpty) {
    return const Center(child: Text("Aucune publication"));
  }

  return GridView.builder(
    padding: const EdgeInsets.all(6),
    gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
      crossAxisCount: 3,
      crossAxisSpacing: 6,
      mainAxisSpacing: 6,
      childAspectRatio: 1,
    ),
    itemCount: products.length,
    itemBuilder: (context, i) {
      final p = products[i];
      final String displayUrl = p.isVideo
          ? ((p.thumbnailUrl != null && p.thumbnailUrl!.isNotEmpty)
              ? resolveMediaUrl(p.thumbnailUrl!)
              : resolveMediaUrl(p.mediaUrl))
          : resolveMediaUrl(p.mediaUrl);

      return GestureDetector(
        onTap: () async {
          final refreshed = await Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => MediaViewerPage(
                posts: products,
                initialIndex: i,
              ),
            ),
          );

          if (refreshed == true) {
            _loadPublications();
          }
        },
        child: ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: Stack(
            children: [
              Positioned.fill(
                child: displayUrl.isNotEmpty
                    ? CachedNetworkImage(
                        imageUrl: displayUrl,
                        fit: BoxFit.cover,
                        placeholder: (context, url) =>
                            Container(color: Colors.grey[200]),
                        errorWidget: (context, url, error) => Container(
                          color: Colors.black,
                          child: const Icon(Icons.image_not_supported,
                              color: Colors.white, size: 28),
                        ),
                      )
                    : Container(
                        color: Colors.black,
                        child: const Icon(Icons.image_not_supported,
                            color: Colors.white, size: 28),
                      ),
              ),
              if (p.isVideo)
                const Positioned(
                  bottom: 6,
                  right: 6,
                  child: Icon(Icons.play_arrow,
                      color: Colors.white, size: 22),
                ),
            ],
          ),
        ),
      );
    },
  );
}

  Widget _buildDraftsList() {
    if (localDrafts.isEmpty) {
      return const Center(child: Text("Aucun brouillon"));
    }

    return GridView.builder(
      padding: const EdgeInsets.all(8),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        crossAxisSpacing: 8,
        mainAxisSpacing: 8,
        childAspectRatio: 0.7,
      ),
      itemCount: localDrafts.length,
      itemBuilder: (context, i) {
        final d = localDrafts[i];
        final thumbPath = d.thumbnailLocalPath;
        final showThumb =
            d.isVideo && thumbPath != null && isLocalMediaPath(thumbPath);
        final showImage = !d.isVideo && isLocalMediaPath(d.mediaLocalPath);

        return GestureDetector(
          onTap: () async {
            final refreshed = await Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => LocalDraftPreviewPage(draft: d),
              ),
            );

            if (refreshed == true) {
              _loadDrafts();
              _loadPublications();
            }
          },
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: Stack(
              children: [
                Positioned.fill(
                  child: showThumb
                      ? Image.file(
                          File(thumbPath!),
                          fit: BoxFit.cover,
                        )
                      : showImage
                          ? Image.file(
                              File(d.mediaLocalPath),
                              fit: BoxFit.cover,
                            )
                          : Container(
                              color: Colors.black,
                              child: const Icon(Icons.image_not_supported,
                                  color: Colors.white, size: 28),
                            ),
                ),

                if (d.isVideo)
                  const Positioned(
                    bottom: 6,
                    right: 6,
                    child: Icon(
                      Icons.videocam,
                      color: Colors.white,
                      size: 20,
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class LocalDraftPreviewPage extends StatefulWidget {
  final DraftLocalModel draft;

  const LocalDraftPreviewPage({super.key, required this.draft});

  @override
  State<LocalDraftPreviewPage> createState() => _LocalDraftPreviewPageState();
}

class _LocalDraftPreviewPageState extends State<LocalDraftPreviewPage> {
  VideoPlayerController? _controller;
  bool _publishing = false;
  bool _deleting = false;

  @override
  void initState() {
    super.initState();
    if (widget.draft.isVideo) {
      _controller = createVideoController(widget.draft.mediaLocalPath)
        ..initialize().then((_) {
          if (!mounted) return;
          _controller!
            ..setLooping(true)
            ..play();
          setState(() {});
        });
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  Future<void> _publish() async {
    setState(() => _publishing = true);
    final result = await DraftOfflineManager.publishDraft(draft: widget.draft);
    if (!mounted) return;
    setState(() => _publishing = false);
    if (result.success) {
      Navigator.pop(context, true);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(result.errorMessage ?? "Échec publication"),
        ),
      );
    }
  }

  Future<void> _deleteDraft() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text("Supprimer ?"),
        content: const Text("Supprimer ce brouillon ?"),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text("Annuler"),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text("Supprimer"),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    setState(() => _deleting = true);
    try {
      DraftLocalStore().deleteWithFiles(widget.draft);
      if (mounted) Navigator.pop(context, true);
    } finally {
      if (mounted) setState(() => _deleting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final canPublish = widget.draft.state == DraftState.localOnly ||
        widget.draft.state == DraftState.queued ||
        widget.draft.state == DraftState.failed;
    final isUploading = widget.draft.state == DraftState.uploading;
    final isFailed = widget.draft.state == DraftState.failed;

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        iconTheme: const IconThemeData(color: Colors.white),
        actions: [
          IconButton(
            icon: _deleting
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      color: Colors.white,
                      strokeWidth: 2,
                    ),
                  )
                : const Icon(Icons.delete, color: Colors.white),
            onPressed: _deleting ? null : _deleteDraft,
          ),
          TextButton(
            onPressed: (!canPublish || _publishing || isUploading)
                ? null
                : _publish,
            child: _publishing || isUploading
                ? const Text(
                    "Envoi...",
                    style: TextStyle(color: Colors.white70),
                  )
                : Text(
                    isFailed ? "Réessayer" : "Publier",
                    style: const TextStyle(color: Colors.greenAccent),
                  ),
          ),
        ],
      ),
      body: Center(
        child: widget.draft.isVideo
            ? Stack(
                alignment: Alignment.center,
                children: [
                  if (_controller == null ||
                      !_controller!.value.isInitialized)
                    (widget.draft.thumbnailLocalPath != null
                            && File(widget.draft.thumbnailLocalPath!).existsSync())
                        ? Image.file(
                            File(widget.draft.thumbnailLocalPath!),
                            fit: BoxFit.cover,
                          )
                        : const CircularProgressIndicator(color: Colors.white)
                  else
                    GestureDetector(
                      onTap: () {
                        if (_controller!.value.isPlaying) {
                          _controller!.pause();
                        } else {
                          _controller!.play();
                        }
                        setState(() {});
                      },
                      child: AspectRatio(
                        aspectRatio: _controller!.value.aspectRatio,
                        child: VideoPlayer(_controller!),
                      ),
                    ),
                  if (_controller != null && _controller!.value.isInitialized)
                    Positioned(
                      bottom: 20,
                      left: 16,
                      right: 16,
                      child: VideoProgressIndicator(
                        _controller!,
                        allowScrubbing: true,
                        colors: const VideoProgressColors(
                          playedColor: Colors.white,
                          bufferedColor: Colors.white38,
                          backgroundColor: Colors.white24,
                        ),
                      ),
                    ),
                ],
              )
            : isLocalMediaPath(widget.draft.mediaLocalPath)
                ? Image.file(
                    File(widget.draft.mediaLocalPath),
                    fit: BoxFit.contain,
                  )
                : Image.network(
                    resolveMediaUrl(widget.draft.mediaLocalPath),
                    fit: BoxFit.contain,
                  ),
      ),
    );
  }
}

class AvatarFullScreenPage extends StatelessWidget {
  final String? photoUrl;
  final Future<void> Function() onDelete;

  const AvatarFullScreenPage({
    super.key,
    required this.photoUrl,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final hasAvatar = photoUrl != null && photoUrl!.trim().isNotEmpty;

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        iconTheme: const IconThemeData(color: Colors.white),
        actions: [
          if (hasAvatar)
            IconButton(
              icon: const Icon(Icons.delete, color: Colors.white),
              onPressed: () async {
                final confirm = await showDialog<bool>(
                  context: context,
                  builder: (_) => AlertDialog(
                    title: const Text("Supprimer la photo ?"),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(context, false),
                        child: const Text("Annuler"),
                      ),
                      ElevatedButton(
                        onPressed: () => Navigator.pop(context, true),
                        child: const Text("Supprimer"),
                      ),
                    ],
                  ),
                );

                if (confirm == true) {
                  await onDelete();
                  if (context.mounted) Navigator.pop(context);
                }
              },
            ),
        ],
      ),
      body: Center(
        child: InteractiveViewer(
          child: hasAvatar
              ? Image.network(photoUrl!, fit: BoxFit.contain)
              : Image.asset("assets/images/avatar.png", fit: BoxFit.contain),
        ),
      ),
    );
  }
}
