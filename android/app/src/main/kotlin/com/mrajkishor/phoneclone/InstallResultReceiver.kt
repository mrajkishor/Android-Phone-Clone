package com.mrajkishor.phoneclone

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInstaller
import android.os.Build

/** Receives the outcome of an app install and shows Android's confirmation when needed. */
class InstallResultReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val sid = intent.getIntExtra("sid", -1)
        when (val status = intent.getIntExtra(PackageInstaller.EXTRA_STATUS, PackageInstaller.STATUS_FAILURE)) {
            PackageInstaller.STATUS_PENDING_USER_ACTION -> {
                val confirm: Intent? = if (Build.VERSION.SDK_INT >= 33) {
                    intent.getParcelableExtra(Intent.EXTRA_INTENT, Intent::class.java)
                } else {
                    @Suppress("DEPRECATION") intent.getParcelableExtra(Intent.EXTRA_INTENT)
                }
                if (confirm != null) {
                    val a = App.currentActivity?.get()
                    if (a != null) a.startActivity(confirm) else context.startActivity(confirm.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                }
            }
            else -> {
                val ok = status == PackageInstaller.STATUS_SUCCESS
                val msg = intent.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE)
                ExtrasBridge.installCallbacks.remove(sid)?.invoke(ok, if (ok) null else (msg ?: "Install failed ($status)"))
            }
        }
    }
}
