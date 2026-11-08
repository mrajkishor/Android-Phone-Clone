package com.mrajkishor.phoneclone

import android.content.Context
import android.media.MediaScannerConnection
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import android.view.WindowManager
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

/** The "phone_transfer/native" channel. Lives with the engine, not the screen. */
class NativeBridge(private val ctx: Context) {
    private val main = Handler(Looper.getMainLooper())

    fun register(engine: FlutterEngine) {
        MethodChannel(engine.dartExecutor.binaryMessenger, "phone_transfer/native")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "keepScreenOn" -> {
                        App.currentActivity?.get()?.window?.let { w ->
                            if (call.arguments == true) w.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                            else w.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                        }
                        result.success(null)
                    }

                    "moveToBackground" -> {
                        App.currentActivity?.get()?.moveTaskToBack(true)
                        result.success(null)
                    }

                    "sdkInt" -> result.success(Build.VERSION.SDK_INT)

                    "storageRoots" -> result.success(storageRoots())

                    "listMedia" -> Thread {
                        try {
                            val media = listMedia()
                            main.post { result.success(media) }
                        } catch (e: Exception) {
                            main.post { result.error("LIST_FAILED", e.message, null) }
                        }
                    }.start()

                    "finalizeFile" -> {
                        val path = call.argument<String>("path")!!
                        val mtime = call.argument<Number>("mtime")?.toLong() ?: 0L
                        if (mtime > 0) File(path).setLastModified(mtime)
                        // Reply once Android's media index has picked the file up.
                        MediaScannerConnection.scanFile(ctx, arrayOf(path), null) { _, _ ->
                            main.post { result.success(null) }
                        }
                    }

                    "scanFiles" -> {
                        val paths = call.argument<List<String>>("paths") ?: emptyList()
                        if (paths.isNotEmpty()) MediaScannerConnection.scanFile(ctx, paths.toTypedArray(), null, null)
                        result.success(null)
                    }

                    "startService" -> {
                        try {
                            TransferService.start(
                                ctx,
                                call.argument<String>("title") ?: "Phone Clone",
                                call.argument<String>("text") ?: "",
                                call.argument<Boolean>("sending") ?: true
                            )
                            result.success(null)
                        } catch (e: Exception) {
                            result.error("SERVICE_FAILED", e.message, null)
                        }
                    }

                    "updateNotification" -> {
                        TransferService.update(
                            ctx,
                            call.argument<String>("title") ?: "",
                            call.argument<String>("text") ?: "",
                            call.argument<Int>("progress") ?: -1
                        )
                        result.success(null)
                    }

                    "stopService" -> {
                        TransferService.stop(ctx)
                        result.success(null)
                    }

                    else -> result.notImplemented()
                }
            }
    }

    /** Internal storage plus every removable volume (SD card, USB drive). */
    private fun storageRoots(): List<String> {
        val roots = linkedSetOf(Environment.getExternalStorageDirectory().absolutePath)
        for (dir in ctx.getExternalFilesDirs(null)) {
            val path = dir?.absolutePath ?: continue
            val idx = path.indexOf("/Android/data/")
            if (idx > 0) roots.add(path.substring(0, idx))
        }
        return roots.filter { File(it).canRead() }
    }

    /** Every image, video and audio file Android knows about, on all volumes. */
    private fun listMedia(): List<Map<String, Any?>> {
        val out = ArrayList<Map<String, Any?>>()
        val volume = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) MediaStore.VOLUME_EXTERNAL else "external"

        fun query(uri: Uri, kind: String) {
            @Suppress("DEPRECATION")
            val dataCol = MediaStore.MediaColumns.DATA
            ctx.contentResolver.query(uri, arrayOf(dataCol), null, null, null)?.use { c ->
                val idx = c.getColumnIndexOrThrow(dataCol)
                while (c.moveToNext()) {
                    val path = c.getString(idx) ?: continue
                    out.add(mapOf("path" to path, "kind" to kind))
                }
            }
        }

        query(MediaStore.Images.Media.getContentUri(volume), "photo")
        query(MediaStore.Video.Media.getContentUri(volume), "video")
        query(MediaStore.Audio.Media.getContentUri(volume), "audio")
        return out
    }
}
