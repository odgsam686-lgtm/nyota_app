// feed_page_supabase.dart
import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:nyota_app/widgets/nyota_background.dart';
import 'package:video_player/video_player.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../widgets/fullscreen_media_actions.dart';
import '../utils/media_resolver.dart';
import '../services/feed_controller.dart';
import '../services/crashlytics_logger.dart';
import 'comments_page.dart';

class FeedPage extends StatefulWidget {
  final bool isVisible;

  const FeedPage({
    super.key,
    this.isVisible = true,
  });

  @override
  State<FeedPage> createState() => _FeedPageState();
}

class _FeedPageState extends State<FeedPage> with WidgetsBindingObserver {
  final PageController _pageController = PageController();
  int currentIndex = 0;

  // Posts loaded from Supabase (paged)
  final List<Map<String, dynamic>> posts = [];
  bool isLoading = false;
  bool hasMore = true;
  final int limit = 6; // ajustable
  final FeedController _feedController = FeedController();
  final Set<String> _loadedFeedPostIds = <String>{};
  final Set<String> _impressionMarkedPostIds = <String>{};
  String? _viewerDbUserId;
  String? _viewerDbUserIdForFirebaseUid;
  Future<String?>? _viewerDbUserIdFuture;
  StreamSubscription<Position>? _userLocationSub;
  DateTime? _lastUserLocationSyncAt;
  double? _lastUserLocationLat;
  double? _lastUserLocationLng;
  bool _userLocationSyncInFlight = false;
  static const Duration _inactiveRefreshThreshold = Duration(minutes: 5);
  static DateTime? _lastFeedInactiveAt;

  // Video controllers keyed by postId (stabler que par index)
  final Map<String, VideoPlayerController> videoControllers = {};
  final Map<String, int> _videoInitEpoch = {};
  final Set<String> _videoInitInFlight = {};
  final Set<String> _videoInitFailed = {};
  final Map<String, DateTime> _videoRetryAfter = {};
  final Set<String> _loggedPosts = {};
  static const Duration _viewThreshold = Duration(seconds: 2);
  Timer? _viewTimer;
  String? _pendingViewPostId;
  final Set<String> _viewRegisteredPosts = {};
  final Set<String> _viewInFlightPosts = {};
  RealtimeChannel? _commentsChannel;
  Timer? _commentsRefreshDebounce;

  // Pour animation like
  final Set<String> likedLocal = {}; // posts liked locally (UI)
  final Map<String, int> localLikes = {}; // overrides for optimistic UI
  final supabase = Supabase.instance.client;
  String? _doubleTapPostId;
  bool _showBigHeart = false;
  bool _didInitialFeedLoad = false;

  @override
  void initState() {
    super.initState();
    CrashlyticsLogger.log('feed:open');
    WidgetsBinding.instance.addObserver(this);
    _initCommentsRealtime();
    if (widget.isVisible) {
      _maybeRefreshAfterInactivity(forceIfEmpty: true);
      _startUserLocationTracking();
      _syncUserLocationOnce();
    }
    FirebaseAuth.instance.authStateChanges().listen((user) {
      if (!mounted) return;
      _handleAuthChanged();
      _loadLikesForPosts();
    });
  }

  @override
  void didUpdateWidget(covariant FeedPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isVisible == widget.isVisible) return;

    if (!widget.isVisible) {
      _markFeedInactive();
      _cancelViewTimer();
      _pauseAllVideos();
      _stopUserLocationTracking();
      return;
    }

    _maybeRefreshAfterInactivity(forceIfEmpty: posts.isEmpty);
    _startUserLocationTracking();
    _syncUserLocationOnce();
    _playCurrentIfNeeded();
  }

  @override
  void dispose() {
    _markFeedInactive();
    _cancelViewTimer();
    _commentsRefreshDebounce?.cancel();
    if (_commentsChannel != null) {
      supabase.removeChannel(_commentsChannel!);
      _commentsChannel = null;
    }
    _stopUserLocationTracking();
    WidgetsBinding.instance.removeObserver(this);
    _pageController.dispose();
    for (var c in videoControllers.values) {
      try {
        c.pause();
        c.dispose();
      } catch (_) {}
    }
    videoControllers.clear();
    _videoInitEpoch.clear();
    _videoInitInFlight.clear();
    _videoInitFailed.clear();
    _videoRetryAfter.clear();
    _feedController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      _markFeedInactive();
      _cancelViewTimer();
      _pauseAllVideos();
      _stopUserLocationTracking();
    } else if (state == AppLifecycleState.resumed) {
      if (widget.isVisible) {
        _maybeRefreshAfterInactivity();
        _startUserLocationTracking();
        _syncUserLocationOnce(forceCurrent: true);
        _playCurrentIfNeeded();
      }
    }
  }

  @override
  void deactivate() {
    _markFeedInactive();
    _stopUserLocationTracking();
    super.deactivate();
  }

  @override
  void activate() {
    super.activate();
    if (widget.isVisible) {
      _startUserLocationTracking();
      _syncUserLocationOnce();
      _maybeRefreshAfterInactivity();
    }
  }

  void _handleAuthChanged() {
    _viewerDbUserId = null;
    _viewerDbUserIdForFirebaseUid = null;
    _viewerDbUserIdFuture = null;
    _resolveViewerDbUserId();
    if (widget.isVisible) {
      _syncUserLocationOnce(forceCurrent: true);
    }
    _resetFeedStateForReload();
    if (widget.isVisible) {
      _loadMorePosts();
    }
  }

  void _initCommentsRealtime() {
    _commentsChannel = supabase.channel('feed-comments-counts');
    _commentsChannel!
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'comments',
          callback: (payload) {
            final postId =
                (payload.newRecord['post_id'] ?? payload.oldRecord['post_id'] ?? '')
                    .toString();
            if (postId.isEmpty) return;
            if (!posts.any((p) => p['id']?.toString() == postId)) return;
            _scheduleRefreshCommentCounts();
          },
        )
        .subscribe();
  }

  void _scheduleRefreshCommentCounts() {
    _commentsRefreshDebounce?.cancel();
    _commentsRefreshDebounce = Timer(
      const Duration(milliseconds: 220),
      () => unawaited(_loadCommentCountsForPosts()),
    );
  }

  Future<void> _loadCommentCountsForPosts({List<String>? onlyPostIds}) async {
    final ids = (onlyPostIds ??
            posts.map((p) => p['id']?.toString() ?? '').toList())
        .where((id) => id.isNotEmpty)
        .toSet()
        .toList();
    if (ids.isEmpty) return;

    try {
      final rows = await supabase
          .from('comments')
          .select('post_id')
          .inFilter('post_id', ids);
      if (!mounted) return;

      final counts = <String, int>{};
      for (final row in rows) {
        final pid = (row['post_id'] ?? '').toString();
        if (pid.isEmpty) continue;
        counts[pid] = (counts[pid] ?? 0) + 1;
      }

      setState(() {
        for (final p in posts) {
          final id = p['id']?.toString();
          if (id == null || !ids.contains(id)) continue;
          p['comments_count'] = counts[id] ?? 0;
        }
      });
    } catch (e) {
      debugPrint('Erreur load comments counts: $e');
    }
  }

  void _stopUserLocationTracking() {
    _userLocationSub?.cancel();
    _userLocationSub = null;
  }

  void _startUserLocationTracking() {
    if (_userLocationSub != null) return;

    final settings = const LocationSettings(
      accuracy: LocationAccuracy.medium,
      distanceFilter: 75,
    );

    _userLocationSub = Geolocator.getPositionStream(
      locationSettings: settings,
    ).listen(
      (position) {
        _syncUserLocationOnce(position: position);
      },
      onError: (Object error) {
        debugPrint('FEED user_locations stream error: $error');
        _userLocationSub = null;
      },
      onDone: () {
        _userLocationSub = null;
      },
    );
  }

  String _buildUserLocationZone(double lat, double lng) {
    return '${lat.toStringAsFixed(2)},${lng.toStringAsFixed(2)}';
  }

  bool _shouldSkipUserLocationWrite({
    required double lat,
    required double lng,
  }) {
    final lastAt = _lastUserLocationSyncAt;
    final lastLat = _lastUserLocationLat;
    final lastLng = _lastUserLocationLng;
    if (lastAt == null || lastLat == null || lastLng == null) return false;

    final seconds = DateTime.now().difference(lastAt).inSeconds;
    final meters = Geolocator.distanceBetween(lastLat, lastLng, lat, lng);
    return seconds < 30 && meters < 50;
  }

  Future<void> _syncUserLocationOnce({
    bool forceCurrent = false,
    Position? position,
  }) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null || uid.isEmpty) return;
    if (_userLocationSyncInFlight) return;

    try {
      _userLocationSyncInFlight = true;

      Position? pos = position;
      if (pos == null) {
        final serviceEnabled = await Geolocator.isLocationServiceEnabled();
        if (!serviceEnabled) return;

        var permission = await Geolocator.checkPermission();
        if (permission == LocationPermission.denied) {
          permission = await Geolocator.requestPermission();
        }
        if (permission == LocationPermission.denied ||
            permission == LocationPermission.deniedForever) {
          return;
        }

        if (!forceCurrent) {
          pos = await Geolocator.getLastKnownPosition();
        }
        pos ??= await Geolocator.getCurrentPosition(
          desiredAccuracy: LocationAccuracy.medium,
        );
      }

      if (_shouldSkipUserLocationWrite(
        lat: pos.latitude,
        lng: pos.longitude,
      )) {
        return;
      }

      final payload = <String, dynamic>{
        'user_id': uid,
        'latitude': pos.latitude,
        'longitude': pos.longitude,
        'zone': _buildUserLocationZone(pos.latitude, pos.longitude),
        'updated_at': DateTime.now().toIso8601String(),
      };

      await supabase.from('user_locations').upsert(
            payload,
            onConflict: 'user_id',
          );

      _lastUserLocationSyncAt = DateTime.now();
      _lastUserLocationLat = pos.latitude;
      _lastUserLocationLng = pos.longitude;
      debugPrint(
          'FEED user_locations upsert user=$uid lat=${pos.latitude} lng=${pos.longitude}');
    } catch (e) {
      debugPrint('FEED user_locations sync error user=$uid error=$e');
    } finally {
      _userLocationSyncInFlight = false;
    }
  }

  Future<String?> _resolveViewerDbUserId() async {
    final firebaseUid = FirebaseAuth.instance.currentUser?.uid;
    if (firebaseUid == null || firebaseUid.isEmpty) {
      _viewerDbUserId = null;
      _viewerDbUserIdForFirebaseUid = null;
      _viewerDbUserIdFuture = null;
      return null;
    }

    if (_viewerDbUserId != null && _viewerDbUserIdForFirebaseUid == firebaseUid) {
      return _viewerDbUserId;
    }

    final inFlight = _viewerDbUserIdFuture;
    if (inFlight != null) {
      return inFlight;
    }

    _viewerDbUserIdFuture = () async {
      try {
        final row = await supabase
            .from('users')
            .select('id')
            .eq('firebase_uid', firebaseUid)
            .maybeSingle();

        final dbId = row?['id']?.toString();
        if (dbId == null || dbId.isEmpty) {
          debugPrint('FEED viewerDbId missing for firebase_uid=$firebaseUid');
          return null;
        }

        _viewerDbUserId = dbId;
        _viewerDbUserIdForFirebaseUid = firebaseUid;
        return dbId;
      } catch (e) {
        debugPrint(
            'FEED viewerDbId resolve error firebase_uid=$firebaseUid error=$e');
        return null;
      } finally {
        _viewerDbUserIdFuture = null;
      }
    }();

    return _viewerDbUserIdFuture;
  }

  void _markFeedInactive() {
    _lastFeedInactiveAt = DateTime.now();
  }

  void _maybeRefreshAfterInactivity({bool forceIfEmpty = false}) {
    final now = DateTime.now();
    final shouldRefresh = forceIfEmpty && posts.isEmpty
        ? true
        : (_lastFeedInactiveAt != null &&
            now.difference(_lastFeedInactiveAt!) >= _inactiveRefreshThreshold);
    if (!shouldRefresh) return;
    _resetFeedStateForReload();
    _loadMorePosts();
  }

  void _resetFeedStateForReload() {
    _cancelViewTimer();
    _didInitialFeedLoad = false;
    currentIndex = 0;
    _loadedFeedPostIds.clear();
    _impressionMarkedPostIds.clear();
    _viewRegisteredPosts.clear();
    _viewInFlightPosts.clear();
    _feedController.reset();

    for (final c in videoControllers.values) {
      try {
        c.pause();
        c.dispose();
      } catch (_) {}
    }
    videoControllers.clear();
    _videoInitEpoch.clear();
    _videoInitInFlight.clear();
    _videoInitFailed.clear();
    _videoRetryAfter.clear();
    _loggedPosts.clear();
    posts.clear();
    likedLocal.clear();
    localLikes.clear();
    hasMore = true;
    isLoading = false;

    if (_pageController.hasClients) {
      try {
        _pageController.jumpToPage(0);
      } catch (_) {}
    }
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _loadMorePosts() async {
    if (isLoading || !hasMore) return;

    final firebaseUid = FirebaseAuth.instance.currentUser?.uid;
    if (firebaseUid == null || firebaseUid.isEmpty) {
      debugPrint('FEED load skipped: viewerId null');
      return;
    }
    _resolveViewerDbUserId();

    if (!mounted) return;
    setState(() => isLoading = true);

    try {
      final rankedItems = posts.isEmpty
          ? await _feedController.fetchFirstPage(
              viewerId: firebaseUid, pageSize: limit)
          : await _feedController.fetchNextPage(pageSize: limit);
      hasMore = _feedController.state.hasMore;

      if (rankedItems.isEmpty) {
        if (!_feedController.state.hasMore) {
          hasMore = false;
        }
        return;
      }

      final rankedPostIds = rankedItems.map((e) => e.postId).toList();
      final rows = await supabase
          .from('posts')
          .select(
              'id, seller_id, media_url, thumbnail_url, thumbnail_path, video_variants, is_video, timestamp')
          .inFilter('id', rankedPostIds);

      if (!mounted) return;

      final byId = <String, Map<String, dynamic>>{};
      for (final raw in rows) {
        final row = Map<String, dynamic>.from(raw);
        final id = row['id']?.toString();
        if (id == null || id.isEmpty) continue;
        row['id'] = id;
        byId[id] = row;
      }

      final loadedIds = <String>[];
      final appendedRows = <Map<String, dynamic>>[];
      for (final ranked in rankedItems) {
        final r = byId[ranked.postId];
        if (r == null) continue;
        if (!_loadedFeedPostIds.add(ranked.postId)) continue;

        final post = <String, dynamic>{
          'id': ranked.postId,
          'seller_id': r['seller_id'],
          'media_url': r['media_url'],
          'thumbnail_url': r['thumbnail_url'],
          'thumbnail_path': r['thumbnail_path'],
          'video_variants': r['video_variants'],
          'is_video': r['is_video'],
          'timestamp': r['timestamp'],
          'normalized_score': ranked.normalizedScore,
          'random_score': ranked.randomScore,
          'popularity_score': ranked.popularityScore,
          'seller_name': 'Utilisateur',
          'avatar_url': null,
          'description': '',
          'comments_count': 0,
          'likes': 0,
        };

        posts.add(post);
        appendedRows.add(r);
        localLikes[ranked.postId] = localLikes[ranked.postId] ?? 0;
        loadedIds.add(ranked.postId);

        if (!_loggedPosts.contains(ranked.postId)) {
          _loggedPosts.add(ranked.postId);
          debugPrint(
              "FEED ranked post=${ranked.postId} score=${ranked.normalizedScore} is_video=${post['is_video']} media_url=${post['media_url']}");
        }
      }

      if (loadedIds.isNotEmpty) {
        _hydratePostMeta(loadedIds);
      }

      if (!_didInitialFeedLoad && posts.isNotEmpty) {
        _didInitialFeedLoad = true;
        currentIndex = 0;
        _maybeInitAroundIndex(currentIndex);
        _playCurrentIfNeeded();
        _markImpressionForCurrentPost();
      }

      if (!mounted) return;
      for (final r in appendedRows) {
        final rawMediaUrl = r['media_url']?.toString() ?? '';
        final isVideo = r['is_video'] == true;
        if (!isVideo && rawMediaUrl.isNotEmpty) {
          final mediaUrl = resolveMediaUrl(rawMediaUrl);
          precacheImage(CachedNetworkImageProvider(mediaUrl), context);
        }
      }
    } catch (e, st) {
      debugPrint("Erreur load personalized posts : $e\n$st");
    } finally {
      if (mounted) {
        setState(() => isLoading = false);
      }
    }

    if (!mounted) return;
    _loadLikesForPosts();
  }

  Future<void> _hydratePostMeta(List<String> ids) async {
    if (ids.isEmpty) return;
    try {
      final rows = await supabase
          .from('posts')
          .select('id, seller_name, avatar_url, description')
          .inFilter('id', ids);
      if (!mounted) return;
      final byId = <String, Map<String, dynamic>>{};
      for (final row in rows) {
        final id = row['id']?.toString();
        if (id == null || id.isEmpty) continue;
        byId[id] = Map<String, dynamic>.from(row);
      }
      if (byId.isEmpty) return;
      setState(() {
        for (final p in posts) {
          final id = p['id']?.toString();
          if (id == null) continue;
          final m = byId[id];
          if (m == null) continue;
          p['seller_name'] = m['seller_name'] ?? p['seller_name'];
          p['avatar_url'] = m['avatar_url'];
          p['description'] = m['description'] ?? p['description'];
        }
      });
      unawaited(_loadCommentCountsForPosts(onlyPostIds: ids));
    } catch (e) {
      debugPrint('Erreur hydrate post meta: $e');
    }
  }

  Future<void> _initializeVideoForIndex(int index) async {
    if (index < 0 || index >= posts.length) return;
    final doc = posts[index];
    final bool isVideo =
        doc['is_video'] == true || (doc['is_video']?.toString() == 'true');
    final mediaPath = doc['media_url']?.toString() ?? '';
    final dynamic rawVariants = doc['video_variants'];
    final Map<String, dynamic>? variants =
        rawVariants is Map ? Map<String, dynamic>.from(rawVariants) : null;
    final postId = doc['id']?.toString() ?? index.toString();

    if (!isVideo || mediaPath.isEmpty) return;
    if (videoControllers.containsKey(postId)) return;
    if (_videoInitInFlight.contains(postId)) return;
    final blockedUntil = _videoRetryAfter[postId];
    if (blockedUntil != null && DateTime.now().isBefore(blockedUntil)) return;

    _videoInitInFlight.add(postId);
    final epoch = DateTime.now().microsecondsSinceEpoch;
    _videoInitEpoch[postId] = epoch;

    try {
      final resolvedUrl = await resolveBestVideoUrl(
        mediaPath: mediaPath,
        variants: variants,
      );
      if (_videoInitEpoch[postId] != epoch) return;
      final urls = <String>[];
      urls.add(resolvedUrl);
      final fallbackUrl = resolveMediaUrl(mediaPath);
      if (!urls.contains(fallbackUrl)) {
        urls.add(fallbackUrl);
      }

      VideoPlayerController? controller;
      Object? lastError;
      for (final url in urls) {
        VideoPlayerController? testController;
        try {
          testController = createVideoController(url);
          await testController.initialize();
          controller = testController;
          break;
        } catch (e) {
          try {
            await testController?.dispose();
          } catch (_) {}
          lastError = e;
        }
      }
      if (controller == null) {
        throw lastError ?? Exception('Video source error');
      }

      if (_videoInitEpoch[postId] != epoch) {
        try {
          controller.dispose();
        } catch (_) {}
        return;
      }
      videoControllers[postId] = controller;
      controller.setLooping(true);
      _videoInitFailed.remove(postId);
      _videoRetryAfter.remove(postId);
      if (currentIndex < posts.length &&
          posts[currentIndex]['id']?.toString() == postId) {
        controller.play();
        _scheduleViewForCurrentPost();
      }
      setState(() {});
    } catch (e) {
      debugPrint("Erreur init video ($postId): $e");
      CrashlyticsLogger.log('video:init_error post=$postId');
      unawaited(CrashlyticsLogger.recordNonFatal(
        e,
        StackTrace.current,
        reason: 'feed_video_initialize',
      ));
      _videoInitFailed.add(postId);
      _videoRetryAfter[postId] = DateTime.now().add(const Duration(seconds: 8));
      videoControllers.remove(postId);
      _videoInitEpoch.remove(postId);
    } finally {
      _videoInitInFlight.remove(postId);
    }
  }

  void _maybeInitAroundIndex(int index) {
    _initializeVideoForIndex(index); // current
    _initializeVideoForIndex(index + 1); // next
    _pruneVideoControllers(index);
  }

  void _pruneVideoControllers(int index) {
    final keep = <String>{};
    for (final i in [index, index + 1]) {
      if (i >= 0 && i < posts.length) {
        final id = posts[i]['id']?.toString();
        if (id != null && id.isNotEmpty) keep.add(id);
      }
    }
    final ids = videoControllers.keys.toList();
    for (final id in ids) {
      if (keep.contains(id)) continue;
      final c = videoControllers.remove(id);
      _videoInitEpoch.remove(id);
      _videoInitInFlight.remove(id);
      if (c != null) {
        try {
          c.pause();
          c.dispose();
        } catch (_) {}
      }
    }
  }

  void _pauseVideoByIndex(int index) {
    if (index < 0 || index >= posts.length) return;
    final id = posts[index]['id']?.toString();
    if (id == null) return;
    final c = videoControllers[id];
    if (c != null && c.value.isPlaying) {
      c.pause();
      if (index == currentIndex) {
        _cancelViewTimer();
      }
    }
  }

  void _pauseAllVideos() {
    for (var c in videoControllers.values) {
      try {
        if (c.value.isPlaying) c.pause();
      } catch (_) {}
    }
    _cancelViewTimer();
  }

  bool _isVideoPost(Map<String, dynamic> post) {
    return post['is_video'] == true || (post['is_video']?.toString() == 'true');
  }

  void _cancelViewTimer() {
    _viewTimer?.cancel();
    _viewTimer = null;
    _pendingViewPostId = null;
  }

  Future<void> _registerViewForPost(String postId) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    if (_viewRegisteredPosts.contains(postId)) return;
    if (_viewInFlightPosts.contains(postId)) return;

    _viewInFlightPosts.add(postId);
    bool success = false;
    try {
      try {
        await supabase.from('post_views').upsert(
          {
            'post_id': postId,
            'viewer_id': uid,
            'created_at': DateTime.now().toIso8601String(),
          },
          onConflict: 'post_id,viewer_id',
        );
        success = true;
      } catch (_) {
        final exists = await supabase
            .from('post_views')
            .select('id')
            .eq('post_id', postId)
            .eq('viewer_id', uid)
            .limit(1);
        if (exists.isEmpty) {
          await supabase.from('post_views').insert({
            'post_id': postId,
            'viewer_id': uid,
            'created_at': DateTime.now().toIso8601String(),
          });
        }
        success = true;
      }
    } catch (e) {
      debugPrint("FEED view register error post=$postId user=$uid error=$e");
    } finally {
      if (success) {
        _viewRegisteredPosts.add(postId);
      }
      _viewInFlightPosts.remove(postId);
    }
  }

  void _scheduleViewForCurrentPost() {
    _cancelViewTimer();
    if (currentIndex < 0 || currentIndex >= posts.length) return;

    final post = posts[currentIndex];
    if (!_isVideoPost(post)) return;
    final postId = post['id']?.toString();
    if (postId == null || postId.isEmpty) return;
    if (_viewRegisteredPosts.contains(postId)) return;
    if (_viewInFlightPosts.contains(postId)) return;

    _pendingViewPostId = postId;
    _viewTimer = Timer(_viewThreshold, () async {
      if (!mounted) return;
      if (_pendingViewPostId != postId) return;
      if (currentIndex < 0 || currentIndex >= posts.length) return;
      final currentPostId = posts[currentIndex]['id']?.toString();
      if (currentPostId != postId) return;

      final controller = videoControllers[postId];
      if (controller == null ||
          !controller.value.isInitialized ||
          !controller.value.isPlaying) {
        return;
      }
      await _registerViewForPost(postId);
    });
  }

  void _markImpressionForCurrentPost() {
    if (currentIndex < 0 || currentIndex >= posts.length) return;
    final postId = posts[currentIndex]['id']?.toString();
    if (postId == null || postId.isEmpty) return;
    _markFeedImpression(postId);
  }

  Future<void> _markFeedImpression(String postId) async {
    final viewerDbId = await _resolveViewerDbUserId();
    if (viewerDbId == null || viewerDbId.isEmpty) return;
    if (_impressionMarkedPostIds.contains(postId)) return;
    _impressionMarkedPostIds.add(postId);
    try {
      await supabase.from('feed_impressions').upsert(
        {
          'user_id': viewerDbId,
          'post_id': postId,
          'seen_at': DateTime.now().toIso8601String(),
        },
        onConflict: 'user_id,post_id',
        ignoreDuplicates: true,
      );
    } catch (e) {
      debugPrint(
          'FEED impression error post=$postId user=$viewerDbId error=$e');
      _impressionMarkedPostIds.remove(postId);
    }
  }

  Future<void> openPublicProfile(String sellerId) async {
    _markFeedInactive();
    await Navigator.pushNamed(
      context,
      '/publicProfile',
      arguments: sellerId,
    );
    _maybeRefreshAfterInactivity();
  }

  void _playCurrentIfNeeded() {
    Future.microtask(() {
      if (currentIndex < 0 || currentIndex >= posts.length) return;

      final id = posts[currentIndex]['id']?.toString();
      if (id == null) return;

      final c = videoControllers[id];
      if (c == null) {
        _initializeVideoForIndex(currentIndex);
        return;
      }
      if (c.value.isInitialized) {
        if (!c.value.isPlaying) {
          c.play();
        }
        _scheduleViewForCurrentPost();
      }
    });
  }

  void _onPageChanged(int index) {
    _cancelViewTimer();
    _pauseVideoByIndex(currentIndex);
    currentIndex = index;
    _maybeInitAroundIndex(index);
    _playCurrentIfNeeded();
    _markImpressionForCurrentPost();

    if (index >= posts.length - 3) {
      _loadMorePosts();
    }
  }

  // -------------------- LIKE (animation + update supabase) --------------------
  // Optimistic UI: on like pressed -> animate + increment local value, then update server
  Future<void> _likePostAnimated(String postId) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    final userId = user.uid;

    // Empêche double like
    if (likedLocal.contains(postId)) return;

    // LIKE OPTIMISTIQUE (affichage immédiat)
    setState(() {
      likedLocal.add(postId);
      localLikes[postId] = (localLikes[postId] ?? 0) + 1;
    });

    try {
      // -------------------------------
      // 1️⃣ INSERT DANS LA TABLE LIKES
      // -------------------------------
      await Supabase.instance.client.from('likes').insert({
        'post_id': postId,
        'user_id': userId,
        'created_at': DateTime.now().toIso8601String(),
      });

      // -------------------------------
      // 2️⃣ UPDATE DE LA TABLE POSTS
      // -------------------------------
      await Supabase.instance.client
          .from('posts')
          .update({'likes': localLikes[postId]}).eq('id', postId);
    } catch (e) {
      debugPrint("ERROR LIKE: $e");
    }

    // -------------------------------
    // 3️⃣ Après tout → rechargement fiable
    // -------------------------------
    await _loadLikesForPosts();
  }

  Future<void> _loadLikesForPosts() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    final userId = user.uid;

    if (posts.isEmpty) return;

    final postIds = posts.map((e) => e['id'].toString()).toList();

    final data = await Supabase.instance.client
        .from('likes')
        .select()
        .inFilter('post_id', postIds);

    likedLocal.clear();
    localLikes.clear();

    for (final like in data) {
      final pid = like['post_id'].toString();

      localLikes[pid] = (localLikes[pid] ?? 0) + 1;

      if (like['user_id'] == userId) {
        likedLocal.add(pid);
      }
    }
    if (!mounted) return;
    setState(() {});
  }

  // -------------------- WIDGET BUILD --------------------
  @override
  Widget build(BuildContext context) {
    if (posts.isEmpty && isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (posts.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.rss_feed, size: 64, color: Colors.grey),
            const SizedBox(height: 12),
            const Text("Aucun post disponible", style: TextStyle(fontSize: 16)),
            const SizedBox(height: 12),
            ElevatedButton(
                onPressed: _loadMorePosts, child: const Text("Recharger")),
          ],
        ),
      );
    }

    return NyotaBackground(
      child: Stack(
        children: [
          PageView.builder(
            controller: _pageController,
            scrollDirection: Axis.vertical,
            pageSnapping: true,
            physics: const PageScrollPhysics(),
            itemCount: posts.length,
            onPageChanged: _onPageChanged,
            itemBuilder: (context, index) {
              final doc = posts[index];
              final rawMediaUrl = doc['media_url']?.toString();
              final mediaUrl =
                  rawMediaUrl == null ? null : resolveMediaUrl(rawMediaUrl);
              final rawThumb = doc['thumbnail_url'] ?? doc['thumbnail_path'];
              final thumbnailUrl =
                  rawThumb != null && rawThumb.toString().isNotEmpty
                      ? resolveMediaUrl(rawThumb.toString())
                      : null;
              final isVideo = doc['is_video'] == true ||
                  (doc['is_video']?.toString() == 'true');
              final sellerId = doc['seller_id'];
              final description = doc['description'] ?? '';
              final postId = doc['id']?.toString() ?? index.toString();

              final likesCount = localLikes[postId] ?? (doc['likes'] ?? 0);

              return GestureDetector(
                behavior: HitTestBehavior.opaque,

                // ✅ DOUBLE TAP = LIKE + FEU D’ARTIFICE DE CŒUR
                onDoubleTap: () {
                  if (!likedLocal.contains(postId)) {
                    _likePostAnimated(postId);
                  }

                  setState(() {
                    _doubleTapPostId = postId;
                    _showBigHeart = true;
                  });

                  Future.delayed(const Duration(milliseconds: 700), () {
                    if (mounted) {
                      setState(() {
                        _showBigHeart = false;
                      });
                    }
                  });
                },

                // ✅ SIMPLE TAP = PLAY / PAUSE
                onTap: () {
                  if (isVideo && mediaUrl != null && mediaUrl.isNotEmpty) {
                    final ctrl = videoControllers[postId];
                    if (ctrl != null && ctrl.value.isInitialized) {
                      if (ctrl.value.isPlaying) {
                        ctrl.pause();
                        _cancelViewTimer();
                      } else {
                        ctrl.play();
                        if (currentIndex == index) {
                          _scheduleViewForCurrentPost();
                        }
                      }
                      setState(() {});
                    }
                  }
                },

                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (isVideo && mediaUrl != null && mediaUrl.isNotEmpty)
                      _buildVideoWidget(postId, mediaUrl, thumbnailUrl)
                    else if (mediaUrl != null && mediaUrl.isNotEmpty)
                      CachedNetworkImage(
                        imageUrl: mediaUrl,
                        fit: BoxFit.cover,
                        width: double.infinity,
                        height: double.infinity,
                        placeholder: (c, s) => const Center(
                            child: CircularProgressIndicator(strokeWidth: 2)),
                        errorWidget: (c, s, e) =>
                            const Center(child: Icon(Icons.broken_image)),
                      )
                    else
                      Container(color: Colors.black54),

                    // Gradient for readability
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      height: 260,
                      child: Container(
                        decoration: const BoxDecoration(
                          gradient: LinearGradient(
                            colors: [Colors.transparent, Colors.black54],
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                          ),
                        ),
                      ),
                    ),

                    // Seller info
                    Positioned(
                      left: 16,
                      bottom: 40,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // ❌ SUPPRIMER L’AVATAR ICI
                          // ❌ SUPPRIMER L’EMAIL ICI

                          const SizedBox(height: 6),

                          // ✅ GARDER LA DESCRIPTION
                          SizedBox(
                            width: MediaQuery.of(context).size.width * 0.6,
                            child: Text(
                              description,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 15,
                              ),
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ),

                    if (_showBigHeart && _doubleTapPostId == postId)
                      Center(
                        child: TweenAnimationBuilder<double>(
                          tween: Tween(begin: 0.3, end: 1.4),
                          duration: const Duration(milliseconds: 400),
                          curve: Curves.elasticOut,
                          builder: (context, scale, child) {
                            return Transform.scale(
                              scale: scale,
                              child: const Icon(
                                Icons.favorite,
                                color: Colors.red,
                                size: 120,
                              ),
                            );
                          },
                        ),
                      ),

                    FullScreenMediaActions(
                      postId: postId,
                      sellerId: sellerId,
                      avatarUrl: doc['avatar_url'],
                      likesCount: likesCount,
                      commentsCount: doc['comments_count'] ?? 0,
                      isLiked: likedLocal.contains(postId),
                      onLike: () => _likePostAnimated(postId),
                      onComment: () => _openComments(postId),
                      onOpenProfile: () => openPublicProfile(sellerId), // ✅ ICI
                    ),
                  ],
                ),
              );
            },
          ),

          // Top-right controls

          if (isLoading)
            const Positioned(
                bottom: 24,
                left: 0,
                right: 0,
                child: Center(child: CircularProgressIndicator())),
        ],
      ),
    );
  }

  Widget _buildVideoWidget(
      String postId, String mediaUrl, String? thumbnailUrl) {
    final controller = videoControllers[postId];
    if (controller == null) {
      final isFailed = _videoInitFailed.contains(postId);
      return _buildVideoFallback(
        thumbnailUrl: thumbnailUrl,
        loading: !isFailed,
        onRetry: isFailed ? () => _retryVideoInit(postId) : null,
      );
    }

    if (!controller.value.isInitialized || controller.value.hasError) {
      return _buildVideoFallback(
        thumbnailUrl: thumbnailUrl,
        loading: !controller.value.hasError,
        onRetry:
            controller.value.hasError ? () => _retryVideoInit(postId) : null,
      );
    }

    return FittedBox(
      fit: BoxFit.cover,
      clipBehavior: Clip.hardEdge,
      child: SizedBox(
          width: controller.value.size.width,
          height: controller.value.size.height,
          child: VideoPlayer(controller)),
    );
  }

  Widget _buildVideoFallback({
    required String? thumbnailUrl,
    required bool loading,
    VoidCallback? onRetry,
  }) {
    final bg = (thumbnailUrl != null && thumbnailUrl.isNotEmpty)
        ? CachedNetworkImage(
            imageUrl: thumbnailUrl,
            fit: BoxFit.cover,
            width: double.infinity,
            height: double.infinity,
            placeholder: (c, s) => const SizedBox.shrink(),
            errorWidget: (c, s, e) =>
                const Center(child: Icon(Icons.broken_image)),
          )
        : Container(color: Colors.black54);

    return Stack(
      fit: StackFit.expand,
      children: [
        bg,
        if (loading)
          const Center(
            child: SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
        if (onRetry != null)
          Center(
            child: ElevatedButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh, size: 16),
              label: const Text('Reessayer'),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.black87,
                foregroundColor: Colors.white,
              ),
            ),
          ),
      ],
    );
  }

  void _retryVideoInit(String postId) {
    final existing = videoControllers.remove(postId);
    if (existing != null) {
      try {
        existing.pause();
        existing.dispose();
      } catch (_) {}
    }
    _videoInitFailed.remove(postId);
    _videoRetryAfter.remove(postId);
    _videoInitEpoch.remove(postId);
    _videoInitInFlight.remove(postId);
    final idx = posts.indexWhere((d) => d['id']?.toString() == postId);
    if (idx != -1) {
      _initializeVideoForIndex(idx);
    }
  }

  void _openComments(String postId) {
    _markFeedInactive();
    openComments(context, postId).whenComplete(() {
      _maybeRefreshAfterInactivity();
      unawaited(_loadCommentCountsForPosts(onlyPostIds: [postId]));
    });
  }
}
