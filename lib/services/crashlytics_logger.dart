import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:flutter/foundation.dart';

class CrashlyticsLogger {
  CrashlyticsLogger._();

  static FirebaseCrashlytics get _crashlytics =>
      FirebaseCrashlytics.instance;

  static Future<void> initSessionMetadata() async {
    await _crashlytics.setCustomKey('app', 'nyota');
    await _crashlytics.setCustomKey(
      'build',
      kReleaseMode ? 'release' : 'debug',
    );
  }

  static Future<void> setUser(User? firebaseUser) async {
    final uid = firebaseUser?.uid ?? '';
    await _crashlytics.setUserIdentifier(uid);
  }

  static void log(String message) {
    _crashlytics.log(message);
  }

  static Future<void> recordNonFatal(
    Object error,
    StackTrace stack, {
    String? reason,
  }) async {
    await _crashlytics.recordError(
      error,
      stack,
      fatal: false,
      reason: reason,
    );
  }
}
