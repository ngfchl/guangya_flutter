package com.ptools.guangya

import android.content.Intent
import android.net.Uri
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.ptools.guangya/external_player",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "availablePlayers" -> {
                    val packages = call.argument<List<String>>("packages").orEmpty()
                    val available = packages.filter { packageName ->
                        packageManager.getLaunchIntentForPackage(packageName) != null
                    }
                    result.success(available)
                }
                "openPlayer" -> {
                    val packageName = call.argument<String>("package")
                    val url = call.argument<String>("url")
                    if (packageName.isNullOrBlank() || url.isNullOrBlank()) {
                        result.error("invalid_arguments", "播放器或播放地址为空", null)
                        return@setMethodCallHandler
                    }
                    try {
                        val intent = Intent(Intent.ACTION_VIEW).apply {
                            setDataAndType(Uri.parse(url), "video/*")
                            setPackage(packageName)
                            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        }
                        startActivity(intent)
                        result.success(true)
                    } catch (error: Exception) {
                        result.error("open_failed", error.message, null)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }
}
