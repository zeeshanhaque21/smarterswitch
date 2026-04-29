package com.smarterswitch.app

import com.smarterswitch.app.native.CalendarChannel
import com.smarterswitch.app.native.CallLogChannel
import com.smarterswitch.app.native.ContactsChannel
import com.smarterswitch.app.native.MediaChannel
import com.smarterswitch.app.native.SmsChannel
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
    }
}
