package com.mrajkishor.phoneclone

import android.content.Intent
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import java.lang.ref.WeakReference

class MainActivity : FlutterActivity() {
    /** Use the engine owned by [App], and don't destroy it when this screen closes. */
    override fun getCachedEngineId(): String = App.ENGINE_ID

    override fun shouldDestroyEngineWithHost(): Boolean = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        App.currentActivity = WeakReference(this)
    }

    override fun onResume() {
        super.onResume()
        App.currentActivity = WeakReference(this)
    }

    @Deprecated("Needed for the SMS role request and file picker results")
    @Suppress("DEPRECATION")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        ExtrasBridge.onActivityResult(requestCode, resultCode, data)
    }

    override fun onDestroy() {
        if (App.currentActivity?.get() === this) App.currentActivity = null
        super.onDestroy()
    }
}
