package com.qis.driverscreen

import io.flutter.embedding.android.FlutterActivity

import android.app.admin.DevicePolicyManager
import android.content.ComponentName
import android.content.Context
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.fleet.kiosk/lock"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "startKioskMode" -> {
                    try {
                        val dpm = getSystemService(Context.DEVICE_POLICY_SERVICE) as DevicePolicyManager
                        val deviceAdminNode = ComponentName(this, MyDeviceAdminReceiver::class.java)

                        // If we are the root Device Owner, authorize a True, unbreakable Kiosk lock
                        if (dpm.isDeviceOwnerApp(packageName)) {
                            dpm.setLockTaskPackages(deviceAdminNode, arrayOf(packageName))
                        }

                        startLockTask()
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("LOCK_FAIL", e.message, null)
                    }
                }
                "stopKioskMode" -> {
                    try {
                        stopLockTask()
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("UNLOCK_FAIL", e.message, null)
                    }
                }
                else -> {
                    result.notImplemented()
                }
            }
        }
    }
}
