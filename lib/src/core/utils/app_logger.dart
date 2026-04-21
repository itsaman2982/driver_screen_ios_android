import 'dart:developer' as developer;
import 'package:flutter/foundation.dart';

class AppLogger {
  static void info(dynamic message, {String tag = 'INFO'}) {
    if (kDebugMode) {
      developer.log(message.toString(), name: tag);
    }
  }

  static void error(dynamic message, {dynamic error, StackTrace? stackTrace, String tag = 'ERROR'}) {
    if (kDebugMode) {
      developer.log(message.toString(), name: tag, error: error, stackTrace: stackTrace);
    }
  }

  static void warning(dynamic message, {String tag = 'WARNING'}) {
    if (kDebugMode) {
      developer.log(message.toString(), name: tag);
    }
  }
}
