import 'package:flutter/foundation.dart';

import 'feed_repository.dart';

class FeedControllerState {
  final List<FeedRankedItem> items;
  final FeedCursor? cursor;
  final bool loading;
  final bool hasMore;
  final String? viewerId;
  final String? error;

  const FeedControllerState({
    required this.items,
    required this.cursor,
    required this.loading,
    required this.hasMore,
    required this.viewerId,
    required this.error,
  });

  factory FeedControllerState.initial() => const FeedControllerState(
        items: [],
        cursor: null,
        loading: false,
        hasMore: true,
        viewerId: null,
        error: null,
      );

  FeedControllerState copyWith({
    List<FeedRankedItem>? items,
    FeedCursor? cursor,
    bool? loading,
    bool? hasMore,
    String? viewerId,
    String? error,
    bool clearError = false,
    bool clearCursor = false,
  }) {
    return FeedControllerState(
      items: items ?? this.items,
      cursor: clearCursor ? null : (cursor ?? this.cursor),
      loading: loading ?? this.loading,
      hasMore: hasMore ?? this.hasMore,
      viewerId: viewerId ?? this.viewerId,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

class FeedController extends ChangeNotifier {
  FeedController({FeedRepository? repository})
      : _repository = repository ?? FeedRepository();

  final FeedRepository _repository;
  final Set<String> _seenPostIds = <String>{};
  int _requestToken = 0;
  FeedControllerState _state = FeedControllerState.initial();

  FeedControllerState get state => _state;

  void reset() {
    _seenPostIds.clear();
    _state = FeedControllerState.initial();
    notifyListeners();
  }

  Future<List<FeedRankedItem>> fetchFirstPage({
    required String viewerId,
    int pageSize = 6,
  }) async {
    if (_state.loading) return const [];
    final token = ++_requestToken;
    _seenPostIds.clear();
    _state = _state.copyWith(
      loading: true,
      hasMore: true,
      viewerId: viewerId,
      items: const [],
      clearCursor: true,
      clearError: true,
    );
    notifyListeners();

    try {
      final result = await _repository.fetchFirstPage(
        viewerId: viewerId,
        pageSize: pageSize,
      );
      if (token != _requestToken) return const [];

      final unique = <FeedRankedItem>[];
      for (final item in result.items) {
        if (_seenPostIds.add(item.postId)) {
          unique.add(item);
        }
      }

      _state = _state.copyWith(
        loading: false,
        viewerId: viewerId,
        items: unique,
        cursor: result.cursor,
        hasMore: result.hasMore,
        clearError: true,
      );
      notifyListeners();
      return unique;
    } catch (e) {
      if (token != _requestToken) return const [];
      _state = _state.copyWith(
        loading: false,
        error: e.toString(),
      );
      notifyListeners();
      rethrow;
    }
  }

  Future<List<FeedRankedItem>> fetchNextPage({int pageSize = 6}) async {
    if (_state.loading || !_state.hasMore) return const [];
    final viewerId = _state.viewerId;
    final cursor = _state.cursor;
    if (viewerId == null || viewerId.isEmpty || cursor == null) {
      return const [];
    }

    final token = ++_requestToken;
    _state = _state.copyWith(
      loading: true,
      clearError: true,
    );
    notifyListeners();

    try {
      final result = await _repository.fetchNextPage(
        viewerId: viewerId,
        cursor: cursor,
        pageSize: pageSize,
      );
      if (token != _requestToken) return const [];

      final unique = <FeedRankedItem>[];
      for (final item in result.items) {
        if (_seenPostIds.add(item.postId)) {
          unique.add(item);
        }
      }

      _state = _state.copyWith(
        loading: false,
        items: [..._state.items, ...unique],
        cursor: result.cursor,
        hasMore: result.hasMore,
        clearError: true,
      );
      notifyListeners();
      return unique;
    } catch (e) {
      if (token != _requestToken) return const [];
      _state = _state.copyWith(
        loading: false,
        error: e.toString(),
      );
      notifyListeners();
      rethrow;
    }
  }
}
