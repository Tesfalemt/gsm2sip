package com.callagent.gateway.net

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/**
 * Optional remote copy of the gateway's log (Settings → Remote log URL).
 *
 * Off unless an https:// URL is set.  Every line the Logs screen gets is
 * queued and posted in batches every couple of seconds as
 *
 *     {"launch": "g2s-xxxx", "entries": [{"t": <epoch ms>, "level": "info|error", "msg": "…"}]}
 *
 * so a gateway in another country can be watched live from a log server
 * (the format MoonShot's /moonshot/logs/client takes).  The lines carry what
 * the Logs screen carries — phone numbers, SIP status, SMS events — so only
 * point it at a server you control.
 *
 * A failed post is dropped and never logged: logging it would feed straight
 * back into the queue.  The URL is read from preferences on every flush, so
 * saving a new one (or clearing it) takes effect within a couple of seconds.
 */
object RemoteLog {
    private const val PREF_KEY = "remote_log_url"
    private const val MAX_QUEUE = 1000
    private const val BATCH = 200
    private const val FLUSH_SECS = 2L

    private val queue = ArrayList<JSONObject>()
    private val launch = "g2s-" + (1..4).map { "abcdefghijkmnpqrstuvwxyz23456789".random() }.joinToString("")

    @Volatile
    private var appContext: Context? = null
    private val sender = Executors.newSingleThreadScheduledExecutor { r ->
        Thread(r, "remote-log").apply { isDaemon = true }
    }

    fun init(context: Context) {
        if (appContext != null) return
        appContext = context.applicationContext
        sender.scheduleWithFixedDelay({ runCatching { flush() } }, FLUSH_SECS, FLUSH_SECS, TimeUnit.SECONDS)
    }

    fun add(msg: String) {
        if (url() == null) return
        synchronized(queue) {
            queue.add(
                JSONObject()
                    .put("t", System.currentTimeMillis())
                    .put("level", if (msg.contains("ERROR")) "error" else "info")
                    .put("msg", msg)
            )
            while (queue.size > MAX_QUEUE) queue.removeAt(0)
        }
    }

    private fun url(): String? =
        appContext?.getSharedPreferences("gateway", Context.MODE_PRIVATE)
            ?.getString(PREF_KEY, "")?.trim()?.takeIf { it.startsWith("https://") }

    private fun flush() {
        val target = url()
        if (target == null) {
            synchronized(queue) { queue.clear() }
            return
        }
        val batch = synchronized(queue) {
            if (queue.isEmpty()) return
            val b = queue.take(BATCH)
            repeat(b.size) { queue.removeAt(0) }
            b
        }
        val body = JSONObject().put("launch", launch).put("entries", JSONArray(batch)).toString().toByteArray()
        val conn = URL(target).openConnection() as HttpURLConnection
        try {
            conn.requestMethod = "POST"
            conn.connectTimeout = 10_000
            conn.readTimeout = 10_000
            conn.doOutput = true
            conn.setRequestProperty("Content-Type", "application/json")
            conn.outputStream.use { it.write(body) }
            conn.responseCode
        } catch (_: Exception) {
            // Dropped on purpose (see the class comment).
        } finally {
            conn.disconnect()
        }
    }
}
