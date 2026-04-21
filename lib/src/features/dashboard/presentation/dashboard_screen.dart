// ignore_for_file: use_build_context_synchronously, deprecated_member_use, prefer_conditional_assignment, curly_braces_in_flow_control_structures, prefer_const_constructors
import 'dart:async';
import 'dart:io';
import 'package:dio/dio.dart' as dio_pkg;
import 'package:driverscreen/src/core/api/api_service.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import 'package:driverscreen/src/core/providers/driver_provider.dart';
import 'package:driverscreen/src/core/theme/app_theme.dart';
import 'package:mappls_gl/mappls_gl.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:driverscreen/src/core/map/mappls_service.dart';
import 'package:geolocator/geolocator.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart' hide ServiceStatus;
import 'package:flutter_animate/flutter_animate.dart';
import 'package:battery_plus/battery_plus.dart';
import 'package:connectivity_plus/connectivity_plus.dart';

class DashboardPage extends StatefulWidget {
  const DashboardPage({super.key});

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage> with WidgetsBindingObserver {
  MapplsMapController? _mapController;
  int _batteryLevel = 100;
  final Battery _battery = Battery();
  StreamSubscription<BatteryState>? _batterySubscription;
  
  // Real-time Status
  String _networkStatus = "CONN...";
  Color _networkColor = Colors.grey;
  IconData _networkIcon = Icons.signal_cellular_off_rounded;
  
  bool _isGpsLocked = false;
  StreamSubscription<ServiceStatus>? _gpsSubscription;
  StreamSubscription<List<ConnectivityResult>>? _connectivitySubscription;

  // WebRTC & Monitoring Channels
  MediaStream? _frontRoadStream;
  MediaStream? _interiorStream;
  final RTCVideoRenderer _localRenderer = RTCVideoRenderer();
  final Map<String, RTCPeerConnection> _peerConnections = {};

  // Dashcam Recording Component
  MediaRecorder? _roadRecorder;
  MediaRecorder? _interiorRecorder;
  bool _isRecording = false;
  String? _currentRideId;
  
  // Navigation State
  List<LatLng> _routePoints = [];
  List<Map<String, dynamic>> _trafficSegments = [];
  Line? _routeLine;
  final List<Line> _trafficLines = [];
  Symbol? _pickupSymbol;
  Symbol? _dropSymbol;
  
  // LIVE JOURNEY STATS
  double _liveDistance = 0.0;
  double _liveDuration = 0.0;
  StreamSubscription<Position>? _locationSubscription;

  @override
  void initState() {
    super.initState();
    _localRenderer.initialize();
    
    _checkPermissions();
    _initBattery();
    _initSensors();
    _startLocationTracking();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addObserver(this);
    
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _setupWebRTCSignaling();
      
      // 🔌 Hot-plug detection for USB cameras
      navigator.mediaDevices.ondevicechange = (event) {
        debugPrint('🔌 [HARDWARE] Camera Change Detected. Rescanning...');
        _initCamera();
      };

      // 1. WATCHER: Auto-init cameras when a ride starts, Stop when ride ends
      context.read<DriverProvider>().addListener(() {
        final provider = context.read<DriverProvider>();
        final hasRide = provider.activeRide != null;
        final rideId = provider.activeRide?['_id']?.toString();
        
        // Automatic Lifecycle Management: Start on Ride, Stop on End
        if (hasRide && _frontRoadStream == null) {
          debugPrint('🚀 [AUTO] Ride started: Activating hardware monitoring system...');
          _currentRideId = rideId;
          _initCamera().then((_) {
             _startRecording();
          });
        } else if (!hasRide && _frontRoadStream != null) {
           debugPrint('🏁 [AUTO] Ride ended: Preparing surveillance archive...');
           _stopAndUploadRecording();
           _stopSensors();
           _currentRideId = null;
        }

        _updateMapOverlays();
        _setupWebRTCSignaling(); 
      });
    });
  }

  Future<void> _startRecording() async {
    if (_isRecording || _currentRideId == null) return;
    try {
      final dir = await getTemporaryDirectory();
      
      if (_frontRoadStream != null) {
        _roadRecorder = MediaRecorder();
        final path = '${dir.path}/road_${_currentRideId}_${DateTime.now().millisecondsSinceEpoch}.mp4';
        await _roadRecorder!.start(path, videoTrack: _frontRoadStream!.getVideoTracks().first);
      }
      
      if (_interiorStream != null) {
        _interiorRecorder = MediaRecorder();
        final path = '${dir.path}/interior_${_currentRideId}_${DateTime.now().millisecondsSinceEpoch}.mp4';
        await _interiorRecorder!.start(path, videoTrack: _interiorStream!.getVideoTracks().first);
      }

      setState(() => _isRecording = true);
      debugPrint('📹 [DASHCAM] Recording started for Dual-Cam Grid');
    } catch (e) {
      debugPrint('❌ [DASHCAM] Start error: $e');
    }
  }

  Future<void> _stopAndUploadRecording() async {
    if (!_isRecording || _currentRideId == null) return;
    final rideToLink = _currentRideId;
    
    try {
      String? roadPath;
      String? interiorPath;

      if (_roadRecorder != null) {
         roadPath = await _roadRecorder!.stop();
         _roadRecorder = null;
      }
      if (_interiorRecorder != null) {
         interiorPath = await _interiorRecorder!.stop();
         _interiorRecorder = null;
      }

      setState(() => _isRecording = false);
      debugPrint('📼 [DASHCAM] Recording stopped. Initiating asynchronous upload...');

      // Run upload in background to not block UI
      if (rideToLink != null) {
        _uploadVideo(roadPath, 'road', rideToLink);
        _uploadVideo(interiorPath, 'interior', rideToLink);
      }
    } catch (e) {
      debugPrint('❌ [DASHCAM] Stop error: $e');
    }
  }

  Future<void> _uploadVideo(String? path, String type, String rideId) async {
    if (path == null) return;
    final file = File(path);
    if (!await file.exists()) return;

    try {
      final driverProvider = Provider.of<DriverProvider>(context, listen: false);
      final token = driverProvider.driver?['token'] ?? driverProvider.driver?['_id'] ?? '';
      
      final dio = dio_pkg.Dio();
      // Use dynamic baseUrl from ApiService to avoid hardcoding production URLs
      final baseUrl = ApiService.baseUrl.endsWith('/') 
          ? ApiService.baseUrl.substring(0, ApiService.baseUrl.length - 1)
          : ApiService.baseUrl;
          
      final uploadUrl = '$baseUrl/uploads';
      final associationUrl = '$baseUrl/rides';

      final formData = dio_pkg.FormData.fromMap({
        'file': await dio_pkg.MultipartFile.fromFile(path, filename: '${type}_$rideId.mp4'),
      });

      debugPrint('📤 [SURVEILLANCE] Archiving $type footage for ride $rideId...');
      
      final response = await dio.post(
        uploadUrl, 
        data: formData,
        options: dio_pkg.Options(
          headers: {
            'Authorization': 'Bearer $token',
          },
        ),
      );

      if (response.data['success'] == true) {
        final videoUrl = response.data['data']['url'];
        debugPrint('✅ [SURVEILLANCE] Upload successful: $videoUrl');

        // Association with Ride Document (Forensic Link)
        await dio.post(
          '$associationUrl/$rideId/recordings', 
          data: {
            'url': videoUrl,
            'type': type,
            'source': 'tablet',
            'metadata': {
              'size': response.data['data']['size'],
              'timestamp': DateTime.now().toIso8601String(),
              'device': 'tablet_dashboard'
            }
          },
          options: dio_pkg.Options(
            headers: {
              'Authorization': 'Bearer $token',
            },
          ),
        );
        debugPrint('🔗 [SURVEILLANCE] Forensic association complete for $type view');
      } else {
        debugPrint('❌ [SURVEILLANCE] Upload failed: ${response.data['message']}');
      }
    } catch (e) {
      debugPrint('❌ [SURVEILLANCE] Critical pipeline failure ($type): $e');
    }
  }

  void _stopSensors() {
     _frontRoadStream?.getTracks().forEach((t) => t.stop());
     _interiorStream?.getTracks().forEach((t) => t.stop());
     _frontRoadStream = null;
     _interiorStream = null;
     _localRenderer.srcObject = null;
     // Close all admin viewers
     for (var pc in _peerConnections.values) {
       pc.dispose();
     }
     _peerConnections.clear();
     if (mounted) setState(() {});
  }

  Future<void> _initBattery() async {
    final level = await _battery.batteryLevel;
    setState(() => _batteryLevel = level);
    _batterySubscription = _battery.onBatteryStateChanged.listen((_) async {
       final l = await _battery.batteryLevel;
       if (mounted) setState(() => _batteryLevel = l);
    });
  }

  Future<void> _initSensors() async {
    // 1. NETWORK
    final connectivity = Connectivity();
    final initial = await connectivity.checkConnectivity();
    _updateNetwork(initial);
    _connectivitySubscription = connectivity.onConnectivityChanged.listen(_updateNetwork);

    // 2. GPS
    final initialGps = await Geolocator.isLocationServiceEnabled();
    setState(() => _isGpsLocked = initialGps);
    _gpsSubscription = Geolocator.getServiceStatusStream().listen((status) {
       if (mounted) setState(() => _isGpsLocked = (status == ServiceStatus.enabled));
    });
  }

  void _updateNetwork(List<ConnectivityResult> results) {
    if (results.isEmpty || results.contains(ConnectivityResult.none)) {
       setState(() {
         _networkStatus = "OFFLINE";
         _networkIcon = Icons.signal_cellular_off_rounded;
         _networkColor = Colors.red;
       });
       return;
    }
    
    if (results.contains(ConnectivityResult.wifi)) {
       setState(() {
         _networkStatus = "WIFI ACTIVE";
         _networkIcon = Icons.wifi_rounded;
         _networkColor = Colors.blue;
       });
    } else {
       setState(() {
         _networkStatus = "MOBILE 5G"; // Default for professional fleet
         _networkIcon = Icons.signal_cellular_alt_rounded;
         _networkColor = Colors.green;
       });
    }
  }

  @override
  void dispose() {
    _locationSubscription?.cancel();
    _batterySubscription?.cancel();
    _gpsSubscription?.cancel();
    _connectivitySubscription?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _localRenderer.dispose();
    _interiorStream?.getTracks().forEach((t) => t.stop());
    _frontRoadStream?.getTracks().forEach((t) => t.stop());
    for (var pc in _peerConnections.values) {
      pc.dispose();
    }
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      debugPrint('🔄 [LIFECYCLE] App Resumed. Forcing state sync...');
      final provider = context.read<DriverProvider>();
      provider.syncProfile();
    }
  }

  void _startLocationTracking() async {
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) return;

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) return;
    }

    _locationSubscription = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(accuracy: LocationAccuracy.high, distanceFilter: 20),
    ).listen((Position pos) {
      _updateLiveJourneyStats(pos);
    });
  }

  void _updateLiveJourneyStats(Position pos) async {
    final provider = Provider.of<DriverProvider>(context, listen: false);
    final ride = provider.activeRide;
    if (ride == null) return;

    // TARGET DETERMINATION: If status is 'accepted/assigned/arrived' -> target is PICKUP
    // If status is 'started' -> target is DROP-OFF
    final status = ride['status']?.toString().toLowerCase() ?? 'accepted';
    
    LatLng target;
    if (status == 'started') {
       target = _parseLatLng(ride['drop']);
    } else {
       target = _parseLatLng(ride['pickup']);
    }

    try {
      final routeData = await MapplsService.getDrivingRoute(
        LatLng(pos.latitude, pos.longitude),
        target
      );

      if (routeData != null && routeData['routes'] != null && routeData['routes'].isNotEmpty) {
        final route = routeData['routes'][0];
        if (mounted) {
          setState(() {
            _liveDistance = (route['distance'] ?? 0.0) / 1000.0; // Meters to KM
            _liveDuration = (route['duration'] ?? 0.0) / 60.0;  // Seconds to Minutes
          });
        }
      }
    } catch (e) {
      debugPrint('⚠️ [STATS] Failed to update live journey stats: $e');
    }
  }

  LatLng _parseLatLng(dynamic loc) {
    if (loc is Map) {
       return LatLng(
         double.tryParse(loc['latitude']?.toString() ?? loc['lat']?.toString() ?? '0.0') ?? 0.0,
         double.tryParse(loc['longitude']?.toString() ?? loc['lng']?.toString() ?? '0.0') ?? 0.0
       );
    }
    return const LatLng(0, 0);
  }

  Future<void> _initCamera() async {
    try {
      final devices = await navigator.mediaDevices.enumerateDevices();
      final videoDevices = devices.where((device) => device.kind == 'videoinput').toList();
      debugPrint('🔍 [HARDWARE] Total Video Devices Found: ${videoDevices.length}');

      String? primaryCamId; 
      String? secondaryCamId;  

      if (videoDevices.isNotEmpty) {
        // 1. Identify Primary (Interior/Front-facing)
        for (var device in videoDevices) {
           String label = device.label.toLowerCase();
           if (label.contains('front') || label.contains('user') || label.contains('selfie')) {
             primaryCamId = device.deviceId;
             break;
           } 
        }
        
        // 2. Identify Secondary (USB/Road/External)
        for (var device in videoDevices) {
           String label = device.label.toLowerCase();
           if (device.deviceId == primaryCamId) continue;
           
           if (label.contains('usb') || label.contains('external') || label.contains('uvc')) {
              secondaryCamId = device.deviceId;
              break;
           }
        }

        // 3. Fallback: If still nothing assigned, use pure indices
        primaryCamId ??= videoDevices[0].deviceId;
        if (secondaryCamId == null && videoDevices.length > 1) {
           // If we have a second device and it's not the primary, use it as road cam
           for (var device in videoDevices) {
              if (device.deviceId != primaryCamId) {
                 secondaryCamId = device.deviceId;
                 break;
              }
           }
        }
        
        debugPrint('📹 [CAMERA] Final Setup: Primary=$primaryCamId, Secondary=$secondaryCamId');
      }

      // --- Primary Camera (Interior/Front) ---
      if (primaryCamId != null && _frontRoadStream == null) {
        final constraints = {
          'audio': false,
          'video': {
            'deviceId': primaryCamId,
            'facingMode': 'user',
            'width': {'ideal': 1280},
            'height': {'ideal': 720},
          }
        };
        _frontRoadStream = await navigator.mediaDevices.getUserMedia(constraints);
        _localRenderer.srcObject = _frontRoadStream;
        debugPrint('📹 [WEBRTC] Primary Tablet Camera Active');
      }

      // --- Secondary Camera (USB/Road) ---
      if (secondaryCamId != null && _interiorStream == null) {
        debugPrint('🔌 [USB] Initializing External Webcam...');
        final usbConstraints = {
          'audio': false,
          'video': {
            'deviceId': secondaryCamId,
            'facingMode': 'environment',
            'width': {'ideal': 1280},
            'height': {'ideal': 720},
          }
        };
        _interiorStream = await navigator.mediaDevices.getUserMedia(usbConstraints);
        debugPrint('📹 [WEBRTC] USB/Secondary Camera Active');
      } else if (secondaryCamId == null && _interiorStream != null) {
         // Cleanup if unplugged
         _interiorStream?.getTracks().forEach((t) => t.stop());
         _interiorStream = null;
         debugPrint('🛑 [USB] External Webcam disconnected');
      }

      if (mounted) setState(() {});
    } catch (e) {
      debugPrint('❌ [WEBRTC] Camera Init Fail: $e');
    }
  }

  Future<void> _checkPermissions() async {
    final status = await [
      Permission.camera,
      Permission.locationWhenInUse,
    ].request();

    if (status[Permission.camera] != PermissionStatus.granted) {
      if (!mounted) return;
      _showPermissionReason();
    } else {
      _initCamera();
    }
  }

  void _showPermissionReason() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
        title: Row(
          children: [
            const Icon(Icons.security_rounded, color: AppTheme.accent, size: 30),
            const SizedBox(width: 15),
            Text('SAFETY MONITORING', style: GoogleFonts.outfit(fontWeight: FontWeight.bold)),
          ],
        ),
        content: Text(
          'Fleet policies require active road and interior monitoring to ensure driver safety and professional compliance during all active rides.',
          style: GoogleFonts.outfit(fontSize: 16, color: AppTheme.secondaryText, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              openAppSettings();
            },
            child: Text('MANAGE SETTINGS', style: GoogleFonts.outfit(color: AppTheme.accent, fontWeight: FontWeight.bold)),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(context);
              _checkPermissions();
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.accent,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
            child: Text('RE-AUTHENTICATE', style: GoogleFonts.outfit(color: Colors.white, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  void _setupWebRTCSignaling() {
    final provider = Provider.of<DriverProvider>(context, listen: false);
    final socket = provider.socket;
    if (socket == null) return;

    final driverId = (provider.driver?['_id'] ?? provider.driver?['id'] ?? '').toString();
    final rideId = _extractId(provider.activeRide);

    // CRITICAL: Always join the driver room for persistent monitoring (even if idle)
    socket.emit('join_room', 'driver_$driverId');
    
    // Also join ride room if active
    if (rideId != null) {
      socket.emit('join_room', 'ride_$rideId');
      debugPrint('🔔 [WEBRTC] Tablet joining ride room: ride_$rideId');
    }
    debugPrint('📡 [WEBRTC] Tablet persistent room active: driver_$driverId');

    // 1. Stream Request from Admin (Works even if NOT in a ride)
    socket.off('request_webrtc_stream');
    socket.on('request_webrtc_stream', (data) async {
       final selfId = (provider.driver?['_id'] ?? provider.driver?['id'] ?? '').toString();
       
       
       // Handle specific type or all active tablet streams
       final adminSocketId = data['adminSocketId'] ?? 'unnamed_admin';
       final requestedType = data['type'];
       
       final typesHandle = (requestedType != null) 
          ? [requestedType] 
          : ['tablet_front_road', 'tablet_interior'];

       for (final type in typesHandle) {
          unawaited(
            () async {
              try {
                // Determine which camera stream we need
                if (type == 'tablet_front_road' && _frontRoadStream == null) await _initCamera();
                if (type == 'tablet_interior' && _interiorStream == null) await _initCamera();

                final key = '${adminSocketId}_$type';
                if (_peerConnections.containsKey(key)) {
                   await _peerConnections[key]?.dispose();
                   _peerConnections.remove(key);
                }

                final activeStream = (type == 'tablet_front_road') ? _frontRoadStream : _interiorStream;
                if (activeStream == null) return;

                final pc = await _createPeerConnection(type, adminSocketId, socket);
                _peerConnections[key] = pc;
                
                final offer = await pc.createOffer();
                await pc.setLocalDescription(offer);
                
                socket.emit('webrtc_offer', {
                   'rideId': _extractId(data['rideId']),
                   'type': type,
                   'sdp': offer.toMap(),
                   'targetSocketId': adminSocketId,
                   'driverId': selfId
                });
                debugPrint('📤 [WEBRTC] Offer Sent: $type -> $adminSocketId');
              } catch (_) {}
            }(),
          );
       }
    });

    // 3. Remote Hardware Lifecycle Control (Start/Stop command from Admin)
     socket.off('toggle_webrtc_stream');
     socket.on('toggle_webrtc_stream', (data) async {
        final status = data['status']; // 'on' or 'off'
        final targetType = data['type']; // which cam
        debugPrint('🔌 [REMOTE] Command: Toggle $targetType to $status');

        if (status == 'on') {
           await _initCamera(); 
           socket.emit('request_webrtc_stream', { 
             'driverId': driverId, 
             'adminSocketId': data['adminSocketId'],
             'type': targetType 
           });
        } else {
           if (targetType == 'tablet_front_road') {
              _frontRoadStream?.getTracks().forEach((t) => t.stop());
              _frontRoadStream = null;
           } else if (targetType == 'tablet_interior') {
              _interiorStream?.getTracks().forEach((t) => t.stop());
              _interiorStream = null;
           } else {
              _stopSensors(); 
           }
           if (mounted) setState(() {});
        }
     });

     // 2. Answer from Admin
     socket.off('webrtc_answer');
     socket.on('webrtc_answer', (data) async {
        final adminId = data['adminSocketId'] ?? data['senderSocketId'];
        final type = data['type'];
        final key = '${adminId}_$type';
        
        final pc = _peerConnections[key];
        if (pc != null && data['sdp'] != null) {
           final sdp = RTCSessionDescription(data['sdp']['sdp'], data['sdp']['type']);
           await pc.setRemoteDescription(sdp);
        }
     });

     // 3. ICE from Admin
     socket.off('webrtc_ice_candidate');
     socket.on('webrtc_ice_candidate', (data) async {
        final adminId = data['senderSocketId'] ?? data['adminSocketId'];
        final type = data['type'];
        final key = '${adminId}_$type';
        
        final pc = _peerConnections[key];
        if (pc != null && data['candidate'] != null) {
           final cand = RTCIceCandidate(
              data['candidate']['candidate'],
              data['candidate']['sdpMid'],
              data['candidate']['sdpMLineIndex']
           );
           await pc.addCandidate(cand);
        }
     });
  }

  Future<RTCPeerConnection> _createPeerConnection(String type, String adminId, dynamic socket) async {
    final pc = await createPeerConnection({
      "iceServers": [{"urls": "stun:stun.l.google.com:19302"}],
      "sdpSemantics": "unified-plan",
    });
    
    pc.onIceCandidate = (cand) {
      if (cand.candidate != null) {
         socket.emit('webrtc_ice_candidate', {
           'targetSocketId': adminId,
           'target': 'admin',
           'rideId': _extractId(Provider.of<DriverProvider>(context, listen: false).activeRide),
           'type': type,
           'candidate': cand.toMap(),
         });
      }
    };
    
    final stream = type == 'tablet_interior' ? _interiorStream : _frontRoadStream;
    if (stream != null) {
      for (var track in stream.getVideoTracks()) {
         pc.addTrack(track, stream);
      }
    }
    return pc;
  }

  String? _extractId(dynamic data) {
    if (data == null) return null;
    if (data is String) return data;
    if (data is Map) return (data['_id'] ?? data['id']).toString();
    return data.toString();
  }

  String _getPickupStr(Map<String, dynamic> ride) {
    if (ride['pickup'] is Map) return ride['pickup']['address'] ?? 'Current Location';
    return ride['pickupAddress'] ?? 'Current Location';
  }

  String _getDropStr(Map<String, dynamic> ride) {
    if (ride['drop'] is Map) return ride['drop']['address'] ?? 'Destination';
    return ride['dropAddress'] ?? 'Destination';
  }

  String _getCustomerName(Map<String, dynamic> ride) {
    if (ride['userId'] is Map) {
      return ride['userId']['name'] ?? 'Passenger';
    }
    return ride['customerName'] ?? 'Passenger';
  }

  void _updateMapOverlays() async {
    if (_mapController == null) return;
    final ride = Provider.of<DriverProvider>(context, listen: false).activeRide;
    
    // 1. CLEAR EXISTING
    await _clearOverlays();
    
    if (ride == null) return;
    
    // 2. ADD MARKERS (Pickup/Drop)
    final pickup = ride['pickup'] ?? ride['pickupAddress'];
    final drop = ride['drop'] ?? ride['dropAddress'];
    
    if (pickup is Map && pickup['lat'] != null) {
      _pickupSymbol = await _mapController!.addSymbol(SymbolOptions(
        geometry: LatLng(double.tryParse('${pickup['lat']}') ?? 0, double.tryParse('${pickup['lng']}') ?? 0),
        iconImage: 'pickup_marker',
        iconSize: 0.8,
      ));
    }
    
    if (drop is Map && drop['lat'] != null) {
      _dropSymbol = await _mapController!.addSymbol(SymbolOptions(
        geometry: LatLng(double.tryParse('${drop['lat']}') ?? 0, double.tryParse('${drop['lng']}') ?? 0),
        iconImage: 'drop_marker',
        iconSize: 0.8,
      ));
    }
    
    // 3. DRAW ROUTE
    _drawRoute(ride);
  }

  Future<void> _clearOverlays() async {
    if (_mapController == null) return;
    if (_routeLine != null) await _mapController!.removeLine(_routeLine!);
    for (var l in _trafficLines) {
      await _mapController!.removeLine(l);
    }
    _trafficLines.clear();
    if (_pickupSymbol != null) await _mapController!.removeSymbol(_pickupSymbol!);
    if (_dropSymbol != null) await _mapController!.removeSymbol(_dropSymbol!);
    _routeLine = null;
    _pickupSymbol = null;
    _dropSymbol = null;
  }

  void _drawRoute(Map<String, dynamic> ride) async {
    if (_mapController == null) return;
    
    final currentPos = await Geolocator.getCurrentPosition();
    final start = {'lat': currentPos.latitude, 'lng': currentPos.longitude};
    
    final status = ride['status']?.toString().toLowerCase();
    final isArrived = status == 'arrived' || status == 'started' || status == 'ongoing';
    final target = (status == 'accepted' || status == 'assigned') ? ride['pickup'] : (isArrived ? ride['drop'] : null);
    
    if (target != null) {
      final routeData = await MapplsService.getRouteBetweenSelections(start, target);
      if (routeData != null) {
        _routePoints = routeData['points'];
        _trafficSegments = routeData['trafficSegments'];
        
        // Casing Line (Dark Blue)
        _routeLine = await _mapController!.addLine(LineOptions(
           geometry: _routePoints,
           lineColor: "#00008B",
           lineWidth: 12.0,
           lineOpacity: 0.8,
           lineJoin: "round",
        ));

        // Core / Traffic Lines
        for (var segment in _trafficSegments) {
           final line = await _mapController!.addLine(LineOptions(
             geometry: segment['points'],
             lineColor: _lineColorHex(segment['color']),
             lineWidth: 6.0,
             lineJoin: "round",
           ));
           _trafficLines.add(line);
        }

        // Fit Camera
        if (_routePoints.isNotEmpty) {
          _mapController!.animateCamera(CameraUpdate.newLatLngBounds(
            LatLngBounds(
              southwest: LatLng(
                _routePoints.map((p) => p.latitude).reduce((a, b) => a < b ? a : b),
                _routePoints.map((p) => p.longitude).reduce((a, b) => a < b ? a : b)
              ),
              northeast: LatLng(
                _routePoints.map((p) => p.latitude).reduce((a, b) => a > b ? a : b),
                _routePoints.map((p) => p.longitude).reduce((a, b) => a > b ? a : b)
              ),
            ),
            left: 200, right: 100, top: 100, bottom: 400
          ));
        }
      }
    }
  }

  String _lineColorHex(Color color) {
    return '#${color.value.toRadixString(16).padLeft(8, '0').substring(2).toUpperCase()}';
  }

  String _formatNum(dynamic val, {int decimals = 1}) {
    if (val == null) return "0";
    double d = double.tryParse(val.toString()) ?? 0.0;
    if (d == 0) return "0";
    return d.toStringAsFixed(decimals);
  }

  @override
  Widget build(BuildContext context) {
    final driverProvider = Provider.of<DriverProvider>(context);
    final ride = driverProvider.activeRide;
    
    // 🔥 FORCE SCREEN TO STAY ON DURING RIDE
    if (ride != null) {
      WakelockPlus.enable();
    } else {
      WakelockPlus.disable();
    }

    final driver = driverProvider.driver;
    final incomingRequest = driverProvider.incomingRideRequest;
    final bool hasOngoingRide = ride != null;

    return Scaffold(
      backgroundColor: AppTheme.background,
      body: !driverProvider.isInitialized 
        ? _buildLoadingUI() 
        : hasOngoingRide 
          ? _buildOngoingRideUI(ride, driver, driverProvider.photoVersion, driverProvider)
          : Stack(
              children: [
                // 1. DYNAMIC BACKGROUND MAP (Only in idle/empty state)
                Positioned.fill(
                  child: MapplsMap(
                    initialCameraPosition: const CameraPosition(target: LatLng(23.0225, 72.5714), zoom: 12),
                    onMapCreated: (c) => _mapController = c,
                    onStyleLoadedCallback: _updateMapOverlays,
                    myLocationEnabled: true,
                    myLocationTrackingMode: MyLocationTrackingMode.none,
                  ),
                ),
                
                // Subtle Map Fade (Bottom Edge)
                Positioned(
                  bottom: 0, left: 0, right: 0, height: 150,
                  child: Container(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.bottomCenter,
                        end: Alignment.topCenter,
                        colors: [Colors.white.withOpacity(0.9), Colors.white.withOpacity(0)],
                      ),
                    ),
                  ),
                ),
      
                // 2. EMPTY STATE
                _buildEmptyStateUI(),
      
                // 3. TOP BAR
                _buildStatusBar(null),
      
                // 4. ACTION DOCK
                _buildActionDock(driverProvider),
      
                // 5. INCOMING POPUP
                if (incomingRequest != null) _buildIncomingRequestOverlay(incomingRequest),
              ],
            ),
    );
  }

  Widget _buildLoadingUI() {
    return Container(
      width: double.infinity, height: double.infinity,
      decoration: const BoxDecoration(
        color: AppTheme.background,
        image: DecorationImage(
          image: NetworkImage('https://images.unsplash.com/photo-1614850523296-d8c1af93d400?q=80&w=2070'),
          fit: BoxFit.cover, opacity: 0.05,
        ),
      ),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(color: AppTheme.accent, strokeWidth: 2),
            const SizedBox(height: 30),
            Text('SYNCING ENGINE', style: GoogleFonts.outfit(fontSize: 14, fontWeight: FontWeight.w800, letterSpacing: 4, color: AppTheme.accent)),
            const SizedBox(height: 10),
            Text('RESTORING SECURE SESSION', style: GoogleFonts.outfit(fontSize: 10, fontWeight: FontWeight.normal, letterSpacing: 2, color: AppTheme.secondaryText)),
          ],
        ).animate().fadeIn(duration: 800.ms).scale(begin: const Offset(0.9, 0.9)),
      ),
    );
  }

  Widget _buildIncomingRequestOverlay(Map<String, dynamic> request) {
    return Positioned.fill(
      child: Container(
        color: Colors.black.withOpacity(0.1),
        child: Center(
          child: Container(
            width: 550,
            padding: const EdgeInsets.all(40),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(40),
              border: Border.all(color: AppTheme.accent.withOpacity(0.3), width: 2),
              boxShadow: [
                BoxShadow(color: AppTheme.accent.withOpacity(0.2), blurRadius: 40, spreadRadius: 10)
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.notifications_active_rounded, size: 80, color: AppTheme.accent),
                const SizedBox(height: 30),
                Text('NEW RIDE REQUEST', style: GoogleFonts.outfit(fontSize: 32, fontWeight: FontWeight.bold, letterSpacing: 2)),
                const SizedBox(height: 40),
                _statRow("CUSTOMER", request['customerName'] ?? 'Passenger', fontSize: 24),
                _statRow("PICKUP", request['pickupAddress'] ?? 'Nearby', fontSize: 18),
                _statRow("DISTANCE", "${request['distance'] ?? '2.4'} km", fontSize: 18),
                const SizedBox(height: 50),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () {}, 
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 25),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                        ),
                        child: const Text('DECLINE', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
                      ),
                    ),
                    const SizedBox(width: 25),
                    Expanded(
                      child: ElevatedButton(
                        onPressed: () {
                          context.read<DriverProvider>().acceptRide(request['_id']);
                        },
                        style: ElevatedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 25),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                        ),
                        child: const Text('ACCEPT RIDE', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildOngoingRideUI(Map<String, dynamic> ride, Map<String, dynamic>? driver, int photoVersion, DriverProvider provider) {
    bool isLandscape = MediaQuery.of(context).orientation == Orientation.landscape;

    final driverCard = Container(
      padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 60),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(30),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 30, spreadRadius: 5)],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.max,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
           Container(
            padding: const EdgeInsets.all(4),
            decoration: const BoxDecoration(color: AppTheme.accent, shape: BoxShape.circle),
            child: CircleAvatar(
              radius: 90,
              backgroundColor: Colors.grey[200],
              backgroundImage: NetworkImage(_getDriverImage(driver, version: photoVersion)),
            ),
          ),
          const SizedBox(height: 35),
          Text(driver?['name']?.toUpperCase() ?? 'DRIVER PROFILE', style: GoogleFonts.outfit(fontSize: 28, fontWeight: FontWeight.bold, color: AppTheme.primaryText)),
          const SizedBox(height: 10),
          const Text('AUTHORIZED PROFESIONAL • SYSTEM READY', style: TextStyle(color: AppTheme.accent, letterSpacing: 3, fontSize: 11, fontWeight: FontWeight.bold)),
          const SizedBox(height: 50),
          _profileLine("ID Serial", (driver?['_id'] ?? driver?['id'] ?? 'D-42412').toString().substring(0, 8).toUpperCase(), fontSize: 18),
          _profileLine("Vehicle Plate", driver?['vehicle']?['plate'] ?? driver?['vehicleNo'] ?? driver?['plate'] ?? "DB 421", fontSize: 18),
          _profileLine("License No.", driver?['licenseNo'] ?? driver?['license'] ?? "L-9021", fontSize: 18),
          const SizedBox(height: 30),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            decoration: BoxDecoration(color: Colors.blue.withOpacity(0.08), borderRadius: BorderRadius.circular(15)),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.security_rounded, color: Colors.blue, size: 20),
                const SizedBox(width: 12),
                Text('VERIFIED TAXI HUB SESSION', style: GoogleFonts.outfit(color: Colors.blue, fontSize: 12, fontWeight: FontWeight.bold, letterSpacing: 1.5)),
              ],
            ),
          ),
        ],
      ),
    ).animate().fadeIn(duration: 600.ms).slideX(begin: -0.05);

    final journeyCard = Container(
      padding: const EdgeInsets.symmetric(horizontal: 30, vertical: 40),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(30),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 30, spreadRadius: 5)],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.max,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('ACTIVE JOURNEY INFO', style: TextStyle(color: AppTheme.secondaryText, fontSize: 12, fontWeight: FontWeight.w800, letterSpacing: 3)),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                decoration: BoxDecoration(color: AppTheme.accent.withOpacity(0.1), borderRadius: BorderRadius.circular(20)),
                child: const Text('LIVE TRIP', style: TextStyle(color: AppTheme.accent, fontSize: 10, fontWeight: FontWeight.w900)),
              )
            ],
          ),
          const SizedBox(height: 10),
          const Text('ESTIMATED FARE', style: TextStyle(color: AppTheme.secondaryText, fontSize: 14, fontWeight: FontWeight.bold, letterSpacing: 2)),
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text('₹', style: GoogleFonts.outfit(fontSize: 32, fontWeight: FontWeight.w400, color: AppTheme.accent)),
              const SizedBox(width: 10),
              Text('${ride['fare'] ?? '342.00'}', style: GoogleFonts.outfit(fontSize: 90, fontWeight: FontWeight.bold, letterSpacing: -2, color: AppTheme.primaryText)),
            ],
          ),
          const Divider(height: 60, color: AppTheme.divider),
          _statRow("CURRENT CUSTOMER", _getCustomerName(ride), fontSize: 24),
          const SizedBox(height: 20),
          _statRow("PICKUP", _getPickupStr(ride), fontSize: 18),
          _statRow("DROP-OFF", _getDropStr(ride), fontSize: 18),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(child: _miniStat("DISTANCE", "${_formatNum(_liveDistance > 0 ? _liveDistance : ride['distance'])} km")),
              const SizedBox(width: 20),
              Expanded(child: _miniStat("DURATION", "${_formatNum(_liveDuration > 0 ? _liveDuration : ride['duration'])} min")),
            ],
          ),
          const SizedBox(height: 30),
          // Camera System Live View Placeholder / Indicator
        ],
      ),
    ).animate().fadeIn(duration: 600.ms, delay: 200.ms).slideX(begin: 0.05);

    return Container(
      width: double.infinity,
      height: double.infinity,
      color: const Color(0xFFF8FAFC),
      child: Column(
        children: [
          // 1. TOP BAR (Integrated)
          _buildHeroStatusBar(ride),

          // 2. MAIN MISSION CONTROL (Flexible & Scrollable)
          Expanded(
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: isLandscape ? 40 : 20, vertical: 10),
              child: SingleChildScrollView(
                physics: const BouncingScrollPhysics(),
                child: isLandscape 
                  ? IntrinsicHeight(
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                           Expanded(flex: 2, child: driverCard),
                           const SizedBox(width: 40),
                           Expanded(flex: 3, child: journeyCard),
                        ],
                      ),
                    )
                  : Column(
                      children: [
                        driverCard,
                        const SizedBox(height: 20),
                        journeyCard,
                      ],
                    ),
              ),
            ),
          ),

          // 3. ACTION DOCK (Integrated)
          _buildHeroActionDock(provider),
          const SizedBox(height: 30),
        ],
      ),
    );
  }

  Widget _buildHeroStatusBar(Map<String, dynamic>? ride) {
    bool isLandscape = MediaQuery.of(context).orientation == Orientation.landscape;
    double p = isLandscape ? 40 : 20;

    return Padding(
      padding: EdgeInsets.fromLTRB(p, p, p, 0),
      child: isLandscape 
        ? Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _heroStatusLeft(ride),
              _heroStatusRight(),
            ],
          )
        : Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  _statusChip(Icons.signal_cellular_alt_rounded, "5G", Colors.green),
                  _statusChip(_batteryLevel > 20 ? Icons.battery_charging_full_rounded : Icons.battery_alert_rounded, "$_batteryLevel%", _batteryLevel > 20 ? Colors.blueGrey : Colors.red),
                  Text(_getCurrentTime(), style: GoogleFonts.outfit(fontSize: 24, fontWeight: FontWeight.bold, color: AppTheme.primaryText)),
                ],
              ),
              const SizedBox(height: 15),
              _heroStatusLeft(ride),
            ],
          ),
    );
  }

  Widget _heroStatusLeft(Map<String, dynamic>? ride) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('VEHICLE STATUS: ACTIVE', style: TextStyle(color: AppTheme.accent, fontWeight: FontWeight.bold, fontSize: 11, letterSpacing: 1.5)),
        const SizedBox(height: 5),
        Text(ride != null ? 'TRIP TO: ${_getDropStr(ride)}' : 'SYSTEM READY', style: GoogleFonts.outfit(fontSize: 20, fontWeight: FontWeight.bold, color: AppTheme.primaryText)),
      ],
    );
  }

  Widget _heroStatusRight() {
    return Row(
      children: [
         _statusChip(Icons.signal_cellular_alt_rounded, "5G ACTIVE", Colors.green),
         const SizedBox(width: 15),
         _statusChip(Icons.gps_fixed_rounded, "GPS LOCK", Colors.blue),
         const SizedBox(width: 15),
         _statusChip(
           _batteryLevel > 20 ? Icons.battery_charging_full_rounded : Icons.battery_alert_rounded,
           "$_batteryLevel%",
           _batteryLevel > 20 ? Colors.blueGrey : Colors.red,
         ),
         const SizedBox(width: 30),
         Text(_getCurrentTime(), style: GoogleFonts.outfit(fontSize: 32, fontWeight: FontWeight.bold, color: AppTheme.primaryText)),
      ],
    );
  }

  Widget _buildHeroActionDock(DriverProvider provider) {
    final ride = provider.activeRide;
    String actionLabel = "COMPLETE";
    IconData actionIcon = Icons.check_circle_rounded;
    Color actionColor = Colors.blue;
    String nextStatus = "completed";

    if (ride != null) {
      final status = ride['status']?.toString().toLowerCase();
      if (status == 'accepted' || status == 'assigned') {
        actionLabel = "ARRIVED";
        actionIcon = Icons.location_on_rounded;
        actionColor = Colors.orange;
        nextStatus = "arrived";
      } else if (status == 'arrived') {
        actionLabel = "START TRIP";
        actionIcon = Icons.play_arrow_rounded;
        actionColor = Colors.green;
        nextStatus = "started";
      }
    }

    return Center(
      child: Container(
        padding: const EdgeInsets.all(8),
        margin: const EdgeInsets.symmetric(horizontal: 20),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(100),
          boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.12), blurRadius: 40, offset: const Offset(0, 15))],
          border: Border.all(color: AppTheme.divider.withOpacity(0.5)),
        ),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _dockBtn(Icons.navigation_rounded, "NAV", AppTheme.secondaryText, onTap: () {}),
              const SizedBox(width: 8),
              _dockBtn(Icons.call_rounded, "CALL", AppTheme.secondaryText, onTap: () {}),
              const SizedBox(width: 8),
              _dockBtn(Icons.warning_amber_rounded, "SOS", Colors.redAccent, onTap: () {
                _showBreakdownConfirm(provider);
              }),
              const SizedBox(width: 15),
              _dockBtn(actionIcon, actionLabel, actionColor, isPrimary: true, onTap: () async {
                 final success = await provider.updateRideStatus(nextStatus);
                 if (success && mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Status updated to $nextStatus'), backgroundColor: Colors.green),
                    );
                 }
              }),
            ],
          ),
        ),
      ),
    );
  }

  Widget _miniStat(String label, String value) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(color: const Color(0xFFF1F5F9), borderRadius: BorderRadius.circular(20)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(color: AppTheme.secondaryText, fontSize: 10, fontWeight: FontWeight.w800, letterSpacing: 1.5)),
          const SizedBox(height: 8),
          Text(value, style: GoogleFonts.outfit(fontSize: 22, fontWeight: FontWeight.bold, color: AppTheme.primaryText)),
        ],
      ),
    );
  }

  Widget _buildEmptyStateUI() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.map_rounded, size: 120, color: AppTheme.divider),
          const SizedBox(height: 30),
          Text('WAITING FOR NEXT TRIP', style: GoogleFonts.outfit(fontSize: 32, fontWeight: FontWeight.bold, color: AppTheme.secondaryText, letterSpacing: 4)),
          const SizedBox(height: 10),
          const Text('STAY IN ACTIVE ZONE FOR FASTER BOOKINGS', style: TextStyle(color: AppTheme.accent, fontWeight: FontWeight.bold, letterSpacing: 2, fontSize: 13)),
        ],
      ),
    );
  }

  Widget _buildStatusBar(Map<String, dynamic>? ride) {
    return Positioned(
      top: 40, left: 40, right: 40,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('VEHICLE STATUS: ACTIVE', style: TextStyle(color: AppTheme.accent, fontWeight: FontWeight.bold, fontSize: 13, letterSpacing: 1.5)),
              const SizedBox(height: 5),
              Text(ride != null ? 'TRIP TO: ${_getDropStr(ride)}' : 'SYSTEM READY', style: GoogleFonts.outfit(fontSize: 24, fontWeight: FontWeight.bold, color: AppTheme.primaryText)),
            ],
          ),
          Row(
            children: [
               _statusChip(_networkIcon, _networkStatus, _networkColor),
               const SizedBox(width: 15),
               _statusChip(Icons.gps_fixed_rounded, _isGpsLocked ? "GPS LOCK" : "GPS SEARCHING", _isGpsLocked ? Colors.blue : Colors.orange),
               const SizedBox(width: 15),
               _statusChip(
                 _batteryLevel > 20 ? Icons.battery_charging_full_rounded : Icons.battery_alert_rounded,
                 "$_batteryLevel%",
                 _batteryLevel > 20 ? Colors.blueGrey : Colors.red,
               ),
               const SizedBox(width: 30),
               Text(_getCurrentTime(), style: GoogleFonts.outfit(fontSize: 32, fontWeight: FontWeight.bold, color: AppTheme.primaryText)),
            ],
          )
        ],
      ),
    );
  }

  String _getCurrentTime() {
    final now = DateTime.now();
    return "${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')} ${now.hour >= 12 ? 'PM' : 'AM'}";
  }

  Widget _statusChip(IconData icon, String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12), border: Border.all(color: AppTheme.divider)),
      child: Row(
        children: [
          Icon(icon, color: color, size: 18),
          const SizedBox(width: 10),
          Text(label, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: AppTheme.secondaryText, letterSpacing: 1)),
        ],
      ),
    );
  }

  Widget _buildActionDock(DriverProvider provider) {
    final ride = provider.activeRide;
    String actionLabel = "COMPLETE";
    IconData actionIcon = Icons.check_circle_rounded;
    Color actionColor = Colors.blue;
    String nextStatus = "completed";

    if (ride != null) {
      final status = ride['status']?.toString().toLowerCase();
      if (status == 'accepted' || status == 'assigned') {
        actionLabel = "ARRIVED";
        actionIcon = Icons.location_on_rounded;
        actionColor = Colors.orange;
        nextStatus = "arrived";
      } else if (status == 'arrived') {
        actionLabel = "START TRIP";
        actionIcon = Icons.play_arrow_rounded;
        actionColor = Colors.green;
        nextStatus = "started";
      }
    }

    return Positioned(
      bottom: 40, left: 0, right: 0,
      child: Center(
        child: Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(100),
            boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.12), blurRadius: 40, offset: const Offset(0, 15))],
            border: Border.all(color: AppTheme.divider.withOpacity(0.5)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _dockBtn(Icons.navigation_rounded, "NAVIGATE", AppTheme.secondaryText, onTap: () {}),
              const SizedBox(width: 12),
              _dockBtn(Icons.call_rounded, "SUPPORT", AppTheme.secondaryText, onTap: () {}),
              const SizedBox(width: 12),
              _dockBtn(Icons.warning_amber_rounded, "SOS BREAKDOWN", Colors.redAccent, onTap: () {
                _showBreakdownConfirm(provider);
              }),
              const SizedBox(width: 25),
              _dockBtn(actionIcon, actionLabel, actionColor, isPrimary: true, onTap: () async {
                 final success = await provider.updateRideStatus(nextStatus);
                 if (success && mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Status updated to $nextStatus'), backgroundColor: Colors.green),
                    );
                 }
              }),
            ],
          ),
        ),
      ),
    );
  }

  void _showBreakdownConfirm(DriverProvider provider) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('REPORT BREAKDOWN?'),
        content: const Text('This will alert the admin and notify the customer.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('CANCEL')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () {
              provider.reportBreakdown();
              Navigator.pop(ctx);
            }, 
            child: const Text('REPORT EMERGENCY', style: TextStyle(color: Colors.white))
          ),
        ],
      )
    );
  }

  Widget _dockBtn(IconData icon, String label, Color color, {bool isPrimary = false, VoidCallback? onTap}) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        constraints: BoxConstraints(minWidth: isPrimary ? 200 : 140),
        padding: const EdgeInsets.symmetric(horizontal: 25, vertical: 12),
        decoration: BoxDecoration(
          color: isPrimary ? color : AppTheme.background,
          borderRadius: BorderRadius.circular(100),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: isPrimary ? Colors.white : color, size: 22),
            const SizedBox(width: 12),
            Text(label, style: TextStyle(color: isPrimary ? Colors.white : AppTheme.primaryText, fontWeight: FontWeight.bold, fontSize: 13, letterSpacing: 1.2)),
          ],
        ),
      ),
    );
  }

  Widget _statRow(String label, String value, {double fontSize = 16}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(color: AppTheme.secondaryText, fontSize: 12, fontWeight: FontWeight.bold, letterSpacing: 1)),
          const SizedBox(width: 40),
          Expanded(child: Text(value, textAlign: TextAlign.right, style: GoogleFonts.outfit(fontSize: fontSize, fontWeight: FontWeight.bold, color: AppTheme.primaryText), overflow: TextOverflow.ellipsis)),
        ],
      ),
    );
  }

  Widget _profileLine(String label, String value, {double fontSize = 14}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: TextStyle(color: AppTheme.secondaryText, fontSize: fontSize - 2, fontWeight: FontWeight.w600)),
          Text(value, style: TextStyle(color: AppTheme.primaryText, fontSize: fontSize, fontWeight: FontWeight.bold, fontFamily: 'monospace')),
        ],
      ),
    );
  }

  String _getDriverImage(dynamic driverData, {int? version}) {
    if (driverData == null) return 'https://plus.unsplash.com/premium_photo-1689551332255-1b72eff78c98?w=500';
    String? url;
    if (driverData is Map) {
      url = (driverData['image'] ?? driverData['avatar'] ?? driverData['profileImage'] ?? driverData['url'])?.toString();
    } else if (driverData is String) {
      url = driverData;
    }
    
    if (url == null || url.isEmpty) return 'https://plus.unsplash.com/premium_photo-1689551332255-1b72eff78c98?w=500';
    
    String fullUrl = url;
    if (!url.startsWith('http')) {
      const base = 'https://taxi-back-rnci.onrender.com/';
      final cleanPath = url.startsWith('/') ? url.substring(1) : url;
      fullUrl = '$base$cleanPath';
    }

    if (version != null && fullUrl.contains('uploads/')) {
       final sep = fullUrl.contains('?') ? '&' : '?';
       return '$fullUrl${sep}v=$version';
    }
    return fullUrl;
  }
}
