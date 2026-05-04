package com.example.radiont

import android.content.ContentUris
import android.content.Context
import android.content.Intent
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.Environment
import android.os.StatFs
import android.provider.MediaStore
import androidx.core.content.FileProvider
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity: AudioServiceActivity() {

    private val CHANNEL = "com.example.radiont/media_manager"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "deleteSong" -> {
                    val idStr = call.argument<String>("id")
                    val id = idStr?.toLongOrNull()
                    if (id != null) {
                        val deleted = deleteMedia(id)
                        result.success(deleted)
                    } else {
                        result.error("INVALID_ID", "Song ID is null or invalid: $idStr", null)
                    }
                }
                "installApk" -> {
                    val filePath = call.argument<String>("filePath")
                    if (filePath != null) {
                        try {
                            val file = File(filePath)
                            val uri = FileProvider.getUriForFile(
                                this,
                                "com.example.radiont.fileprovider",
                                file
                            )
                            val intent = Intent(Intent.ACTION_VIEW).apply {
                                setDataAndType(uri, "application/vnd.android.package-archive")
                                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            }
                            startActivity(intent)
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("INSTALL_ERROR", e.message, null)
                        }
                    } else {
                        result.error("INVALID_PATH", "File path is null", null)
                    }
                }
                "getFreeSpace" -> {
                    try {
                        val path = Environment.getExternalStorageDirectory()
                        val stat = StatFs(path.path)
                        val freeBytes = stat.availableBlocksLong * stat.blockSizeLong
                        result.success(freeBytes)
                    } catch (e: Exception) {
                        result.error("STORAGE_ERROR", e.message, null)
                    }
                }
                "isWifiConnected" -> {
                    try {
                        val connectivityManager = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
                        val network = connectivityManager.activeNetwork
                        val capabilities = connectivityManager.getNetworkCapabilities(network)
                        val isWifi = capabilities?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) == true
                        result.success(isWifi)
                    } catch (e: Exception) {
                        result.success(true) // Hiba esetén feltételezzük, hogy van net, hogy ne akasszuk meg
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun deleteMedia(id: Long): Boolean {
        return try {
            val uri = ContentUris.withAppendedId(MediaStore.Audio.Media.EXTERNAL_CONTENT_URI, id)
            val deletedRows = contentResolver.delete(uri, null, null)
            deletedRows > 0
        } catch (e: Exception) {
            false
        }
    }
}
