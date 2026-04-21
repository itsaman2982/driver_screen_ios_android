import 'package:driverscreen/src/core/utils/app_logger.dart';
import 'package:flutter/services.dart';

class KioskService {
  static const MethodChannel _channel = MethodChannel('com.fleet.kiosk/lock');

  static Future<void> setEnabled(bool enabled) async {
    try {
      AppLogger.info('🔒 [KIOSK] Triggering TRUE Android Screen Pinning: ${enabled ? 'LOCKED' : 'UNLOCKED'}');
      
      if (enabled) {
        // Visual Cleanup: Hide status and navigation bars
        await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
        
        // HARDWARE LOCK: Trigger Android's Native "Start Lock Task" APIs
        await _channel.invokeMethod('startKioskMode');
      } else {
        // Restore standard visuals
        await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
        
        // HARDWARE UNLOCK: Release Android Screen Pinning
        await _channel.invokeMethod('stopKioskMode');
      }
    } catch (e) {
      AppLogger.info('❌ [KIOSK] Hardware Level Error: $e');
    }
  }

  static Future<bool> isEnabled() async {
    return false; // Real state is tracked via driver_provider and backend
  }
}
