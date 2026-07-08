package com.zeus.thunderpeak

import android.app.Activity
import android.app.ActivityManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

/**
 * ThunderPeak host Activity.
 *
 * Bridges the WebView's `<input type="file">` selector to a native
 * Storage Access Framework chooser. The Flutter side (`WebArena`)
 * dispatches a `pick` call over the [attachChannel] and receives a
 * list of `content://` URIs to hand back to the WebView.
 *
 * This is deliberately dependency-free — no `file_picker` plugin.
 * See `.cursor/rules/gray_part_pitfalls.md` §1 for the reason (the
 * 10.x line of file_picker ships its own KGP and collides with
 * Flutter's built-in Kotlin support).
 *
 * [FINGERPRINT] The channel name AND the request code below must
 * be unique per project and mirror the Dart side literally.
 */
class MainActivity : FlutterActivity() {

    private val attachChannel = "peak/attach"
    // [FINGERPRINT] Separate debug channel — only used by DebugKit and
    // therefore only wired in debug builds on the Dart side. Keeping
    // it isolated from attachChannel means release APKs can strip the
    // Dart-side caller without touching any production code path.
    private val devChannel = "peak/dev"
    // Inbound-link bridge — exposes the URI that launched the activity
    // (or was delivered via onNewIntent) to the Dart router. The
    // router uses this to detect a OneLink tap and take the gray path
    // WITHOUT waiting for AppsFlyer's SDK to report a click.
    private val linkMethodChannel = "peak/route"
    private val linkEventChannel = "peak/route/events"
    private val attachRequestCode = 0x50C7
    private var pendingBridge: MethodChannel.Result? = null
    // The URI from Intent.ACTION_VIEW that started (or re-started) us.
    // Null on a normal LAUNCHER intent. Consumed by the Dart side.
    private var pendingLink: String? = null
    private var linkSink: EventChannel.EventSink? = null

    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        // Capture the launching URI as early as possible — the
        // FlutterEngine may take a beat to attach, so we cache it
        // and hand it over on the first `getInitialLink()` call.
        pendingLink = extractLink(intent)
        super.onCreate(savedInstanceState)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        val link = extractLink(intent) ?: return
        // If the Dart side is already listening, push through the
        // stream; otherwise stash for the next getInitialLink() call.
        val sink = linkSink
        if (sink != null) {
            sink.success(link)
        } else {
            pendingLink = link
        }
    }

    private fun extractLink(intent: Intent?): String? {
        if (intent == null) return null
        if (intent.action != Intent.ACTION_VIEW) return null
        val uri = intent.data ?: return null
        val s = uri.toString()
        if (s.isBlank()) return null
        return s
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, attachChannel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "pick" -> {
                        val multiple = call.argument<Boolean>("multiple") ?: false
                        val mimes = call.argument<List<String>>("mimeTypes") ?: emptyList()
                        launchChooser(multiple, mimes, result)
                    }
                    else -> result.notImplemented()
                }
            }

        // Inbound-link method channel — one-shot fetch of the URI
        // that launched the activity. Returns null when there was no
        // ACTION_VIEW / when the URI was already consumed.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, linkMethodChannel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getInitialLink" -> {
                        val link = pendingLink
                        pendingLink = null
                        result.success(link)
                    }
                    else -> result.notImplemented()
                }
            }

        // Inbound-link event stream — every subsequent ACTION_VIEW
        // (delivered via onNewIntent when the activity is already in
        // singleTask) is pushed here.
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, linkEventChannel)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    linkSink = events
                    // If a URI arrived before the Dart listener was up,
                    // deliver it immediately — but do NOT clear it here,
                    // because getInitialLink() may still need it.
                    val stashed = pendingLink
                    if (stashed != null && events != null) {
                        events.success(stashed)
                    }
                }

                override fun onCancel(arguments: Any?) {
                    linkSink = null
                }
            })

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, devChannel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "open_in_chrome" -> {
                        val url = call.argument<String>("url")
                        if (url.isNullOrBlank()) {
                            result.success(false)
                        } else {
                            result.success(openInExternalBrowser(url))
                        }
                    }
                    "clear_app_data" -> {
                        // Wipes SharedPreferences, secure storage, AppsFlyer
                        // cache and every other data owned by this package.
                        // Android will kill the process synchronously after
                        // the call, so the Dart side never sees a return.
                        val am = getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
                        val ok = am.clearApplicationUserData()
                        result.success(ok)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    /**
     * Opens [url] in a real browser, DELIBERATELY BYPASSING this
     * app's own OneLink intent-filter — otherwise Android would
     * hand the OneLink click to us instead of registering it as a
     * browser click on AppsFlyer's servers.
     *
     * Tries Chrome first, then any installed browser that is not
     * this app. Returns true on success.
     */
    private fun openInExternalBrowser(url: String): Boolean {
        val uri = Uri.parse(url)
        val myPkg = packageName

        val chromeIntent = Intent(Intent.ACTION_VIEW, uri).apply {
            setPackage("com.android.chrome")
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        if (chromeIntent.resolveActivity(packageManager) != null) {
            try {
                startActivity(chromeIntent)
                return true
            } catch (_: Throwable) { /* fall through */ }
        }

        // Fallback: pick any browser that isn't us.
        val probe = Intent(Intent.ACTION_VIEW, Uri.parse("https://example.invalid"))
        val browsers = packageManager.queryIntentActivities(probe, PackageManager.MATCH_DEFAULT_ONLY)
        for (info in browsers) {
            val pkg = info.activityInfo.packageName
            if (pkg == myPkg) continue
            val intent = Intent(Intent.ACTION_VIEW, uri).apply {
                setPackage(pkg)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            try {
                startActivity(intent)
                return true
            } catch (_: Throwable) { /* try next */ }
        }
        return false
    }

    private fun launchChooser(
        multiple: Boolean,
        mimes: List<String>,
        result: MethodChannel.Result,
    ) {
        // A previously abandoned dialog should return empty first.
        pendingBridge?.success(emptyList<String>())
        pendingBridge = result

        val valid = mimes.filter { it.contains("/") }
        val intent = Intent(Intent.ACTION_GET_CONTENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            putExtra(Intent.EXTRA_ALLOW_MULTIPLE, multiple)
            when {
                valid.isEmpty() -> type = "*/*"
                valid.size == 1 -> type = valid[0]
                else -> {
                    type = "*/*"
                    putExtra(Intent.EXTRA_MIME_TYPES, valid.toTypedArray())
                }
            }
        }

        try {
            startActivityForResult(Intent.createChooser(intent, null), attachRequestCode)
        } catch (t: Throwable) {
            pendingBridge = null
            result.success(emptyList<String>())
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != attachRequestCode) return

        val bridge = pendingBridge
        pendingBridge = null
        if (bridge == null) return

        if (resultCode != Activity.RESULT_OK || data == null) {
            bridge.success(emptyList<String>())
            return
        }

        val uris = ArrayList<String>()
        val clip = data.clipData
        if (clip != null) {
            for (i in 0 until clip.itemCount) {
                uris.add(clip.getItemAt(i).uri.toString())
            }
        } else {
            data.data?.let { uris.add(it.toString()) }
        }
        bridge.success(uris)
    }
}
