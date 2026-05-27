package com.reuse.flippanel

import android.content.Context
import android.content.Intent
import android.net.wifi.WifiManager
import android.os.Bundle
import android.view.KeyEvent
import androidx.core.view.WindowCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.reuse.flippanel/multicast"
    private val VOLUME_KEY_CHANNEL = "com.reuse.flippanel/volumekey"
    private var multicastLock: WifiManager.MulticastLock? = null
    private var volumeKeyChannel: MethodChannel? = null

    /// Dart 侧根据 PC 连接状态切换。仅 true 时拦截硬件音量键并转发给 Flutter；
    /// false 时走系统默认（调本机音量），避免断连时音量键"无反应"。
    @Volatile private var volumeKeyInterceptEnabled = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        WindowCompat.setDecorFitsSystemWindows(window, false)
        window.statusBarColor = android.graphics.Color.TRANSPARENT
        window.navigationBarColor = android.graphics.Color.TRANSPARENT
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "acquireMulticastLock" -> {
                    try {
                        val wifiManager = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
                        multicastLock = wifiManager.createMulticastLock("flippanel_multicast").apply {
                            setReferenceCounted(true)
                            acquire()
                        }
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("LOCK_ERROR", "Failed to acquire multicast lock: ${e.message}", null)
                    }
                }
                "releaseMulticastLock" -> {
                    try {
                        multicastLock?.release()
                        multicastLock = null
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("LOCK_ERROR", "Failed to release multicast lock: ${e.message}", null)
                    }
                }
                "startForegroundService" -> {
                    try {
                        val intent = Intent(this, PanelForegroundService::class.java)
                        startForegroundService(intent)
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("SERVICE_ERROR", "Failed to start foreground service: ${e.message}", null)
                    }
                }
                else -> result.notImplemented()
            }
        }

        volumeKeyChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, VOLUME_KEY_CHANNEL)
        volumeKeyChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "setEnabled" -> {
                    volumeKeyInterceptEnabled = (call.arguments as? Boolean) ?: false
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
    }

    /// 拦截硬件音量键：连接 PC 后 enabled=true，向 Flutter 上报方向；否则走系统默认。
    /// 长按由 Android 自动产生连续 ACTION_DOWN（repeatCount 递增），无需特殊处理。
    /// 同时吞掉 ACTION_UP，避免系统弹出本机音量条 OSD。
    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        if (volumeKeyInterceptEnabled) {
            val code = event.keyCode
            if (code == KeyEvent.KEYCODE_VOLUME_UP || code == KeyEvent.KEYCODE_VOLUME_DOWN) {
                if (event.action == KeyEvent.ACTION_DOWN) {
                    val direction = if (code == KeyEvent.KEYCODE_VOLUME_UP) "up" else "down"
                    volumeKeyChannel?.invokeMethod("volumeKey", direction)
                }
                return true
            }
        }
        return super.dispatchKeyEvent(event)
    }

    override fun onDestroy() {
        multicastLock?.release()
        multicastLock = null
        super.onDestroy()
    }
}
