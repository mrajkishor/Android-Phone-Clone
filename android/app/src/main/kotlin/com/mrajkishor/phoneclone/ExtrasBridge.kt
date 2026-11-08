package com.mrajkishor.phoneclone

import android.app.Activity
import android.app.PendingIntent
import android.app.WallpaperManager
import android.app.role.RoleManager
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.content.pm.PackageInstaller
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.Canvas
import android.media.MediaScannerConnection
import android.media.RingtoneManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.CalendarContract
import android.provider.CallLog
import android.provider.MediaStore
import android.provider.Settings
import android.provider.Telephony
import android.util.Base64
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * Everything beyond files and contacts: messages, call history, calendar,
 * installed apps, wallpaper and ringtones. Reads on the old phone, writes on
 * the new phone. Heavy work runs on background threads.
 */
class ExtrasBridge(private val ctx: Context) {
    companion object {
        const val REQ_SMS_ROLE = 7301
        private var pendingRole: ((Boolean) -> Unit)? = null
        val installCallbacks = HashMap<Int, (Boolean, String?) -> Unit>()

        /** Called by MainActivity.onActivityResult. */
        fun onActivityResult(requestCode: Int) {
            if (requestCode == REQ_SMS_ROLE) {
                val cb = pendingRole
                pendingRole = null
                cb?.invoke(true) // the caller re-checks whether we are now the default
            }
        }

        private val GOOGLE_LIKE = setOf(
            "com.google", "com.google.android.gm.exchange", "com.android.exchange",
            "com.microsoft.office.outlook", "com.samsung.android.exchange", "com.microsoft.exchange"
        )
    }

    private val main = Handler(Looper.getMainLooper())

    // De-duplication sets, built once per app run on the new phone.
    private var smsSeen: HashSet<String>? = null
    private var mmsSeen: HashSet<String>? = null
    private var callsSeen: HashSet<String>? = null
    private var eventsSeen: HashSet<String>? = null
    private val calendarIds = HashMap<String, Long>()

    private fun bg(result: MethodChannel.Result, work: () -> Any?) {
        Thread {
            try {
                val v = work()
                main.post { result.success(v) }
            } catch (e: Exception) {
                main.post { result.error("EXTRAS_FAILED", e.message ?: e.toString(), null) }
            }
        }.start()
    }

    private fun activity(): Activity? = App.currentActivity?.get()

    /** Returns true when the call was handled here. */
    fun handle(call: MethodCall, result: MethodChannel.Result): Boolean {
        when (call.method) {
            // ---------------- old phone: counts ----------------
            "extrasCounts" -> bg(result) { counts() }

            // ---------------- messages ----------------
            "readSms" -> bg(result) { readSms(call.argument<Number>("after")!!.toLong(), call.argument<Int>("limit")!!) }
            "readMms" -> bg(result) { readMms(call.argument<Number>("after")!!.toLong(), call.argument<Int>("limit")!!) }
            "isDefaultSmsApp" -> result.success(isDefaultSms())
            "requestDefaultSmsApp" -> requestDefaultSms(result)
            "restoreDefaultSmsApp" -> { restoreDefaultSms(); result.success(null) }
            "writeSms" -> bg(result) { writeSms(call.argument<List<Map<String, Any?>>>("items")!!) }
            "writeMms" -> bg(result) { writeMms(call.argument<List<Map<String, Any?>>>("items")!!) }

            // ---------------- call history ----------------
            "readCalls" -> bg(result) { readCalls(call.argument<Number>("after")!!.toLong(), call.argument<Int>("limit")!!) }
            "writeCalls" -> bg(result) { writeCalls(call.argument<List<Map<String, Any?>>>("items")!!) }

            // ---------------- calendar ----------------
            "readCalendar" -> bg(result) { readCalendar() }
            "writeCalendar" -> bg(result) {
                writeCalendar(call.argument<List<Map<String, Any?>>>("events")!!)
            }

            // ---------------- apps ----------------
            "listApps" -> bg(result) { listApps() }
            "installedVersion" -> result.success(installedVersion(call.argument<String>("package")!!))
            "canInstallApps" -> result.success(
                Build.VERSION.SDK_INT < Build.VERSION_CODES.O || ctx.packageManager.canRequestPackageInstalls()
            )
            "openInstallPermission" -> {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    startSettings(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:${ctx.packageName}")))
                }
                result.success(null)
            }
            "installApks" -> installApks(call.argument<List<String>>("paths")!!, result)
            "openPlayStore" -> { openPlayStore(call.argument<String>("package")!!); result.success(null) }

            // ---------------- wallpaper ----------------
            "readWallpaper" -> bg(result) { readWallpaper(call.argument<String>("which") == "lock") }
            "setWallpaper" -> bg(result) {
                val bytes = call.argument<ByteArray>("bytes")!!
                val which = if (call.argument<String>("which") == "lock") WallpaperManager.FLAG_LOCK else WallpaperManager.FLAG_SYSTEM
                WallpaperManager.getInstance(ctx).setStream(ByteArrayInputStream(bytes), null, true, which)
                true
            }

            // ---------------- ringtones ----------------
            "readRingtones" -> bg(result) { readRingtones() }
            "canWriteSettings" -> result.success(Settings.System.canWrite(ctx))
            "openWriteSettings" -> {
                startSettings(Intent(Settings.ACTION_MANAGE_WRITE_SETTINGS, Uri.parse("package:${ctx.packageName}")))
                result.success(null)
            }
            "setRingtone" -> bg(result) {
                setRingtone(call.argument<String>("type")!!, call.argument<String>("path"), call.argument<String>("title"))
            }

            // ---------------- thumbnails for the Files tab ----------------
            "apkMeta" -> bg(result) { apkMeta(call.argument<String>("path")!!) }
            "appIcon" -> bg(result) { appIcon(call.argument<String>("package")!!) }
            "videoThumb" -> bg(result) { videoThumb(call.argument<String>("path")!!, call.argument<Int>("size") ?: 160) }

            else -> return false
        }
        return true
    }

    private fun startSettings(intent: Intent) {
        val a = activity()
        if (a != null) a.startActivity(intent) else ctx.startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
    }

    // ======================= counts =======================

    private fun count(uri: Uri, selection: String? = null, args: Array<String>? = null): Int = try {
        ctx.contentResolver.query(uri, arrayOf("_id"), selection, args, null)?.use { it.count } ?: 0
    } catch (_: Exception) {
        -1 // no permission
    }

    private fun counts(): Map<String, Any?> {
        val cal = try { readCalendar() } catch (_: Exception) { null }
        return mapOf(
            "sms" to count(Telephony.Sms.CONTENT_URI),
            "mms" to count(Telephony.Mms.CONTENT_URI),
            "calls" to count(CallLog.Calls.CONTENT_URI),
            "calendarEvents" to ((cal?.get("events") as? List<*>)?.size ?: -1),
        )
    }

    // ======================= SMS =======================

    private fun readSms(after: Long, limit: Int): Map<String, Any?> {
        val out = ArrayList<Map<String, Any?>>()
        var last = after
        val cols = arrayOf("_id", "address", "body", "date", "date_sent", "type", "read", "seen", "status", "subject")
        ctx.contentResolver.query(Telephony.Sms.CONTENT_URI, cols, "_id > ?", arrayOf(after.toString()), "_id ASC")?.use { c ->
            while (c.moveToNext() && out.size < limit) {
                last = c.getLong(0)
                out.add(mapOf(
                    "address" to c.getString(1), "body" to c.getString(2), "date" to c.getLong(3),
                    "date_sent" to c.getLong(4), "type" to c.getInt(5), "read" to c.getInt(6),
                    "seen" to c.getInt(7), "status" to c.getInt(8), "subject" to c.getString(9),
                ))
            }
        }
        return mapOf("items" to out, "last" to last)
    }

    private fun smsKey(address: String?, date: Long, body: String?) = "$address|$date|${(body ?: "").hashCode()}"

    private fun writeSms(items: List<Map<String, Any?>>): Map<String, Int> {
        if (!isDefaultSms()) throw IllegalStateException("Phone Clone is not the default SMS app")
        val seen = smsSeen ?: HashSet<String>().also { set ->
            ctx.contentResolver.query(Telephony.Sms.CONTENT_URI, arrayOf("address", "date", "body"), null, null, null)?.use { c ->
                while (c.moveToNext()) set.add(smsKey(c.getString(0), c.getLong(1), c.getString(2)))
            }
            smsSeen = set
        }
        var added = 0; var existing = 0; var failed = 0
        for (m in items) {
            val address = m["address"] as String?
            val date = (m["date"] as Number).toLong()
            val body = m["body"] as String?
            val key = smsKey(address, date, body)
            if (!seen.add(key)) { existing++; continue }
            try {
                val v = ContentValues().apply {
                    put("address", address); put("body", body); put("date", date)
                    put("date_sent", (m["date_sent"] as Number?)?.toLong() ?: 0L)
                    put("type", (m["type"] as Number?)?.toInt() ?: 1)
                    put("read", (m["read"] as Number?)?.toInt() ?: 1)
                    put("seen", (m["seen"] as Number?)?.toInt() ?: 1)
                    put("status", (m["status"] as Number?)?.toInt() ?: -1)
                    (m["subject"] as String?)?.let { put("subject", it) }
                }
                if (ctx.contentResolver.insert(Telephony.Sms.CONTENT_URI, v) != null) added++ else failed++
            } catch (_: Exception) { failed++ }
        }
        return mapOf("added" to added, "existing" to existing, "failed" to failed)
    }

    // ======================= MMS =======================

    private fun readMms(after: Long, limit: Int): Map<String, Any?> {
        val out = ArrayList<Map<String, Any?>>()
        var last = after
        val cols = arrayOf("_id", "date", "date_sent", "msg_box", "read", "seen", "sub", "sub_cs", "ct_t", "m_type")
        ctx.contentResolver.query(Telephony.Mms.CONTENT_URI, cols, "_id > ?", arrayOf(after.toString()), "_id ASC")?.use { c ->
            while (c.moveToNext() && out.size < limit) {
                val id = c.getLong(0)
                last = id
                val addrs = ArrayList<Map<String, Any?>>()
                ctx.contentResolver.query(Uri.parse("content://mms/$id/addr"), arrayOf("address", "type", "charset"), null, null, null)?.use { a ->
                    while (a.moveToNext()) addrs.add(mapOf("address" to a.getString(0), "type" to a.getInt(1), "charset" to a.getInt(2)))
                }
                val parts = ArrayList<Map<String, Any?>>()
                ctx.contentResolver.query(Uri.parse("content://mms/part"), arrayOf("_id", "ct", "text", "name", "cl", "cid", "chset", "_data"),
                    "mid = ?", arrayOf(id.toString()), null)?.use { p ->
                    while (p.moveToNext()) {
                        val pid = p.getLong(0)
                        val ct = p.getString(1)
                        val text = p.getString(2)
                        var data: String? = null
                        if (p.getString(7) != null) {
                            data = try {
                                ctx.contentResolver.openInputStream(Uri.parse("content://mms/part/$pid"))?.use {
                                    Base64.encodeToString(it.readBytes(), Base64.NO_WRAP)
                                }
                            } catch (_: Exception) { null }
                        }
                        parts.add(mapOf("ct" to ct, "text" to text, "name" to p.getString(3), "cl" to p.getString(4),
                            "cid" to p.getString(5), "chset" to p.getInt(6), "data" to data))
                    }
                }
                out.add(mapOf(
                    "date" to c.getLong(1), "date_sent" to c.getLong(2), "msg_box" to c.getInt(3),
                    "read" to c.getInt(4), "seen" to c.getInt(5), "sub" to c.getString(6), "sub_cs" to c.getInt(7),
                    "ct_t" to c.getString(8), "m_type" to c.getInt(9), "addrs" to addrs, "parts" to parts,
                ))
            }
        }
        return mapOf("items" to out, "last" to last)
    }

    private fun mmsKey(date: Long, box: Int, addresses: String) = "$date|$box|$addresses"

    private fun writeMms(items: List<Map<String, Any?>>): Map<String, Int> {
        if (!isDefaultSms()) throw IllegalStateException("Phone Clone is not the default SMS app")
        val seen = mmsSeen ?: HashSet<String>().also { set ->
            ctx.contentResolver.query(Telephony.Mms.CONTENT_URI, arrayOf("_id", "date", "msg_box"), null, null, null)?.use { c ->
                while (c.moveToNext()) {
                    val addrs = StringBuilder()
                    ctx.contentResolver.query(Uri.parse("content://mms/${c.getLong(0)}/addr"), arrayOf("address"), null, null, "address")?.use { a ->
                        while (a.moveToNext()) addrs.append(a.getString(0)).append(',')
                    }
                    set.add(mmsKey(c.getLong(1), c.getInt(2), addrs.toString()))
                }
            }
            mmsSeen = set
        }
        var added = 0; var existing = 0; var failed = 0
        for (m in items) {
            @Suppress("UNCHECKED_CAST") val addrs = m["addrs"] as List<Map<String, Any?>>
            @Suppress("UNCHECKED_CAST") val parts = m["parts"] as List<Map<String, Any?>>
            val date = (m["date"] as Number).toLong()
            val box = (m["msg_box"] as Number).toInt()
            val sortedAddrs = addrs.mapNotNull { it["address"] as String? }.sorted().joinToString(",", postfix = ",")
            if (!seen.add(mmsKey(date, box, sortedAddrs))) { existing++; continue }
            try {
                val recipients = addrs.mapNotNull { it["address"] as String? }.filter { it.isNotBlank() && it != "insert-address-token" }.toSet()
                val threadId = Telephony.Threads.getOrCreateThreadId(ctx, if (recipients.isEmpty()) setOf("unknown") else recipients)
                val v = ContentValues().apply {
                    put("thread_id", threadId); put("date", date)
                    put("date_sent", (m["date_sent"] as Number?)?.toLong() ?: 0L)
                    put("msg_box", box); put("read", (m["read"] as Number?)?.toInt() ?: 1)
                    put("seen", (m["seen"] as Number?)?.toInt() ?: 1)
                    (m["sub"] as String?)?.let { put("sub", it) }
                    put("sub_cs", (m["sub_cs"] as Number?)?.toInt() ?: 106)
                    put("ct_t", (m["ct_t"] as String?) ?: "application/vnd.wap.multipart.related")
                    put("m_type", (m["m_type"] as Number?)?.toInt() ?: if (box == 1) 132 else 128)
                    put("v", 18); put("pri", 129); put("rr", 129); put("d_rpt", 129)
                    put("m_cls", "personal"); put("tr_id", "T" + java.lang.Long.toHexString(System.nanoTime()))
                    put("exp", 604800); put("locked", 0)
                }
                val uri = ctx.contentResolver.insert(Telephony.Mms.CONTENT_URI, v) ?: run { failed++; null } ?: continue
                val id = uri.lastPathSegment
                for (a in addrs) {
                    ctx.contentResolver.insert(Uri.parse("content://mms/$id/addr"), ContentValues().apply {
                        put("address", a["address"] as String?); put("type", (a["type"] as Number?)?.toInt() ?: 137)
                        put("charset", (a["charset"] as Number?)?.toInt() ?: 106)
                    })
                }
                for (p in parts) {
                    val pv = ContentValues().apply {
                        put("mid", id); put("ct", p["ct"] as String?)
                        (p["name"] as String?)?.let { put("name", it) }
                        (p["cl"] as String?)?.let { put("cl", it) }
                        (p["cid"] as String?)?.let { put("cid", it) }
                        (p["text"] as String?)?.let { put("text", it) }
                        val chset = (p["chset"] as Number?)?.toInt() ?: 0
                        if (chset != 0) put("chset", chset)
                    }
                    val partUri = ctx.contentResolver.insert(Uri.parse("content://mms/$id/part"), pv)
                    val data = p["data"] as String?
                    if (partUri != null && data != null) {
                        ctx.contentResolver.openOutputStream(partUri)?.use { it.write(Base64.decode(data, Base64.NO_WRAP)) }
                    }
                }
                added++
            } catch (_: Exception) { failed++ }
        }
        return mapOf("added" to added, "existing" to existing, "failed" to failed)
    }

    // ======================= default SMS app =======================

    private fun isDefaultSms() = Telephony.Sms.getDefaultSmsPackage(ctx) == ctx.packageName

    private fun requestDefaultSms(result: MethodChannel.Result) {
        if (isDefaultSms()) { result.success(true); return }
        val a = activity() ?: run { result.success(false); return }
        ctx.getSharedPreferences("phoneclone", Context.MODE_PRIVATE).edit()
            .putString("previousSmsApp", Telephony.Sms.getDefaultSmsPackage(ctx)).apply()
        pendingRole = { _ -> result.success(isDefaultSms()) }
        val intent = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            ctx.getSystemService(RoleManager::class.java).createRequestRoleIntent(RoleManager.ROLE_SMS)
        } else {
            Intent(Telephony.Sms.Intents.ACTION_CHANGE_DEFAULT).putExtra(Telephony.Sms.Intents.EXTRA_PACKAGE_NAME, ctx.packageName)
        }
        a.startActivityForResult(intent, REQ_SMS_ROLE)
    }

    /** Hands the SMS role back: directly on Android 9 and below, via Settings on 10+. */
    private fun restoreDefaultSms() {
        val previous = ctx.getSharedPreferences("phoneclone", Context.MODE_PRIVATE).getString("previousSmsApp", null)
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q && previous != null) {
            startSettings(Intent(Telephony.Sms.Intents.ACTION_CHANGE_DEFAULT).putExtra(Telephony.Sms.Intents.EXTRA_PACKAGE_NAME, previous))
        } else {
            startSettings(Intent(Settings.ACTION_MANAGE_DEFAULT_APPS_SETTINGS))
        }
    }

    // ======================= call history =======================

    private fun readCalls(after: Long, limit: Int): Map<String, Any?> {
        val out = ArrayList<Map<String, Any?>>()
        var last = after
        val cols = arrayOf(CallLog.Calls._ID, CallLog.Calls.NUMBER, CallLog.Calls.DATE, CallLog.Calls.DURATION,
            CallLog.Calls.TYPE, CallLog.Calls.CACHED_NAME, CallLog.Calls.NUMBER_PRESENTATION)
        ctx.contentResolver.query(CallLog.Calls.CONTENT_URI, cols, "_id > ?", arrayOf(after.toString()), "_id ASC")?.use { c ->
            while (c.moveToNext() && out.size < limit) {
                last = c.getLong(0)
                out.add(mapOf("number" to c.getString(1), "date" to c.getLong(2), "duration" to c.getLong(3),
                    "type" to c.getInt(4), "name" to c.getString(5), "presentation" to c.getInt(6)))
            }
        }
        return mapOf("items" to out, "last" to last)
    }

    private fun callKey(n: String?, date: Long, dur: Long, type: Int) = "$n|$date|$dur|$type"

    private fun writeCalls(items: List<Map<String, Any?>>): Map<String, Int> {
        val seen = callsSeen ?: HashSet<String>().also { set ->
            ctx.contentResolver.query(CallLog.Calls.CONTENT_URI,
                arrayOf(CallLog.Calls.NUMBER, CallLog.Calls.DATE, CallLog.Calls.DURATION, CallLog.Calls.TYPE), null, null, null)?.use { c ->
                while (c.moveToNext()) set.add(callKey(c.getString(0), c.getLong(1), c.getLong(2), c.getInt(3)))
            }
            callsSeen = set
        }
        var added = 0; var existing = 0; var failed = 0
        for (m in items) {
            val n = m["number"] as String?
            val date = (m["date"] as Number).toLong()
            val dur = (m["duration"] as Number?)?.toLong() ?: 0L
            val type = (m["type"] as Number?)?.toInt() ?: CallLog.Calls.INCOMING_TYPE
            if (!seen.add(callKey(n, date, dur, type))) { existing++; continue }
            try {
                val v = ContentValues().apply {
                    put(CallLog.Calls.NUMBER, n); put(CallLog.Calls.DATE, date); put(CallLog.Calls.DURATION, dur)
                    put(CallLog.Calls.TYPE, type); put(CallLog.Calls.NEW, 0)
                    (m["name"] as String?)?.let { put(CallLog.Calls.CACHED_NAME, it) }
                    put(CallLog.Calls.NUMBER_PRESENTATION, (m["presentation"] as Number?)?.toInt() ?: CallLog.Calls.PRESENTATION_ALLOWED)
                }
                if (ctx.contentResolver.insert(CallLog.Calls.CONTENT_URI, v) != null) added++ else failed++
            } catch (_: Exception) { failed++ }
        }
        return mapOf("added" to added, "existing" to existing, "failed" to failed)
    }

    // ======================= calendar =======================

    /**
     * Events from calendars kept on the phone. Calendars synced to Google,
     * Exchange or Outlook are skipped: they come back by signing in on the new phone.
     */
    private fun readCalendar(): Map<String, Any?> {
        val calendars = HashMap<Long, Map<String, Any?>>()
        ctx.contentResolver.query(CalendarContract.Calendars.CONTENT_URI, arrayOf(
            CalendarContract.Calendars._ID, CalendarContract.Calendars.ACCOUNT_TYPE,
            CalendarContract.Calendars.CALENDAR_DISPLAY_NAME, CalendarContract.Calendars.CALENDAR_COLOR), null, null, null)?.use { c ->
            while (c.moveToNext()) {
                val type = c.getString(1) ?: ""
                if (GOOGLE_LIKE.contains(type)) continue
                calendars[c.getLong(0)] = mapOf("name" to (c.getString(2) ?: "Calendar"), "color" to c.getInt(3))
            }
        }
        val events = ArrayList<Map<String, Any?>>()
        if (calendars.isEmpty()) return mapOf("events" to events)
        val ids = calendars.keys.joinToString(",")
        val cols = arrayOf(CalendarContract.Events._ID, CalendarContract.Events.CALENDAR_ID, CalendarContract.Events.TITLE,
            CalendarContract.Events.DESCRIPTION, CalendarContract.Events.EVENT_LOCATION, CalendarContract.Events.DTSTART,
            CalendarContract.Events.DTEND, CalendarContract.Events.DURATION, CalendarContract.Events.ALL_DAY,
            CalendarContract.Events.RRULE, CalendarContract.Events.RDATE, CalendarContract.Events.EXRULE,
            CalendarContract.Events.EXDATE, CalendarContract.Events.EVENT_TIMEZONE, CalendarContract.Events.EVENT_END_TIMEZONE,
            CalendarContract.Events.AVAILABILITY, CalendarContract.Events.ACCESS_LEVEL)
        ctx.contentResolver.query(CalendarContract.Events.CONTENT_URI, cols,
            "${CalendarContract.Events.CALENDAR_ID} IN ($ids) AND ${CalendarContract.Events.DELETED} = 0", null, null)?.use { c ->
            while (c.moveToNext()) {
                val eventId = c.getLong(0)
                val reminders = ArrayList<Map<String, Any?>>()
                ctx.contentResolver.query(CalendarContract.Reminders.CONTENT_URI,
                    arrayOf(CalendarContract.Reminders.MINUTES, CalendarContract.Reminders.METHOD),
                    "${CalendarContract.Reminders.EVENT_ID} = ?", arrayOf(eventId.toString()), null)?.use { r ->
                    while (r.moveToNext()) reminders.add(mapOf("minutes" to r.getInt(0), "method" to r.getInt(1)))
                }
                val cal = calendars[c.getLong(1)]!!
                events.add(mapOf(
                    "calendar" to cal["name"], "color" to cal["color"], "title" to c.getString(2),
                    "description" to c.getString(3), "location" to c.getString(4), "dtstart" to c.getLong(5),
                    "dtend" to (if (c.isNull(6)) null else c.getLong(6)), "duration" to c.getString(7),
                    "allDay" to c.getInt(8), "rrule" to c.getString(9), "rdate" to c.getString(10),
                    "exrule" to c.getString(11), "exdate" to c.getString(12), "tz" to c.getString(13),
                    "endTz" to c.getString(14), "availability" to c.getInt(15), "accessLevel" to c.getInt(16),
                    "reminders" to reminders,
                ))
            }
        }
        return mapOf("events" to events)
    }

    private fun localCalendarId(name: String, color: Int): Long {
        val display = "$name (old phone)"
        calendarIds[display]?.let { return it }
        ctx.contentResolver.query(CalendarContract.Calendars.CONTENT_URI, arrayOf(CalendarContract.Calendars._ID),
            "${CalendarContract.Calendars.ACCOUNT_NAME} = ? AND ${CalendarContract.Calendars.CALENDAR_DISPLAY_NAME} = ?",
            arrayOf("Phone Clone", display), null)?.use { c -> if (c.moveToFirst()) return c.getLong(0).also { calendarIds[display] = it } }
        val uri = CalendarContract.Calendars.CONTENT_URI.buildUpon()
            .appendQueryParameter(CalendarContract.CALLER_IS_SYNCADAPTER, "true")
            .appendQueryParameter(CalendarContract.Calendars.ACCOUNT_NAME, "Phone Clone")
            .appendQueryParameter(CalendarContract.Calendars.ACCOUNT_TYPE, CalendarContract.ACCOUNT_TYPE_LOCAL).build()
        val v = ContentValues().apply {
            put(CalendarContract.Calendars.ACCOUNT_NAME, "Phone Clone")
            put(CalendarContract.Calendars.ACCOUNT_TYPE, CalendarContract.ACCOUNT_TYPE_LOCAL)
            put(CalendarContract.Calendars.NAME, display)
            put(CalendarContract.Calendars.CALENDAR_DISPLAY_NAME, display)
            put(CalendarContract.Calendars.CALENDAR_COLOR, color)
            put(CalendarContract.Calendars.CALENDAR_ACCESS_LEVEL, CalendarContract.Calendars.CAL_ACCESS_OWNER)
            put(CalendarContract.Calendars.OWNER_ACCOUNT, "Phone Clone")
            put(CalendarContract.Calendars.VISIBLE, 1)
            put(CalendarContract.Calendars.SYNC_EVENTS, 1)
        }
        val id = ctx.contentResolver.insert(uri, v)!!.lastPathSegment!!.toLong()
        calendarIds[display] = id
        return id
    }

    private fun eventKey(title: String?, start: Long) = "${title ?: ""}|$start"

    private fun writeCalendar(events: List<Map<String, Any?>>): Map<String, Int> {
        val seen = eventsSeen ?: HashSet<String>().also { set ->
            ctx.contentResolver.query(CalendarContract.Events.CONTENT_URI,
                arrayOf(CalendarContract.Events.TITLE, CalendarContract.Events.DTSTART), "${CalendarContract.Events.DELETED} = 0", null, null)?.use { c ->
                while (c.moveToNext()) set.add(eventKey(c.getString(0), c.getLong(1)))
            }
            eventsSeen = set
        }
        var added = 0; var existing = 0; var failed = 0
        for (e in events) {
            val start = (e["dtstart"] as Number).toLong()
            if (!seen.add(eventKey(e["title"] as String?, start))) { existing++; continue }
            try {
                val calId = localCalendarId(e["calendar"] as String? ?: "Calendar", (e["color"] as Number?)?.toInt() ?: 0xFF1B6EF3.toInt())
                val rrule = e["rrule"] as String?
                val v = ContentValues().apply {
                    put(CalendarContract.Events.CALENDAR_ID, calId)
                    put(CalendarContract.Events.TITLE, e["title"] as String?)
                    put(CalendarContract.Events.DESCRIPTION, e["description"] as String?)
                    put(CalendarContract.Events.EVENT_LOCATION, e["location"] as String?)
                    put(CalendarContract.Events.DTSTART, start)
                    put(CalendarContract.Events.ALL_DAY, (e["allDay"] as Number?)?.toInt() ?: 0)
                    put(CalendarContract.Events.EVENT_TIMEZONE, (e["tz"] as String?) ?: java.util.TimeZone.getDefault().id)
                    (e["endTz"] as String?)?.let { put(CalendarContract.Events.EVENT_END_TIMEZONE, it) }
                    if (rrule != null) {
                        put(CalendarContract.Events.RRULE, rrule)
                        put(CalendarContract.Events.DURATION, (e["duration"] as String?)
                            ?: (e["dtend"] as Number?)?.let { "P${(it.toLong() - start) / 1000}S" } ?: "PT1H")
                        (e["rdate"] as String?)?.let { put(CalendarContract.Events.RDATE, it) }
                        (e["exrule"] as String?)?.let { put(CalendarContract.Events.EXRULE, it) }
                        (e["exdate"] as String?)?.let { put(CalendarContract.Events.EXDATE, it) }
                    } else {
                        put(CalendarContract.Events.DTEND, (e["dtend"] as Number?)?.toLong() ?: (start + 3600_000L))
                    }
                    put(CalendarContract.Events.AVAILABILITY, (e["availability"] as Number?)?.toInt() ?: 0)
                    put(CalendarContract.Events.ACCESS_LEVEL, (e["accessLevel"] as Number?)?.toInt() ?: 0)
                }
                val uri = ctx.contentResolver.insert(CalendarContract.Events.CONTENT_URI, v)
                if (uri == null) { failed++; continue }
                val eventId = uri.lastPathSegment!!.toLong()
                @Suppress("UNCHECKED_CAST")
                for (r in (e["reminders"] as List<Map<String, Any?>>? ?: emptyList())) {
                    ctx.contentResolver.insert(CalendarContract.Reminders.CONTENT_URI, ContentValues().apply {
                        put(CalendarContract.Reminders.EVENT_ID, eventId)
                        put(CalendarContract.Reminders.MINUTES, (r["minutes"] as Number).toInt())
                        put(CalendarContract.Reminders.METHOD, (r["method"] as Number?)?.toInt() ?: CalendarContract.Reminders.METHOD_ALERT)
                    })
                }
                added++
            } catch (_: Exception) { failed++ }
        }
        return mapOf("added" to added, "existing" to existing, "failed" to failed)
    }

    // ======================= apps =======================

    /** Apps the user installed (not system apps), with their APK files. */
    private fun listApps(): List<Map<String, Any?>> {
        val pm = ctx.packageManager
        val launcher = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
        val packages = pm.queryIntentActivities(launcher, 0).map { it.activityInfo.packageName }.toSortedSet()
        val out = ArrayList<Map<String, Any?>>()
        for (pkg in packages) {
            if (pkg == ctx.packageName) continue
            try {
                val info = pm.getPackageInfo(pkg, 0)
                val app = info.applicationInfo ?: continue
                if ((app.flags and ApplicationInfo.FLAG_SYSTEM) != 0) continue
                val files = ArrayList<String>()
                files.add(app.sourceDir)
                app.splitSourceDirs?.let { files.addAll(it) }
                if (files.any { !File(it).canRead() }) continue
                val installer = try {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) pm.getInstallSourceInfo(pkg).installingPackageName
                    else @Suppress("DEPRECATION") pm.getInstallerPackageName(pkg)
                } catch (_: Exception) { null }
                out.add(mapOf(
                    "package" to pkg,
                    "label" to pm.getApplicationLabel(app).toString(),
                    "versionName" to info.versionName,
                    "versionCode" to (if (Build.VERSION.SDK_INT >= 28) info.longVersionCode else @Suppress("DEPRECATION") info.versionCode.toLong()),
                    "files" to files,
                    "fromPlay" to (installer == "com.android.vending"),
                ))
            } catch (_: Exception) { }
        }
        return out
    }

    private fun installedVersion(pkg: String): Long = try {
        val info = ctx.packageManager.getPackageInfo(pkg, 0)
        if (Build.VERSION.SDK_INT >= 28) info.longVersionCode else @Suppress("DEPRECATION") info.versionCode.toLong()
    } catch (_: PackageManager.NameNotFoundException) { -1L }

    /** Installs one app from its APK files. Android asks the user to confirm each install. */
    private fun installApks(paths: List<String>, result: MethodChannel.Result) {
        Thread {
            try {
                val installer = ctx.packageManager.packageInstaller
                val params = PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL)
                val sessionId = installer.createSession(params)
                installer.openSession(sessionId).use { session ->
                    for ((i, path) in paths.withIndex()) {
                        val f = File(path)
                        session.openWrite("part$i.apk", 0, f.length()).use { out ->
                            f.inputStream().use { it.copyTo(out) }
                            session.fsync(out)
                        }
                    }
                    installCallbacks[sessionId] = { ok, msg -> main.post { result.success(mapOf("ok" to ok, "message" to msg)) } }
                    val flags = PendingIntent.FLAG_UPDATE_CURRENT or (if (Build.VERSION.SDK_INT >= 31) PendingIntent.FLAG_MUTABLE else 0)
                    val pi = PendingIntent.getBroadcast(ctx, sessionId,
                        Intent(ctx, InstallResultReceiver::class.java).putExtra("sid", sessionId), flags)
                    session.commit(pi.intentSender)
                }
            } catch (e: Exception) {
                main.post { result.success(mapOf("ok" to false, "message" to (e.message ?: e.toString()))) }
            }
        }.start()
    }

    private fun openPlayStore(pkg: String) {
        try {
            startSettings(Intent(Intent.ACTION_VIEW, Uri.parse("market://details?id=$pkg")))
        } catch (_: Exception) {
            startSettings(Intent(Intent.ACTION_VIEW, Uri.parse("https://play.google.com/store/apps/details?id=$pkg")))
        }
    }

    // ======================= wallpaper =======================

    private fun readWallpaper(lock: Boolean): ByteArray? {
        val wm = WallpaperManager.getInstance(ctx)
        val flag = if (lock) WallpaperManager.FLAG_LOCK else WallpaperManager.FLAG_SYSTEM
        if (lock && wm.getWallpaperId(WallpaperManager.FLAG_LOCK) < 0) return null // lock screen uses the home wallpaper
        try {
            wm.getWallpaperFile(flag)?.use { pfd ->
                return android.os.ParcelFileDescriptor.AutoCloseInputStream(pfd).readBytes()
            }
        } catch (_: Exception) { }
        if (lock) return null
        val d = try { wm.drawable } catch (_: Exception) { null } ?: return null
        val bmp = Bitmap.createBitmap(d.intrinsicWidth.coerceAtLeast(1), d.intrinsicHeight.coerceAtLeast(1), Bitmap.Config.ARGB_8888)
        d.setBounds(0, 0, bmp.width, bmp.height)
        d.draw(Canvas(bmp))
        return ByteArrayOutputStream().also { bmp.compress(Bitmap.CompressFormat.PNG, 100, it) }.toByteArray()
    }

    // ======================= thumbnails =======================

    private fun drawablePng(d: android.graphics.drawable.Drawable, size: Int = 96): ByteArray {
        val bmp = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
        d.setBounds(0, 0, size, size)
        d.draw(Canvas(bmp))
        return ByteArrayOutputStream().also { bmp.compress(Bitmap.CompressFormat.PNG, 100, it) }.toByteArray()
    }

    /** Name, package and icon of an app, read from its APK file (works before it is installed). */
    private fun apkMeta(path: String): Map<String, Any?>? {
        val pm = ctx.packageManager
        @Suppress("DEPRECATION")
        val info = pm.getPackageArchiveInfo(path, 0) ?: return null
        val app = info.applicationInfo ?: return null
        app.sourceDir = path
        app.publicSourceDir = path
        return mapOf(
            "package" to info.packageName,
            "label" to pm.getApplicationLabel(app).toString(),
            "versionName" to info.versionName,
            "icon" to try { drawablePng(pm.getApplicationIcon(app)) } catch (_: Exception) { null },
        )
    }

    private fun appIcon(pkg: String): ByteArray? = try {
        drawablePng(ctx.packageManager.getApplicationIcon(pkg))
    } catch (_: Exception) { null }

    private fun videoThumb(path: String, size: Int): ByteArray? {
        val bmp = try {
            if (Build.VERSION.SDK_INT >= 29) {
                android.media.ThumbnailUtils.createVideoThumbnail(File(path), android.util.Size(size, size), null)
            } else {
                @Suppress("DEPRECATION")
                android.media.ThumbnailUtils.createVideoThumbnail(path, MediaStore.Images.Thumbnails.MINI_KIND)
            }
        } catch (_: Exception) { null } ?: return null
        return ByteArrayOutputStream().also { bmp.compress(Bitmap.CompressFormat.JPEG, 80, it) }.toByteArray()
    }

    // ======================= ringtones =======================

    private val ringtoneTypes = mapOf(
        "ringtone" to RingtoneManager.TYPE_RINGTONE,
        "notification" to RingtoneManager.TYPE_NOTIFICATION,
        "alarm" to RingtoneManager.TYPE_ALARM,
    )

    private fun readRingtones(): List<Map<String, Any?>> {
        val out = ArrayList<Map<String, Any?>>()
        for ((name, type) in ringtoneTypes) {
            val uri = RingtoneManager.getActualDefaultRingtoneUri(ctx, type) ?: continue
            var path: String? = null
            var title: String? = null
            try {
                @Suppress("DEPRECATION")
                ctx.contentResolver.query(uri, arrayOf(MediaStore.MediaColumns.DATA, MediaStore.MediaColumns.TITLE), null, null, null)?.use { c ->
                    if (c.moveToFirst()) { path = c.getString(0); title = c.getString(1) }
                }
            } catch (_: Exception) { }
            if (title == null) title = try { RingtoneManager.getRingtone(ctx, uri)?.getTitle(ctx) } catch (_: Exception) { null }
            out.add(mapOf("type" to name, "path" to path, "title" to title))
        }
        return out
    }

    private fun setRingtone(typeName: String, path: String?, title: String?): Boolean {
        val type = ringtoneTypes[typeName] ?: return false
        if (!Settings.System.canWrite(ctx)) return false
        var uri: Uri? = null
        if (path != null && File(path).exists()) {
            uri = mediaUriFor(path)
            if (uri == null) {
                val latch = CountDownLatch(1)
                MediaScannerConnection.scanFile(ctx, arrayOf(path), null) { _, u -> uri = u; latch.countDown() }
                latch.await(10, TimeUnit.SECONDS)
            }
        }
        if (uri == null && title != null) {
            val rm = RingtoneManager(ctx).apply { setType(type) }
            rm.cursor.use { c ->
                while (c.moveToNext()) {
                    if (c.getString(RingtoneManager.TITLE_COLUMN_INDEX) == title) { uri = rm.getRingtoneUri(c.position); break }
                }
            }
        }
        val u = uri ?: return false
        RingtoneManager.setActualDefaultRingtoneUri(ctx, type, u)
        return true
    }

    private fun mediaUriFor(path: String): Uri? {
        @Suppress("DEPRECATION")
        ctx.contentResolver.query(MediaStore.Audio.Media.EXTERNAL_CONTENT_URI, arrayOf(MediaStore.Audio.Media._ID),
            "${MediaStore.Audio.Media.DATA} = ?", arrayOf(path), null)?.use { c ->
            if (c.moveToFirst()) return Uri.withAppendedPath(MediaStore.Audio.Media.EXTERNAL_CONTENT_URI, c.getLong(0).toString())
        }
        return null
    }
}
