import 'package:mappls_gl/mappls_gl.dart';

class MapplsConfig {
  // Use the same keys from the production app for consistency
  static const String restApiKey = '19a8340043af8d929ed5661bc4e2dcf4';
  static const String atlasClientId = '96dHZVzsAuvgbkeidIFGxUZyAHDTzyP6c6wPTZn0d_IRHridX4xFACf6CV0d-ZVUMQtz8s3hhC_9SKsxFV2_cA==';
  static const String atlasClientSecret = 'lrFxI-iSEg80B8p98KeWRM-brweGUfSafyw_1C3v_8kWIKRqOVV3KuFP5GtaHj_TgUF7CvpCNX2PMcTRnwP4lqTrB3-DTKWd';

  static Future<void> initialize() async {
    MapplsAccountManager.setMapSDKKey(restApiKey);
    MapplsAccountManager.setRestAPIKey(restApiKey);
    MapplsAccountManager.setAtlasClientId(atlasClientId);
    MapplsAccountManager.setAtlasClientSecret(atlasClientSecret);
  }
}
