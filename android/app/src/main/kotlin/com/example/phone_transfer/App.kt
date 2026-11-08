package com.example.phone_transfer

import android.app.Activity
import android.app.Application
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor
import java.lang.ref.WeakReference

/**
 * Owns the Flutter engine for the whole process. Because the engine is not tied
 * to the screen, the transfer keeps running when the app is closed or swiped
 * away; reopening the app reattaches to the same running transfer.
 */
class App : Application() {
    companion object {
        const val ENGINE_ID = "main"
        var currentActivity: WeakReference<Activity>? = null
    }

    override fun onCreate() {
        super.onCreate()
        val engine = FlutterEngine(this)
        NativeBridge(this).register(engine)
        engine.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint.createDefault())
        FlutterEngineCache.getInstance().put(ENGINE_ID, engine)
    }
}
