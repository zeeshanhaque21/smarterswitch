package com.smarterswitch.app

import android.content.Intent
import com.smarterswitch.app.native.CalendarChannel
import com.smarterswitch.app.native.CallLogChannel
import com.smarterswitch.app.native.ContactsChannel
import com.smarterswitch.app.native.ForegroundChannel
import com.smarterswitch.app.native.MediaChannel
import com.smarterswitch.app.native.SmsChannel
import com.smarterswitch.app.native.WifiDirectChannel
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        SmsChannel.register(flutterEngine, this)
        CallLogChannel.register(flutterEngine, this)
        ContactsChannel.register(flutterEngine, this)
        MediaChannel.register(flutterEngine, this)
        CalendarChannel.register(flutterEngine, this)
        ForegroundChannel.register(flutterEngine, this)
        WifiDirectChannel.register(flutterEngine, this)
    }

    @Deprecated("Required to forward role-grab results to SmsChannel")
    override fun onActivityResult(
        requestCode: Int,
        resultCode: Int,
        data: Intent?,
    ) {
        super.onActivityResult(requestCode, resultCode, data)
        SmsChannel.handleActivityResult(this, requestCode, resultCode)
    }
}
