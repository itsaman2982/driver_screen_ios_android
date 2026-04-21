import 'package:driverscreen/src/core/utils/app_logger.dart';
import 'package:socket_io_client/socket_io_client.dart' as io;
import 'package:driverscreen/src/core/api/api_service.dart';

class SocketService {
  io.Socket? _socket;
  io.Socket? get socket => _socket;

  void connect(String driverId) {
    if (_socket != null && _socket!.connected) return;

    final baseUrl = ApiService.baseUrl.replaceAll('/api/', '');
    
    _socket = io.io(
      baseUrl,
      io.OptionBuilder()
          .setTransports(['websocket'])
          .disableAutoConnect()
          .setExtraHeaders({
            'driver-id': driverId,
            'client-type': 'driverscreen'
          })
          .build(),
    );

    _socket!.connect();

    _socket!.onConnect((_) {
      AppLogger.info('🚀 [SOCKET] Connected to Backend');
      // Join general channels
      _socket!.emit('join_room', 'driver_$driverId');
      _socket!.emit('join_room', 'drivers_global');
      _socket!.emit('join_room', 'admin_global'); // For fleet sync
    });

    _socket!.onDisconnect((_) => AppLogger.info('🔌 [SOCKET] Disconnected'));
    _socket!.onConnectError((err) => AppLogger.info('⚠️ [SOCKET] Connection Error: $err'));
  }

  void joinRideRoom(String rideId) {
    if (_socket != null && _socket!.connected) {
       AppLogger.info('📍 [SOCKET] Joining Ride Room: ride_$rideId');
       _socket!.emit('join_room', 'ride_$rideId');
    }
  }

  void leaveRideRoom(String rideId) {
    if (_socket != null && _socket!.connected) {
       _socket!.emit('leave_room', 'ride_$rideId');
    }
  }

  void disconnect() {
    _socket?.disconnect();
    _socket?.dispose();
    _socket = null;
  }

  void on(String event, Function(dynamic) handler) {
    _socket?.on(event, handler);
  }

  void off(String event) {
    _socket?.off(event);
  }

  void emit(String event, dynamic data) {
    _socket?.emit(event, data);
  }
}
