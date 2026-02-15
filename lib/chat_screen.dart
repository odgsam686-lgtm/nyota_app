import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:nyota_app/widgets/nyota_background.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:nyota_app/pages/public_profile_page.dart';
import 'package:uuid/uuid.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:video_player/video_player.dart';
import 'package:nyota_app/services/video_thumbnail_service.dart';

final ScrollController _scrollController = ScrollController();

class ChatScreen extends StatefulWidget {
  final String conversationId;
  final String receiverId;
  final String currentUserId;
  final String? initialDisplayName;
  final String? initialPhotoUrl;

  const ChatScreen({
    super.key,
    required this.conversationId,
    required this.receiverId,
    required this.currentUserId,
    this.initialDisplayName,
    this.initialPhotoUrl,
  });

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final supabase = Supabase.instance.client;
  final TextEditingController _controller = TextEditingController();
  late final String currentUserId;
  int _lastMessageCount = 0;
  final List<Map<String, dynamic>> _localMessages = [];
  static final Map<String, Map<String, dynamic>> _profileCache = {};
  final Uuid _uuid = const Uuid();
  static const String _mediaBucket = 'posts';
  bool _sending = false;
  DateTime? _lastSendAt;
  String? _receiverDisplayName;
  String? _receiverPhotoUrl;
  Timer? _draftTimer;
  final ImagePicker _picker = ImagePicker();
  File? _pendingMediaFile;
  bool _pendingIsVideo = false;
  VideoPlayerController? _pendingVideoController;
  bool _pickingMedia = false;
  String _pendingText = '';

  @override
  void initState() {
    super.initState();
    currentUserId = FirebaseAuth.instance.currentUser!.uid;
    _receiverDisplayName =
        widget.initialDisplayName?.trim().isNotEmpty == true
            ? widget.initialDisplayName
            : null;
    _receiverPhotoUrl = widget.initialPhotoUrl?.trim().isNotEmpty == true
        ? widget.initialPhotoUrl
        : null;
    final cached = _profileCache[widget.receiverId];
    if (cached != null) {
      _receiverDisplayName ??= cached['name']?.toString().trim();
      _receiverPhotoUrl ??= cached['photo']?.toString().trim();
    }
    _markMessagesAsRead();
    _loadReceiverInfo();
    _loadDraft();
  }

  String get _draftKey =>
      "chat_draft_${widget.conversationId}_$currentUserId";

  Future<void> _loadDraft() async {
    if (!mounted) return;
    final prefs = await SharedPreferences.getInstance();
    final draft = prefs.getString(_draftKey);
    if (!mounted) return;
    if (draft != null && draft.isNotEmpty) {
      _setControllerText(draft);
    }
  }

  void _setControllerText(String text) {
    _controller.value = _controller.value.copyWith(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
    _pendingText = text;
  }

  void _onDraftChanged(String value) {
    _draftTimer?.cancel();
    _draftTimer = Timer(const Duration(milliseconds: 400), () async {
      final prefs = await SharedPreferences.getInstance();
      final trimmed = value.trim();
      if (trimmed.isEmpty) {
        await prefs.remove(_draftKey);
      } else {
        await prefs.setString(_draftKey, value);
      }
    });
  }

  Future<void> _clearDraft() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_draftKey);
  }

  Future<void> _openAttachSheet() async {
    if (_pickingMedia) return;
    await showModalBottomSheet(
      context: context,
      showDragHandle: true,
      isScrollControlled: false,
      builder: (ctx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.photo),
                title: const Text("Galerie (Image)"),
                onTap: () async {
                  Navigator.pop(ctx);
                  await Future.delayed(const Duration(milliseconds: 200));
                  await _pickMedia(source: ImageSource.gallery, isVideo: false);
                },
              ),
              ListTile(
                leading: const Icon(Icons.video_library),
                title: const Text("Galerie (Vidéo)"),
                onTap: () async {
                  Navigator.pop(ctx);
                  await Future.delayed(const Duration(milliseconds: 200));
                  await _pickMedia(source: ImageSource.gallery, isVideo: true);
                },
              ),
              ListTile(
                leading: const Icon(Icons.photo_camera),
                title: const Text("Caméra (Image)"),
                onTap: () async {
                  Navigator.pop(ctx);
                  await Future.delayed(const Duration(milliseconds: 200));
                  await _pickMedia(source: ImageSource.camera, isVideo: false);
                },
              ),
              ListTile(
                leading: const Icon(Icons.videocam),
                title: const Text("Caméra (Vidéo)"),
                onTap: () async {
                  Navigator.pop(ctx);
                  await Future.delayed(const Duration(milliseconds: 200));
                  await _pickMedia(source: ImageSource.camera, isVideo: true);
                },
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _pickMedia({
    required ImageSource source,
    required bool isVideo,
  }) async {
    if (_pickingMedia) return;
    if (mounted) setState(() => _pickingMedia = true);
    try {
      final XFile? picked = isVideo
          ? await _picker.pickVideo(source: source)
          : await _picker.pickImage(
              source: source,
              imageQuality: 70,
              maxWidth: 1024,
            );
      if (picked == null) return;
      final tempFile = await _copyToTempFile(picked);
      if (!mounted) return;
      await _setPendingMedia(tempFile, isVideo: isVideo);
    } catch (e) {
      debugPrint("pick media error: $e");
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Erreur sélection média: $e")),
        );
      }
    } finally {
      if (mounted) setState(() => _pickingMedia = false);
    }
  }

  Future<File> _copyToTempFile(XFile picked) async {
    final tempDir = await getTemporaryDirectory();
    final ext = _fileExtension(picked.path);
    final name = "chat_${DateTime.now().millisecondsSinceEpoch}.$ext";
    final tempPath = "${tempDir.path}/$name";
    return File(picked.path).copy(tempPath);
  }

  Future<void> _setPendingMedia(File file, {required bool isVideo}) async {
    _clearPendingMedia();
    if (mounted) {
      setState(() {
        _pendingMediaFile = file;
        _pendingIsVideo = isVideo;
      });
    }
    if (isVideo) {
      final controller = VideoPlayerController.file(file);
      await controller.initialize();
      controller.setLooping(true);
      if (!mounted) {
        controller.dispose();
        return;
      }
      _pendingVideoController?.dispose();
      _pendingVideoController = controller;
      setState(() {});
    }
  }

  void _clearPendingMedia() {
    _pendingVideoController?.dispose();
    _pendingVideoController = null;
    _pendingMediaFile = null;
    _pendingIsVideo = false;
  }

  void _updateLocalMessage(String clientId, Map<String, dynamic> patch) {
    final idx = _localMessages.indexWhere(
        (m) => m['client_id']?.toString() == clientId);
    if (idx == -1) return;
    setState(() {
      _localMessages[idx] = {
        ..._localMessages[idx],
        ...patch,
      };
    });
  }

  Future<void> _retryUpload(Map<String, dynamic> msg) async {
    final clientId = msg['client_id']?.toString();
    final localPath = msg['media_local_path']?.toString();
    if (clientId == null || localPath == null || localPath.isEmpty) return;
    final file = File(localPath);
    if (!file.existsSync()) return;
    final isVideo = msg['message_type']?.toString() == 'video';
    _updateLocalMessage(clientId, {'upload_status': 'uploading'});
    try {
      final uploaded = await _uploadMediaFile(file, isVideo, clientId);
      final mediaUrl = uploaded['mediaUrl'];
      final thumbUrl = uploaded['thumbUrl'];

      await supabase.from('messages').upsert(
        {
          'client_id': clientId,
          'conversation_id': widget.conversationId,
          'sender_id': currentUserId,
          'receiver_id': widget.receiverId,
          'content': msg['content'] ?? '',
          'message_type': isVideo ? 'video' : 'image',
          'media_url': mediaUrl,
          'thumbnail_url': thumbUrl,
          'is_read': false,
        },
        onConflict: 'conversation_id,client_id',
        ignoreDuplicates: true,
      );

      _updateLocalMessage(clientId, {
        'media_url': mediaUrl,
        'thumbnail_url': thumbUrl,
        'upload_status': 'done',
      });
    } catch (e) {
      debugPrint("retry upload error: $e");
      _updateLocalMessage(clientId, {'upload_status': 'failed'});
    }
  }

  String _fileExtension(String path) {
    final dot = path.lastIndexOf('.');
    if (dot == -1) return 'bin';
    return path.substring(dot + 1).toLowerCase();
  }

  String? _contentTypeFor(String ext, bool isVideo) {
    if (isVideo) {
      if (ext == 'mov') return 'video/quicktime';
      if (ext == 'mkv') return 'video/x-matroska';
      if (ext == 'webm') return 'video/webm';
      return 'video/mp4';
    } else {
      if (ext == 'jpg' || ext == 'jpeg') return 'image/jpeg';
      if (ext == 'png') return 'image/png';
      if (ext == 'webp') return 'image/webp';
    }
    return null;
  }

  Future<Map<String, String?>> _uploadMediaFile(
    File file,
    bool isVideo,
    String clientId,
  ) async {
    final ext = _fileExtension(file.path);
    final objectPath =
        "messages/${widget.conversationId}/$clientId.$ext";
    debugPrint("CHAT UPLOAD bucket=$_mediaBucket path=$objectPath");
    final contentType = _contentTypeFor(ext, isVideo);
    await supabase.storage.from(_mediaBucket).upload(
          objectPath,
          file,
          fileOptions: FileOptions(
            upsert: true,
            contentType: contentType,
          ),
        );
    final mediaUrl = supabase.storage.from(_mediaBucket).getPublicUrl(objectPath);
    String? thumbUrl;
    if (isVideo) {
      thumbUrl = await VideoThumbnailService.generateAndUpload(
        videoFile: file,
        userId: currentUserId,
      );
    }
    return {
      'mediaUrl': mediaUrl,
      'thumbUrl': thumbUrl,
    };
  }

  Widget _buildPendingPreview() {
    if (_pendingMediaFile == null) return const SizedBox.shrink();
    final file = _pendingMediaFile!;
    final isVideo = _pendingIsVideo;
    final maxWidth = MediaQuery.of(context).size.width * 0.7;
    return SizedBox(
      width: maxWidth,
      height: 140,
      child: Stack(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: Container(
              color: Colors.black12,
              child: isVideo
                  ? (_pendingVideoController != null &&
                          _pendingVideoController!.value.isInitialized)
                      ? Stack(
                          alignment: Alignment.center,
                            children: [
                              VideoPlayer(_pendingVideoController!),
                              const Icon(
                                Icons.play_circle_fill,
                                color: Colors.white70,
                                size: 40,
                              ),
                            ],
                          )
                      : const Center(
                          child: SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        )
                  : Image.file(
                      file,
                      fit: BoxFit.cover,
                    ),
            ),
          ),
          Positioned(
            top: 6,
            right: 6,
            child: InkWell(
              onTap: () {
                setState(() {
                  _clearPendingMedia();
                });
              },
              child: const CircleAvatar(
                radius: 12,
                backgroundColor: Colors.black54,
                child: Icon(Icons.close, size: 14, color: Colors.white),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<Map<String, dynamic>?> _fetchUserProfile(String userId) async {
    if (_profileCache.containsKey(userId)) {
      return _profileCache[userId];
    }
    try {
      final publicProfile = await supabase
          .from('public_profiles')
          .select()
          .eq('user_id', userId)
          .maybeSingle();

      if (publicProfile == null) {
        debugPrint("PROFILE NULL for user=$userId");
        final fallback = await supabase
            .from('users')
            .select('display_name, username, photo_url')
            .eq('firebase_uid', userId)
            .maybeSingle();
        if (fallback != null) {
          final normalized = {
            'name': (fallback['display_name']?.toString().trim().isNotEmpty ==
                    true)
                ? fallback['display_name']
                : (fallback['username']?.toString().trim().isNotEmpty == true)
                    ? fallback['username']
                    : 'Utilisateur',
            'photo': (fallback['photo_url']?.toString().trim().isNotEmpty ==
                    true)
                ? fallback['photo_url']
                : null,
          };
          _profileCache[userId] = normalized;
          return normalized;
        }
        return null;
      }

      final displayName = publicProfile['display_name'] ??
          publicProfile['displayname'];
      final username = publicProfile['username'];
      final avatarUrl = publicProfile['avatar_url'] ??
          publicProfile['photo_url'];

      final normalized = {
        'name': (displayName?.toString().trim().isNotEmpty == true)
            ? displayName
            : (username?.toString().trim().isNotEmpty == true)
                ? username
                : 'Utilisateur',
        'photo': (avatarUrl?.toString().trim().isNotEmpty == true)
            ? avatarUrl
            : null,
      };
      _profileCache[userId] = normalized;
      return normalized;
    } catch (e) {
      debugPrint("load receiver info error: $e");
      return null;
    }
  }

  Future<void> _loadReceiverInfo() async {
    try {
      final data = await _fetchUserProfile(widget.receiverId);
      if (!mounted) return;
      setState(() {
        _receiverDisplayName = data?['name']?.toString().trim();
        _receiverPhotoUrl = data?['photo']?.toString().trim();
      });
    } catch (e) {
      debugPrint("load receiver info error: $e");
    }
  }

  void _openPublicProfile() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => PublicProfilePage(sellerId: widget.receiverId),
      ),
    );
  }

  @override
  void dispose() {
    _draftTimer?.cancel();
    _pendingVideoController?.dispose();
    _setTyping(false);
    super.dispose();
  }

  Future<void> _markMessagesAsRead() async {
    await supabase
        .from('messages')
        .update({
          'is_read': true,
          'read_at': DateTime.now().toIso8601String(),
        })
        .eq('conversation_id', widget.conversationId)
        .neq('sender_id', currentUserId)
        .eq('is_read', false);
    await _touchConversationRead();
  }

  Future<void> _touchConversationRead() async {
    try {
      debugPrint(
          "READ UPSERT conversation_id=${widget.conversationId} user_id=$currentUserId");
      await supabase.from('conversation_reads').upsert({
        'conversation_id': widget.conversationId,
        'user_id': currentUserId,
        'last_read_at': DateTime.now().toIso8601String(),
      }, onConflict: 'conversation_id,user_id');
    } catch (e) {
      debugPrint("conversation_reads upsert error: $e");
    }
  }

  Future<void> _setTyping(bool typing) async {
    await supabase.from('conversations').update({
      'typing_user_id': typing ? currentUserId : null,
    }).eq('id', widget.conversationId);
  }

  Stream<String?> _typingStream() {
    return supabase
        .from('conversations')
        .stream(primaryKey: ['id'])
        .eq('id', widget.conversationId)
        .map((rows) => rows.isEmpty ? null : rows.first['typing_user_id']);
  }

  Stream<List<Map<String, dynamic>>> _messagesStream() {
    return supabase
        .from('messages')
        .stream(primaryKey: ['id'])
        .eq('conversation_id', widget.conversationId)
        .order('created_at', ascending: true) // ✅ ORDRE NORMAL
        .map((rows) => List<Map<String, dynamic>>.from(rows));
  }

  Future<void> _sendMessage() async {
    final text = _controller.text.trim();
    final hasMedia = _pendingMediaFile != null;
    if (text.isEmpty && !hasMedia) return;
    if (_sending) return;
    final now = DateTime.now();
    if (_lastSendAt != null &&
        now.difference(_lastSendAt!) < const Duration(milliseconds: 350)) {
      return;
    }
    _lastSendAt = now;
    setState(() => _sending = true);
    debugPrint("sendMessage called");

    final clientId = _uuid.v4();
    final messageType = hasMedia
        ? (_pendingIsVideo ? 'video' : 'image')
        : 'text';
    final caption = text;
    final pendingFile = _pendingMediaFile;
    final pendingIsVideo = _pendingIsVideo;
    final tempMessage = {
      'id': 'local_${DateTime.now().millisecondsSinceEpoch}',
      'client_id': clientId,
      'conversation_id': widget.conversationId,
      'sender_id': currentUserId,
      'receiver_id': widget.receiverId,
      'content': caption,
      'message_type': messageType,
      'media_local_path': hasMedia ? pendingFile!.path : null,
      'upload_status': hasMedia ? 'uploading' : 'sent',
      'created_at': DateTime.now().toIso8601String(),
      'is_read': false,
      'is_local': true, // 👈 IMPORTANT
    };

    setState(() {
      _localMessages.add(tempMessage);
      _controller.clear();
      _pendingText = '';
      _clearPendingMedia();
    });
    _scrollToBottom();

    try {
      String? mediaUrl;
      String? thumbUrl;
      if (hasMedia) {
        final uploaded =
            await _uploadMediaFile(pendingFile!, pendingIsVideo, clientId);
        mediaUrl = uploaded['mediaUrl'];
        thumbUrl = uploaded['thumbUrl'];
      }

      await supabase.from('messages').upsert(
        {
          'client_id': clientId,
          'conversation_id': widget.conversationId,
          'sender_id': currentUserId,
          'receiver_id': widget.receiverId,
          'content': caption,
          'message_type': messageType,
          'media_url': mediaUrl,
          'thumbnail_url': thumbUrl,
          'is_read': false,
        },
        onConflict: 'conversation_id,client_id',
        ignoreDuplicates: true,
      );

      await supabase.from('conversations').update({
        'last_message': caption.isNotEmpty
            ? caption
            : (messageType == 'image' ? 'Photo' : messageType == 'video' ? 'Vidéo' : ''),
        'updated_at': DateTime.now().toIso8601String(),
      }).eq('id', widget.conversationId);
      await _clearDraft();
      if (hasMedia) {
        _updateLocalMessage(clientId, {
          'media_url': mediaUrl,
          'thumbnail_url': thumbUrl,
          'upload_status': 'done',
        });
      }
    } catch (e) {
      debugPrint("sendMessage error: $e");
      if (hasMedia) {
        _updateLocalMessage(clientId, {'upload_status': 'failed'});
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Échec envoi du message: $e")),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _sending = false);
      }
    }
  }

  void _scrollToBottom() {
    if (_scrollController.hasClients) {
      _scrollController.jumpTo(
        _scrollController.position.maxScrollExtent,
      );
    }
  }

  String _formatTime(String iso) {
    final d = DateTime.parse(iso);
    return "${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}";
  }

  String _formatDate(DateTime d) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final yesterday = today.subtract(const Duration(days: 1));
    final date = DateTime(d.year, d.month, d.day);

    if (date == today) return "Aujourd’hui";
    if (date == yesterday) return "Hier";
    return "${d.day}/${d.month}/${d.year}";
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent, // 👈 AJOUT
      appBar: AppBar(
        backgroundColor: Colors.white,
        toolbarHeight: 56,
        title: InkWell(
          onTap: _openPublicProfile,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircleAvatar(
                radius: 18,
                backgroundImage: (_receiverPhotoUrl != null &&
                        _receiverPhotoUrl!.isNotEmpty)
                    ? NetworkImage(_receiverPhotoUrl!)
                    : const AssetImage("assets/images/avatar.png")
                        as ImageProvider,
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  (_receiverDisplayName != null &&
                          _receiverDisplayName!.isNotEmpty)
                      ? _receiverDisplayName!
                      : "Utilisateur",
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.black),
                ),
              ),
            ],
          ),
        ),
        iconTheme: const IconThemeData(color: Colors.black),
        elevation: 1,
      ),

      body: NyotaBackground(
        child: Column(
          children: [
            Expanded(
              child: StreamBuilder<List<Map<String, dynamic>>>(
                stream: _messagesStream(),
                builder: (context, snapshot) {
                  if (!snapshot.hasData) {
                    return const Center(
                      child: CircularProgressIndicator(),
                    );
                  }
                  final serverMessages = snapshot.data!;
                  final serverClientIds = serverMessages
                      .map((m) => m['client_id'])
                      .where((v) => v != null)
                      .map((v) => v.toString())
                      .toSet();

                  _localMessages.removeWhere((local) {
                    final cid = local['client_id']?.toString();
                    if (cid != null && serverClientIds.contains(cid)) {
                      return true;
                    }
                    // fallback: si pas de client_id côté serveur, déduire par contenu/temps
                    final localContent = local['content']?.toString();
                    final localSender = local['sender_id']?.toString();
                    final localCreated = local['created_at']?.toString();
                    if (localContent == null ||
                        localSender == null ||
                        localCreated == null) {
                      return false;
                    }
                    DateTime? localTime;
                    try {
                      localTime = DateTime.parse(localCreated);
                    } catch (_) {
                      return false;
                    }
                    return serverMessages.any((server) {
                      if (server['client_id'] != null) return false;
                      if (server['content']?.toString() != localContent) {
                        return false;
                      }
                      if (server['sender_id']?.toString() != localSender) {
                        return false;
                      }
                      final serverCreated = server['created_at']?.toString();
                      if (serverCreated == null) return false;
                      DateTime? serverTime;
                      try {
                        serverTime = DateTime.parse(serverCreated);
                      } catch (_) {
                        return false;
                      }
                      final diff =
                          (serverTime.millisecondsSinceEpoch -
                                  localTime!.millisecondsSinceEpoch)
                              .abs();
                      return diff <= 5000;
                    });
                  });

                  final Map<String, Map<String, dynamic>> byKey = {};
                  for (final msg in [...serverMessages, ..._localMessages]) {
                    final key = (msg['client_id'] ??
                            msg['id'] ??
                            "${msg['sender_id']}_${msg['created_at']}_${msg['content']}")
                        .toString();
                    byKey[key] = msg;
                  }

                  final messages = byKey.values.toList()
                    ..sort((a, b) {
                      final aDate = DateTime.parse(a['created_at']);
                      final bDate = DateTime.parse(b['created_at']);
                      return aDate.compareTo(bDate);
                    });

                  DateTime? lastDate;
                  // ✅ ON MARQUE LU MAIS ON NE FORCE PLUS LE SCROLL ICI
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    _markMessagesAsRead();

                    // 🔥 Scroll SEULEMENT s'il y a un nouveau message
                    if (messages.length != _lastMessageCount) {
                      _lastMessageCount = messages.length;

                      if (_scrollController.hasClients) {
                        _scrollController.animateTo(
                          _scrollController.position.maxScrollExtent,
                          duration: const Duration(milliseconds: 300),
                          curve: Curves.easeOut,
                        );
                      }
                    }
                  });

                  return ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.all(12),
                    itemCount: messages.length,
                    itemBuilder: (context, index) {
                      final msg = messages[index];
                      final isMe = msg['sender_id'] == currentUserId;
                      final msgType =
                          (msg['message_type'] ?? 'text').toString();
                      final mediaUrl = msg['media_url']?.toString();
                      final thumbnailUrl = msg['thumbnail_url']?.toString();
                      final localMediaPath =
                          msg['media_local_path']?.toString();
                      final caption = msg['content']?.toString() ?? '';
                      final uploadStatus =
                          msg['upload_status']?.toString() ?? '';
                      final bool isRead =
                          msg['is_read'] == true || msg['read_at'] != null;
                      final bool isDelivered =
                          msg['is_delivered'] == true ||
                          msg['delivered_at'] != null;
                      final date = DateTime.parse(msg['created_at']);
                      final showDate =
                          lastDate == null || lastDate!.day != date.day;
                      lastDate = date;

                      final msgKey = (msg['client_id'] ??
                              msg['id'] ??
                              "${msg['sender_id']}_${msg['created_at']}_${msg['content']}")
                          .toString();
                      final bool isMedia =
                          msgType == 'image' || msgType == 'video';
                      return Column(
                        key: ValueKey(msgKey),
                        children: [
                          if (showDate)
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 8),
                              child: Text(
                                _formatDate(date),
                                style: const TextStyle(
                                    color: Colors.grey, fontSize: 12),
                              ),
                            ),
                          Align(
                            alignment: isMe
                                ? Alignment.centerRight
                                : Alignment.centerLeft,
                            child: Column(
                              crossAxisAlignment: isMe
                                  ? CrossAxisAlignment.end
                                  : CrossAxisAlignment.start,
                              children: [
                                if (isMedia) ...[
                                  _ChatMediaBubble(
                                    isVideo: msgType == 'video',
                                    mediaUrl: mediaUrl,
                                    thumbnailUrl: thumbnailUrl,
                                    localPath: localMediaPath,
                                    uploadStatus: uploadStatus,
                                    onRetry: uploadStatus == 'failed'
                                        ? () => _retryUpload(msg)
                                        : null,
                                    onTap: () {
                                      if (msgType == 'image') {
                                        Navigator.push(
                                          context,
                                          MaterialPageRoute(
                                            builder: (_) => ChatImageViewerPage(
                                              imageUrl: mediaUrl,
                                              localPath: localMediaPath,
                                            ),
                                          ),
                                        );
                                      } else {
                                        Navigator.push(
                                          context,
                                          MaterialPageRoute(
                                            builder: (_) => ChatVideoViewerPage(
                                              videoUrl: mediaUrl,
                                              localPath: localMediaPath,
                                            ),
                                          ),
                                        );
                                      }
                                    },
                                  ),
                                  if (caption.trim().isNotEmpty)
                                    const SizedBox(height: 6),
                                ],
                                if (!isMedia || caption.trim().isNotEmpty)
                                  Container(
                                    margin:
                                        const EdgeInsets.symmetric(vertical: 4),
                                    padding: const EdgeInsets.all(12),
                                    constraints:
                                        const BoxConstraints(maxWidth: 280),
                                    decoration: BoxDecoration(
                                      color: isMe
                                          ? Colors.deepPurple
                                          : Colors.grey.shade300,
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                    child: Text(
                                      caption,
                                      style: TextStyle(
                                        color: isMe
                                            ? Colors.white
                                            : Colors.black,
                                      ),
                                    ),
                                  ),
                                const SizedBox(height: 6),
                                Row(
                                  mainAxisSize: MainAxisSize.min,
                                  mainAxisAlignment: isMe
                                      ? MainAxisAlignment.end
                                      : MainAxisAlignment.start,
                                  children: [
                                    Text(
                                      _formatTime(msg['created_at']),
                                      style: const TextStyle(
                                        fontSize: 10,
                                        color: Colors.grey,
                                      ),
                                    ),
                                    if (isMe) ...[
                                      const SizedBox(width: 6),
                                      Icon(
                                        (isRead || isDelivered)
                                            ? Icons.done_all
                                            : Icons.check,
                                        size: 14,
                                        color: isRead
                                            ? Colors.lightBlueAccent
                                            : Colors.grey,
                                      ),
                                    ],
                                  ],
                                ),
                                const SizedBox(height: 6),
                              ],
                            ),
                          ),
                        ],
                      );
                    },
                  );
                },
              ),
            ),
            StreamBuilder<String?>(
              stream: _typingStream(),
              builder: (_, snap) {
                if (snap.data != null && snap.data != currentUserId) {
                  return const Padding(
                    padding: EdgeInsets.only(left: 12, bottom: 4),
                    child: Text(
                      "L’utilisateur est en train d’écrire…",
                      style: TextStyle(fontSize: 12, color: Colors.grey),
                    ),
                  );
                }
                return const SizedBox.shrink();
              },
            ),
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                  decoration: BoxDecoration(
                    color: Colors.grey.shade100,
                    borderRadius: BorderRadius.circular(26),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (_pendingMediaFile != null) ...[
                        Padding(
                          padding: const EdgeInsets.only(bottom: 6),
                          child: _buildPendingPreview(),
                        ),
                      ],
                      Row(
                        children: [
                          SizedBox(
                            width: 36,
                            height: 36,
                            child: Material(
                              color: Colors.grey.shade200,
                              shape: const CircleBorder(),
                              child: InkWell(
                                customBorder: const CircleBorder(),
                                onTap: _openAttachSheet,
                                child: const Icon(Icons.add),
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: TextField(
                              controller: _controller,
                              onChanged: (v) {
                                _setTyping(v.isNotEmpty);
                                _onDraftChanged(v);
                                _pendingText = v;
                                setState(() {});
                              },
                              decoration: const InputDecoration(
                                hintText: "Écrire un message",
                                border: InputBorder.none,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Builder(builder: (_) {
                            final canSend = !_sending &&
                                (_controller.text.trim().isNotEmpty ||
                                    _pendingMediaFile != null);
                            return IconButton(
                              icon: Icon(
                                Icons.send,
                                color: canSend
                                    ? Colors.lightBlueAccent
                                    : Colors.grey,
                              ),
                              onPressed: canSend ? _sendMessage : null,
                            );
                          }),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ChatMediaBubble extends StatelessWidget {
  final bool isVideo;
  final String? mediaUrl;
  final String? thumbnailUrl;
  final String? localPath;
  final String uploadStatus;
  final VoidCallback? onRetry;
  final VoidCallback onTap;

  const _ChatMediaBubble({
    required this.isVideo,
    required this.mediaUrl,
    required this.thumbnailUrl,
    required this.localPath,
    required this.uploadStatus,
    this.onRetry,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final hasLocal =
        localPath != null && localPath!.isNotEmpty && File(localPath!).existsSync();
    final hasUrl = mediaUrl != null && mediaUrl!.isNotEmpty;
    final hasThumb = thumbnailUrl != null && thumbnailUrl!.isNotEmpty;
    const double bubbleWidth = 200;
    const double bubbleHeight = 140;

    Widget child;
    if (isVideo) {
      child = _ChatVideoThumbnail(
        thumbnailUrl: hasThumb ? thumbnailUrl : null,
        videoUrl: hasUrl ? mediaUrl : null,
        localPath: hasLocal ? localPath : null,
      );
    } else if (hasLocal) {
      child = Image.file(
        File(localPath!),
        fit: BoxFit.cover,
      );
    } else if (hasUrl) {
      child = Image.network(
        mediaUrl!,
        fit: BoxFit.cover,
        loadingBuilder: (context, c, progress) {
          if (progress == null) return c;
          return const Center(child: CircularProgressIndicator());
        },
      );
    } else {
      child = const Center(child: Icon(Icons.image, size: 40));
    }

    return GestureDetector(
      onTap: onTap,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: SizedBox(
          width: bubbleWidth,
          height: bubbleHeight,
          child: Stack(
            alignment: Alignment.center,
            children: [
              child,
              if (isVideo)
                const Icon(
                  Icons.play_circle_outline,
                  color: Colors.white70,
                  size: 48,
                ),
              if (uploadStatus == 'uploading')
                Container(
                  color: Colors.black38,
                  child: const Center(
                    child: SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
                ),
              if (uploadStatus == 'failed')
                Container(
                  color: Colors.black45,
                  child: Center(
                    child: IconButton(
                      icon: const Icon(Icons.refresh, color: Colors.white),
                      onPressed: onRetry,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ChatVideoThumbnail extends StatefulWidget {
  final String? thumbnailUrl;
  final String? videoUrl;
  final String? localPath;

  const _ChatVideoThumbnail({
    this.thumbnailUrl,
    this.videoUrl,
    this.localPath,
  });

  @override
  State<_ChatVideoThumbnail> createState() => _ChatVideoThumbnailState();
}

class _ChatVideoThumbnailState extends State<_ChatVideoThumbnail> {
  VideoPlayerController? _controller;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    if (widget.thumbnailUrl != null && widget.thumbnailUrl!.isNotEmpty) {
      return;
    }
    final controller = widget.localPath != null
        ? VideoPlayerController.file(File(widget.localPath!))
        : (widget.videoUrl != null
            ? VideoPlayerController.networkUrl(Uri.parse(widget.videoUrl!))
            : null);
    if (controller == null) return;
    await controller.initialize();
    controller.setLooping(true);
    if (!mounted) {
      controller.dispose();
      return;
    }
    setState(() {
      _controller = controller;
    });
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.thumbnailUrl != null && widget.thumbnailUrl!.isNotEmpty) {
      return Image.network(
        widget.thumbnailUrl!,
        fit: BoxFit.cover,
        loadingBuilder: (context, c, progress) {
          if (progress == null) return c;
          return const Center(child: CircularProgressIndicator());
        },
      );
    }
    if (_controller == null || !_controller!.value.isInitialized) {
      return const Center(child: CircularProgressIndicator());
    }
    return AspectRatio(
      aspectRatio: _controller!.value.aspectRatio,
      child: VideoPlayer(_controller!),
    );
  }
}

class ChatImageViewerPage extends StatelessWidget {
  final String? imageUrl;
  final String? localPath;

  const ChatImageViewerPage({
    super.key,
    this.imageUrl,
    this.localPath,
  });

  @override
  Widget build(BuildContext context) {
    final hasLocal =
        localPath != null && localPath!.isNotEmpty && File(localPath!).existsSync();
    final hasUrl = imageUrl != null && imageUrl!.isNotEmpty;

    Widget imageChild;
    if (hasLocal) {
      imageChild = Image.file(File(localPath!), fit: BoxFit.contain);
    } else if (hasUrl) {
      imageChild = Image.network(imageUrl!, fit: BoxFit.contain);
    } else {
      imageChild = const Center(child: Icon(Icons.image, color: Colors.white70));
    }

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: Center(
        child: InteractiveViewer(
          child: imageChild,
        ),
      ),
    );
  }
}

class ChatVideoViewerPage extends StatefulWidget {
  final String? videoUrl;
  final String? localPath;

  const ChatVideoViewerPage({
    super.key,
    this.videoUrl,
    this.localPath,
  });

  @override
  State<ChatVideoViewerPage> createState() => _ChatVideoViewerPageState();
}

class _ChatVideoViewerPageState extends State<ChatVideoViewerPage> {
  VideoPlayerController? _controller;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final controller = widget.localPath != null
        ? VideoPlayerController.file(File(widget.localPath!))
        : (widget.videoUrl != null
            ? VideoPlayerController.networkUrl(Uri.parse(widget.videoUrl!))
            : null);
    if (controller == null) return;
    await controller.initialize();
    if (!mounted) {
      controller.dispose();
      return;
    }
    setState(() {
      _controller = controller;
    });
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  void _togglePlay() {
    if (_controller == null) return;
    if (_controller!.value.isPlaying) {
      _controller!.pause();
    } else {
      _controller!.play();
    }
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: Center(
        child: _controller == null || !_controller!.value.isInitialized
            ? const CircularProgressIndicator()
            : GestureDetector(
                onTap: _togglePlay,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    AspectRatio(
                      aspectRatio: _controller!.value.aspectRatio,
                      child: VideoPlayer(_controller!),
                    ),
                    if (!_controller!.value.isPlaying)
                      const Icon(Icons.play_arrow,
                          size: 64, color: Colors.white70),
                    Positioned(
                      bottom: 12,
                      left: 12,
                      right: 12,
                      child: VideoProgressIndicator(
                        _controller!,
                        allowScrubbing: true,
                        colors: VideoProgressColors(
                          playedColor: Colors.lightBlueAccent,
                          bufferedColor: Colors.white38,
                          backgroundColor: Colors.white24,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
      ),
    );
  }
}
