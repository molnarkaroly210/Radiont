package com.example.radiont

import android.content.ContentUris
import android.provider.MediaStore
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity: FlutterActivity() {
    private val CHANNEL = "com.example.radiont/media_manager"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            if (call.method == "deleteSong") {
                val idStr = call.argument<String>("id")
                val id = idStr?.toLongOrNull()
                if (id != null) {
                    val deleted = deleteMedia(id)
                    result.success(deleted)
                } else {
                    result.error("INVALID_ID", "Song ID is null or invalid: $idStr", null)
                }
            } else {
                result.notImplemented()
            }
        }
    }

    private fun deleteMedia(id: Long): Boolean {
        return try {
            val uri = ContentUris.withAppendedId(MediaStore.Audio.Media.EXTERNAL_CONTENT_URI, id)
            val deletedRows = contentResolver.delete(uri, null, null)
            deletedRows > 0
        } catch (e: Exception) {
            // Android 10+ esetén ha nincs MANAGE_EXTERNAL_STORAGE, itt RecoverableSecurityException jöhetne,
            // de mivel az alkalmazás kéri a speciális jogot, a sima delete-nek működnie kell.
            false
        }
    }
}
