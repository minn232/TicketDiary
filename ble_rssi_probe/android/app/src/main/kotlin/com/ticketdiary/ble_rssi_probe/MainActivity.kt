package com.ticketdiary.ble_rssi_probe

import android.content.ContentValues
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "probe/save").setMethodCallHandler { call, result ->
            if (call.method != "saveToDownloads") {
                result.notImplemented()
                return@setMethodCallHandler
            }
            val name = call.argument<String>("name")!!
            val bytes = call.argument<ByteArray>("bytes")!!
            try {
                result.success(saveToDownloads(name, bytes))
            } catch (e: Exception) {
                result.error("SAVE_FAILED", e.message, null)
            }
        }
    }

    // 내 파일 > 다운로드 > BLE실측 폴더에 저장 - 안드로이드 10+는 MediaStore라 저장 권한 필요 없음
    private fun saveToDownloads(name: String, bytes: ByteArray): String {
        val folder = "BLE실측"
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val values = ContentValues().apply {
                put(MediaStore.Downloads.DISPLAY_NAME, name)
                put(MediaStore.Downloads.MIME_TYPE, "text/csv")
                put(MediaStore.Downloads.RELATIVE_PATH, "${Environment.DIRECTORY_DOWNLOADS}/$folder")
            }
            val uri = contentResolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
                ?: throw IllegalStateException("MediaStore insert 실패")
            contentResolver.openOutputStream(uri)!!.use { it.write(bytes) }
            return "다운로드/$folder/$name"
        }
        val dir = File(Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS), folder)
        dir.mkdirs()
        File(dir, name).writeBytes(bytes)
        return "다운로드/$folder/$name"
    }
}
