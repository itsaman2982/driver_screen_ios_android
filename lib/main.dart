import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import 'package:responsive_framework/responsive_framework.dart';
import 'package:driverscreen/src/core/theme/app_theme.dart';
import 'package:driverscreen/src/core/providers/driver_provider.dart';
import 'package:driverscreen/src/features/auth/presentation/login_page.dart';
import 'package:driverscreen/src/features/dashboard/presentation/dashboard_screen.dart';

import 'package:driverscreen/src/core/map/mappls_config.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  Future.delayed(const Duration(milliseconds: 500), () {
    MapplsConfig.initialize();
  });
  
  SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.dark,
    ),
  );
  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => DriverProvider()),
      ],
      child: const DriverApp(),
    ),
  );
}

class DriverApp extends StatelessWidget {
  const DriverApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'DriveScreen',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.lightTheme,
      builder: (context, child) {
        if (child == null) return const SizedBox.shrink();
        return ResponsiveBreakpoints.builder(
          child: child,
          breakpoints: [
             const Breakpoint(start: 0, end: 450, name: MOBILE),
             const Breakpoint(start: 451, end: 800, name: TABLET),
             const Breakpoint(start: 801, end: 1920, name: DESKTOP),
             const Breakpoint(start: 1921, end: double.infinity, name: '4K'),
          ],
        );
      },
      initialRoute: '/',
      onGenerateRoute: (settings) {
        if (settings.name == '/') {
          return MaterialPageRoute(
            builder: (context) {
              final provider = Provider.of<DriverProvider>(context);
              if (!provider.isInitialized) {
                return _buildSplashScreen();
              }
              if (provider.isLoggedIn) {
                return const DashboardPage();
              } else {
                return const LoginPage();
              }
            },
          );
        }
        
        switch (settings.name) {
          case '/dashboard': return MaterialPageRoute(builder: (_) => const DashboardPage());
          case '/login': return MaterialPageRoute(builder: (_) => const LoginPage());
          default: return null;
        }
      },
    );
  }

  Widget _buildSplashScreen() {
    return Scaffold(
      backgroundColor: AppTheme.background,
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.taxi_alert_rounded, size: 80, color: AppTheme.accent),
            const SizedBox(height: 30),
            const CircularProgressIndicator(color: AppTheme.accent),
            const SizedBox(height: 20),
            Text('VALIDATING IN-VEHICLE SYSTEM', style: GoogleFonts.outfit(fontWeight: FontWeight.bold, letterSpacing: 2, fontSize: 13, color: AppTheme.secondaryText)),
          ],
        ),
      ),
    );
  }
}
