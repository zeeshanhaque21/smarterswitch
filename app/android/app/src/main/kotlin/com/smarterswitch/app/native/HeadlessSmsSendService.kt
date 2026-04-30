package com.smarterswitch.app.native

import android.app.Service
import android.content.Intent
import android.os.IBinder

/**
 * RESPOND_VIA_MESSAGE stub. Required by the default-SMS-app role; not
 * functional — we don't reply to calls with SMS. The service exists only
 * so the manifest declares all four required components.
 */
class HeadlessSmsSendService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        stopSelf()
        return START_NOT_STICKY
    }
}
