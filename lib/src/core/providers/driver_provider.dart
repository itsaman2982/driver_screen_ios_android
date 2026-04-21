import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:socket_io_client/socket_io_client.dart' as IO;
import 'package:driverscreen/src/core/api/api_service.dart';
import 'package:driverscreen/src/core/services/socket_service.dart';
import 'package:driverscreen/src/core/services/kiosk_service.dart';

class DriverProvider extends ChangeNotifier {
  Map<String, dynamic>? _driver;
  Map<String, dynamic>? _activeRide;
  Map<String, dynamic>? _incomingRideRequest; 
  
  bool _isLoggedIn = false;
  bool _isInitialized = false; 
  bool _kioskStatus = false;
  int _photoVersion = DateTime.now().millisecondsSinceEpoch;
  
  final SocketService _socketService = SocketService();
  final ApiService _apiService = ApiService();

  Map<String, dynamic>? get driver => _driver;
  Map<String, dynamic>? get activeRide => _activeRide;
  Map<String, dynamic>? get incomingRideRequest => _incomingRideRequest;
  bool get isLoggedIn => _isLoggedIn;
  bool get isInitialized => _isInitialized;
  int get photoVersion => _photoVersion;
  bool get kioskStatus => _kioskStatus;
  IO.Socket? get socket => _socketService.socket;

  DriverProvider() {
    _initPersistentSession();
  }

  Future<void> _initPersistentSession() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final driverStr = prefs.getString('driver');
      print('📦 [SESSION] Checking for saved driver session: ${driverStr != null ? 'DATA FOUND' : 'NO DATA'}');
      
      if (driverStr != null) {
        _driver = jsonDecode(driverStr);
        _isLoggedIn = true;
        
        final driverId = (_driver!['_id'] ?? _driver!['id'] ?? _driver!['driverId']).toString();
        final token = (_driver!['token'] ?? _driver!['_id']).toString();
        
        print('🔐 [SESSION] Restoring session for Driver: $driverId');
        _apiService.setToken(token);
        _socketService.connect(driverId);
        _kioskStatus = _driver!['kioskEnabled'] == true;
        KioskService.setEnabled(_kioskStatus);
        _setupSocketListeners();
        
        // Use try-catch to allow offline entry
        try {
           await syncProfile().timeout(const Duration(seconds: 10)); 
           await _restoreAppState().timeout(const Duration(seconds: 10));
        } catch(e) {
           print('📡 [SESSION] Offline or server taking too long to wake up. Continuing with local data.');
        }
      }
    } catch (e) {
      print('❌ Persistent session error: $e');
    } finally {
      _isInitialized = true;
      notifyListeners();
    }
  }

  Future<void> _restoreAppState() async {
    await _syncCurrentRide();
    if (_activeRide == null) {
       await _fetchPendingRide();
    }
  }

  void _setupSocketListeners() {
    // 🔔 REAL-TIME STATUS UPDATES
    _socketService.on('ride_status_update', (data) {
       print('🔧 [SOCKET] Ride status updated: $data');
       _syncCurrentRide();
    });

    _socketService.on('ride_status', (data) {
       print('🔧 [SOCKET] Ride status changed: $data');
       _syncCurrentRide();
    });
    
    _socketService.on('ride_accepted', (data) {
       print('🚀 [SOCKET] Ride accepted locally or globally: $data');
       _syncCurrentRide();
    });

    _socketService.on('ride_assigned', (data) {
       print('🎯 [SOCKET] Ride assigned to us: $data');
       _activeRide = data['ride'] ?? data;
       _incomingRideRequest = null;
       
       // Join Ride Room IMMEDIATELY for status updates
       if (_activeRide?['_id'] != null) {
          _socketService.joinRideRoom(_activeRide!['_id'].toString());
       }
       notifyListeners();
    });

    _socketService.on('new_ride_request', (data) {
       print('🔔 [SOCKET] New ride request incoming: $data');
       _incomingRideRequest = data;
       notifyListeners();
    });

    _socketService.on('ride_taken', (data) {
       print('⛔ [SOCKET] Ride taken by someone else: $data');
       final takenId = (data is Map) ? data['rideId'] : data?.toString();
       if (_incomingRideRequest != null && _incomingRideRequest!['_id'] == takenId) {
          _incomingRideRequest = null;
          notifyListeners();
       }
    });

    _socketService.on('ride_cancelled', (data) {
       print('❌ [SOCKET] Ride cancelled: $data');
       _activeRide = null; 
       _incomingRideRequest = null;
       notifyListeners();
    });

    _socketService.on('connect', (_) {
       print('🔌 [SOCKET] Reconnected. Syncing state and rooms...');
       syncProfile(); // 🔥 Refresh profile on reconnection
       _restoreAppState();
       if (_activeRide != null && _activeRide!['_id'] != null) {
          _socketService.joinRideRoom(_activeRide!['_id'].toString());
       }
    });

    // 👤 PROFILE SYNC
     _socketService.on('profile_updated', (data) {
        print('👤 [SOCKET] Profile updated notification received');
        syncProfile();
     });

     _socketService.on('admin_toggle_kiosk', (data) async {
        print('🔒 [SOCKET] Admin toggled kiosk mode: $data');
        final enabled = data['enabled'] == true;
        _kioskStatus = enabled;
        notifyListeners();
        await KioskService.setEnabled(enabled);
     });
  }

  void dismissRequest() {
    _incomingRideRequest = null;
    notifyListeners();
  }

  Future<void> _syncCurrentRide() async {
    try {
      final res = await _apiService.get('rides/current');
      if (res is Map && res['success'] == true) {
        _activeRide = res['data'];
        
        // Ensure we are in the ride room for status updates
        if (_activeRide != null && _activeRide!['_id'] != null) {
           _socketService.joinRideRoom(_activeRide!['_id'].toString());
        }
        
        notifyListeners();
      } else {
        _activeRide = null;
        notifyListeners();
      }
    } catch (e) {
       _activeRide = null;
       notifyListeners();
    }
  }

  Future<void> syncProfile() async {
    try {
      final res = await _apiService.get('drivers/me');
      print('📡 [PROVIDER] Profile sync response: $res');
      
      if (res is Map && res['success'] == true) {
        _driver = Map<String, dynamic>.from(res['data'] ?? {});
        _photoVersion = DateTime.now().millisecondsSinceEpoch; // 🔥 Only update version on real data change
        
        _kioskStatus = _driver!['kioskEnabled'] == true;
        KioskService.setEnabled(_kioskStatus);
        
        // Save to persistent storage too
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('driver', jsonEncode(_driver));
        
        notifyListeners();
      }
    } catch (e) {
      print('❌ Profile sync error: $e');
    }
  }

  Future<void> _fetchPendingRide() async {
    try {
      final res = await _apiService.get('rides/pending'); 
      if (res is Map && res['success'] == true) {
        final List<dynamic> list = res['data'] ?? [];
        if (list.isNotEmpty) {
           _incomingRideRequest = list.first;
           notifyListeners();
        }
      }
    } catch (e) {
      print('❌ Fetch pending error: $e');
    }
  }

  Future<bool> updateRideStatus(String status) async {
    if (_activeRide == null) {
       print('⚠️ [PROVIDER] Update status failed: No active ride');
       return false;
    }
    try {
      final rideId = (_activeRide!['_id'] ?? _activeRide!['id'] ?? _activeRide!['rideId']).toString();
      print('🔄 [PROVIDER] Requesting SERVER status change for $rideId to: $status');
      
      final res = await _apiService.post('rides/$rideId/status', {'status': status});
      print('📡 [PROVIDER] Server response: $res');
      
      if (res is Map && res['success'] == true) {
        // Sync the updated ride data back to our local state
        _activeRide = res['data'] ?? _activeRide;
        
        final rId = (_activeRide!['_id'] ?? _activeRide!['id']).toString();
        _socketService.joinRideRoom(rId);
        
        print('✅ [PROVIDER] Status update CONFIRMED by backend: $status');
        notifyListeners();
        
        // Force sync just in case backend data is partial
        await _syncCurrentRide();
        return true;
      } else {
        print('❌ [PROVIDER] Backend rejected status update: ${res['message']}');
      }
    } catch (e) {
      print('❌ [PROVIDER] Network error during status update: $e');
    }
    return false;
  }

  Future<bool> reportBreakdown({double? lat, double? lng, String? notes}) async {
    if (_activeRide == null) return false;
    try {
      final rideId = _activeRide!['_id'];
      final res = await _apiService.post('breakdowns/report', {
        'rideId': rideId,
        'lat': lat ?? 23.0225, // Fallback to Ahmedabad if GPS fails
        'lng': lng ?? 72.5714,
        'notes': notes ?? 'Breakdown reported from tablet dashboard',
      });
      if (res['success'] == true) {
        _activeRide = res['data']; // Might return updated ride or breakdown
        await _syncCurrentRide(); // Best to full sync
        return true;
      }
    } catch (e) {
      print('❌ Report breakdown error: $e');
    }
    return false;
  }

  Future<bool> acceptRide(String rideId) async {
    try {
      final res = await _apiService.post('rides/$rideId/accept', {});
      if (res['success'] == true) {
        _activeRide = res['data'];
        _incomingRideRequest = null;
        
        // Join Ride Room IMMEDIATELY
        if (_activeRide?['_id'] != null) {
           _socketService.joinRideRoom(_activeRide!['_id'].toString());
        }
        
        notifyListeners();
        return true;
      }
    } catch (e) {
      print('❌ Accept ride error: $e');
    }
    return false;
  }

  Future<bool> login(String email, String password) async {
    try {
      final res = await _apiService.post('auth/login', {
        'email': email.trim(),
        'password': password,
      });
      
      if (res['success'] == true) {
        _driver = res['data'];
        _isLoggedIn = true;
        
        final dId = (_driver!['_id'] ?? _driver!['id'] ?? _driver!['driverId']).toString();
        final token = (_driver!['token'] ?? _driver!['_id']).toString();
        
        _apiService.setToken(token);
        _socketService.connect(dId);
        
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('driver', jsonEncode(_driver));
        
        _setupSocketListeners();
        await _restoreAppState();
        notifyListeners();
        return true;
      }
    } catch (e) {
      print('❌ Login error in DriverProvider: $e');
    }
    return false;
  }

  Future<void> logout() async {
    _isLoggedIn = false;
    _driver = null;
    _activeRide = null;
    _incomingRideRequest = null;
    _apiService.clearToken();
    _socketService.disconnect();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('driver');
    notifyListeners();
  }
}
