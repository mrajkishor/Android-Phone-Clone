package com.mrajkishor.phoneclone

import android.app.Activity
import android.app.Service
import android.content.BroadcastReceiver
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.os.IBinder
import android.provider.Settings
import android.provider.Telephony
import android.view.Gravity
import android.widget.Button
import android.widget.LinearLayout
import android.widget.TextView

/*
 * Android only lets the *default SMS app* write messages. While messages are
 * being restored, Phone Clone briefly takes that role, so it must provide the
 * components every SMS app has. They are deliberately minimal: incoming texts
 * are saved to the inbox so nothing is lost, and the user is reminded to switch
 * back to their usual messaging app.
 */

/** Saves any SMS that arrives while Phone Clone is the default SMS app. */
class SmsDeliverReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Telephony.Sms.Intents.SMS_DELIVER_ACTION) return
        val messages = Telephony.Sms.Intents.getMessagesFromIntent(intent) ?: return
        if (messages.isEmpty()) return
        val body = messages.joinToString("") { it.messageBody ?: "" }
        val first = messages[0]
        context.contentResolver.insert(Telephony.Sms.Inbox.CONTENT_URI, ContentValues().apply {
            put(Telephony.Sms.ADDRESS, first.originatingAddress)
            put(Telephony.Sms.BODY, body)
            put(Telephony.Sms.DATE, System.currentTimeMillis())
            put(Telephony.Sms.DATE_SENT, first.timestampMillis)
            put(Telephony.Sms.READ, 0)
            put(Telephony.Sms.SEEN, 0)
        })
    }
}

/** Required for the SMS role. (MMS that arrive during the short restore window are not downloaded.) */
class MmsDeliverReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {}
}

/** Required for the SMS role ("quick reply" to calls). Not used. */
class HeadlessSmsSendService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        stopSelf(startId)
        return START_NOT_STICKY
    }
}

/** Opened if the user taps an SMS link while Phone Clone is the default SMS app. */
class ComposeSmsActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val pad = (24 * resources.displayMetrics.density).toInt()
        setContentView(LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
            setPadding(pad, pad, pad, pad)
            addView(TextView(this@ComposeSmsActivity).apply {
                text = "Phone Clone is only your SMS app while it restores messages.\n\n" +
                    "Switch back to your usual messaging app to send messages."
                textSize = 17f
            })
            addView(Button(this@ComposeSmsActivity).apply {
                text = "Choose default SMS app"
                setOnClickListener { startActivity(Intent(Settings.ACTION_MANAGE_DEFAULT_APPS_SETTINGS)); finish() }
            })
        })
    }
}
