package com.smarterswitch.app.native

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * Default-SMS-app stub. Required by Android for the app to be eligible to
 * become the default SMS app, but it's a no-op during transfer — the user
 * is the default SMS app for ~seconds while we batch-write old messages,
 * and any genuinely incoming SMS during that window is dropped (not
 * silently — Android delivers it via this receiver, we just discard it).
 *
 * If a user is concerned about missing live messages during transfer, they
 * can airplane-mode the receiving phone first; the v0.6 release notes
 * call this out.
 */
class SmsDeliverReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        // Intentionally empty. See class doc.
    }
}
