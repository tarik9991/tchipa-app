package uk.co.tchipa.tchipa2

import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

// Product links from the website: tchipa2://produit/<id>.
// The link is kept in `pending` until Flutter asks for it ("initial"), so it is
// not lost while the catalogue is still loading.
class MainActivity : FlutterActivity() {
    private var channel: MethodChannel? = null
    private var pending: String? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        pending = intent?.dataString
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "tchipa2/deeplink").apply {
            setMethodCallHandler { call, result ->
                if (call.method == "initial") {
                    result.success(pending)
                    pending = null
                } else {
                    result.notImplemented()
                }
            }
        }
    }

    // App already running (launchMode singleTop): store the link and tell Flutter.
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        val link = intent.dataString ?: return
        pending = link
        channel?.invokeMethod("ping", null)
    }
}
