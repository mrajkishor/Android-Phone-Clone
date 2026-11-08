package com.mrajkishor.phoneclone

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

    override fun onDestroy() {
        if (App.currentActivity?.get() === this) App.currentActivity = null
        super.onDestroy()
    }
}
