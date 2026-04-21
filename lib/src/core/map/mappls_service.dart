import 'package:driverscreen/src/core/utils/app_logger.dart';
import 'package:flutter/material.dart';
import 'package:dio/dio.dart';
import 'package:mappls_gl/mappls_gl.dart';
import 'package:driverscreen/src/core/map/mappls_config.dart';

class MapplsService {
  static final Dio _dio = Dio();
  static String? _accessToken;
  static DateTime? _tokenExpiry;

  static Future<String?> _getAccessToken() async {
    if (_accessToken != null && _tokenExpiry != null && DateTime.now().isBefore(_tokenExpiry!)) {
      return _accessToken;
    }
    try {
      final response = await _dio.post(
        'https://outpost.mappls.com/api/security/oauth/token',
        data: {
          'grant_type': 'client_credentials',
          'client_id': MapplsConfig.atlasClientId,
          'client_secret': MapplsConfig.atlasClientSecret,
        },
        options: Options(
          contentType: 'application/x-www-form-urlencoded',
          headers: {'Accept': 'application/json'},
        ),
      );
      if (response.statusCode == 200 && response.data != null) {
        _accessToken = response.data['access_token']?.toString();
        final expiresIn = int.tryParse('${response.data['expires_in'] ?? 86400}') ?? 86400;
        _tokenExpiry = DateTime.now().add(Duration(seconds: expiresIn - 60));
        return _accessToken;
      }
    } catch (e) {
      AppLogger.info('Mappls OAuth error: $e');
    }
    return null;
  }

  static Future<Map<String, dynamic>?> getRouteBetweenSelections(
    Map<String, dynamic> start,
    Map<String, dynamic> end, {
    bool alternatives = false,
  }) async {
    final startLat = double.tryParse('${start['lat'] ?? ''}') ?? 0.0;
    final startLng = double.tryParse('${start['lng'] ?? ''}') ?? 0.0;
    final endLat = double.tryParse('${end['lat'] ?? ''}') ?? 0.0;
    final endLng = double.tryParse('${end['lng'] ?? ''}') ?? 0.0;
    
    final startToken = '$startLng,$startLat';
    final endToken = '$endLng,$endLat';

    try {
      final token = await _getAccessToken();
      if (token == null) return null;

      final response = await _dio.get(
        'https://apis.mappls.com/advancedmaps/v1/${MapplsConfig.restApiKey}/route_adv/driving/$startToken;$endToken',
        queryParameters: {
          'geometries': 'geojson',
          'overview': 'full',
          'alternatives': alternatives,
          'steps': false,
          'annotations': 'speed',
        },
        options: Options(
          headers: {'Authorization': 'bearer $token'},
        ),
      );

      if (response.statusCode == 200 && response.data != null) {
        return _parseRouteResponse(Map<String, dynamic>.from(response.data as Map), alternatives);
      }
    } catch (e) {
      AppLogger.info('Mappls route error: $e');
    }
    return null;
  }

  static Map<String, dynamic>? _parseRouteResponse(Map<String, dynamic> data, bool alternatives) {
    final routes = data['routes'];
    if (routes is! List || routes.isEmpty) return null;

    final primaryRoute = Map<String, dynamic>.from(routes.first as Map);
    final coordinates = primaryRoute['geometry']?['coordinates'] as List?;
    if (coordinates == null) return null;

    final points = coordinates
        .whereType<List>()
        .where((c) => c.length >= 2)
        .map((c) => LatLng((c[1] as num).toDouble(), (c[0] as num).toDouble()))
        .toList();

    final trafficSegments = <Map<String, dynamic>>[];
    try {
      final speeds = primaryRoute['legs']?[0]?['annotation']?['speed'] as List?;
      if (speeds != null) {
        for (var i = 0; i < points.length - 1 && i < speeds.length; i++) {
          final speed = (speeds[i] as num).toDouble();
          var color = Colors.blue;
          if (speed < 15) {
            color = Colors.red;
          } else if (speed < 25) {
            color = Colors.orange;
          }
          trafficSegments.add({'points': [points[i], points[i + 1]], 'color': color});
        }
      }
    } catch (_) {}

    return {
      'points': points,
      'distance': (primaryRoute['distance'] as num?)?.toDouble() ?? 0,
      'duration': (primaryRoute['duration'] as num?)?.toDouble() ?? 0,
      'trafficSegments': trafficSegments,
    };
  }

  static Future<Map<String, dynamic>?> getDrivingRoute(LatLng start, LatLng end) async {
    return getRouteBetweenSelections(
      {'lat': start.latitude, 'lng': start.longitude},
      {'lat': end.latitude, 'lng': end.longitude}
    );
  }
}
