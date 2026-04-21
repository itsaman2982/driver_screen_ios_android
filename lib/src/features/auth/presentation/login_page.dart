import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import 'package:driverscreen/src/core/providers/driver_provider.dart';
import 'package:driverscreen/src/core/theme/app_theme.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _loading = false;

  Future<void> _handleLogin() async {
    if (_emailController.text.isEmpty || _passwordController.text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter Email and Password'), backgroundColor: Colors.orange),
      );
      return;
    }

    setState(() => _loading = true);
    final success = await context.read<DriverProvider>().login(
      _emailController.text, 
      _passwordController.text
    );
    setState(() => _loading = false);

    if (success) {
      if (mounted) Navigator.pushReplacementNamed(context, '/dashboard');
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Invalid Email or Password. Please try again.'), backgroundColor: Colors.red),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.background,
      body: Stack(
        children: [
          // Background Illustration (Light Map)
          Positioned.fill(
             child: Opacity(
               opacity: 0.1,
               child: Image.network('https://api.mapbox.com/styles/v1/mapbox/light-v11/static/25.0712,55.1325,10,0/1280x800@2x?access_token=pk.placeholder', fit: BoxFit.cover),
             ),
          ),

          Center(
            child: Container(
              width: 500,
              padding: const EdgeInsets.all(50),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(40),
                border: Border.all(color: AppTheme.divider),
                boxShadow: [
                  BoxShadow(color: Colors.black.withValues(alpha: 0.05), blurRadius: 40, offset: const Offset(0, 10))
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.taxi_alert_rounded, size: 70, color: AppTheme.accent),
                  const SizedBox(height: 30),
                  Text('DRIVESCREEN', style: GoogleFonts.outfit(fontSize: 34, fontWeight: FontWeight.bold, color: AppTheme.primaryText, letterSpacing: 2)),
                  const SizedBox(height: 8),
                  const Text('CAR DASHBOARD PLATFORM v2.1', style: TextStyle(color: AppTheme.secondaryText, fontSize: 13, fontWeight: FontWeight.w600, letterSpacing: 1.5)),
                  const SizedBox(height: 60),
                  
                  _buildInputField('OFFICIAL EMAIL', Icons.email_rounded, _emailController),
                  const SizedBox(height: 20),
                  _buildInputField('ACCOUNT PASSWORD', Icons.lock_rounded, _passwordController, isObscure: true),
                  
                  const SizedBox(height: 60),
                  
                  SizedBox(
                    width: double.infinity,
                    height: 65,
                    child: ElevatedButton(
                      onPressed: _loading ? null : _handleLogin,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppTheme.accent,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                        elevation: 10,
                        shadowColor: AppTheme.accent.withValues(alpha: 0.4),
                        textStyle: const TextStyle(fontWeight: FontWeight.bold, fontSize: 20, letterSpacing: 1.5)
                      ),
                      child: _loading 
                        ? const SizedBox(height: 25, width: 25, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 3)) 
                        : const Text('ACTIVATE DASHBOARD'),
                    ),
                  ),
                  
                  const SizedBox(height: 35),
                  const Text('FORGOT PIN? CONTACT FLEET DISPATCH', style: TextStyle(color: AppTheme.secondaryText, fontSize: 11, fontWeight: FontWeight.bold, letterSpacing: 1.2)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInputField(String label, IconData icon, TextEditingController ctrl, {bool isObscure = false}) {
    return Container(
      decoration: BoxDecoration(
        color: AppTheme.background,
        borderRadius: BorderRadius.circular(18),
      ),
      child: TextField(
        controller: ctrl,
        obscureText: isObscure,
        style: const TextStyle(color: AppTheme.primaryText, fontSize: 18, fontWeight: FontWeight.w600),
        decoration: InputDecoration(
          prefixIcon: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Icon(icon, color: AppTheme.secondaryText, size: 28),
          ),
          labelText: label,
          labelStyle: const TextStyle(color: AppTheme.secondaryText, fontSize: 13, fontWeight: FontWeight.bold, letterSpacing: 1.5),
          border: InputBorder.none,
          contentPadding: const EdgeInsets.symmetric(vertical: 20, horizontal: 20),
        ),
      ),
    );
  }
}
