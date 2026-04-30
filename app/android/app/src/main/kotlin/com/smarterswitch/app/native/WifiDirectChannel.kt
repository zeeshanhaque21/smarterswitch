package com.smarterswitch.app.native

import android.app.Activity
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.net.wifi.p2p.WifiP2pConfig
import android.net.wifi.p2p.WifiP2pDevice
import android.net.wifi.p2p.WifiP2pManager
import android.net.wifi.p2p.WifiP2pManager.GroupInfoListener
import android.net.wifi.p2p.WifiP2pManager.PeerListListener
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Wraps Android `WifiP2pManager` so the Dart side can drive Wi-Fi Direct
 * peer discovery and group formation without depending on a third-party
 * Flutter plugin.
 *
 * Channel: `smarterswitch/wifi_direct`. Methods:
 * - `isAvailable`: Bool — does this device's PackageManager declare
 *   FEATURE_WIFI_DIRECT?
 * - `enable`: register the BroadcastReceiver. Idempotent.
 * - `disable`: unregister + cancel any active operation.
 * - `discoverPeers`: kick off a discovery scan.
 * - `getPeers`: List<Map> of currently-known peers (deviceAddress,
 *   deviceName, primaryDeviceType).
 * - `connect`: form a P2P group with the named peer. Receiver pins
 *   groupOwnerIntent=15 so it deterministically becomes the GO and
 *   binds the TCP listener at the framework-assigned 192.168.49.1.
 * - `getConnectionInfo`: Map of {connected, isGroupOwner, groupOwnerAddress}.
 * - `removeGroup`: tear down. Mostly to recover from a stuck/half-formed
 *   group between attempts.
 *
 * The actual TCP socket + handshake + AES-GCM seal is handled in pure
 * Dart (`SecureSocketSession`) — this channel just gets the two devices
 * onto the same L2 link.
 */
object WifiDirectChannel {
    private const val CHANNEL = "smarterswitch/wifi_direct"

    private var manager: WifiP2pManager? = null
    private var p2pChannel: WifiP2pManager.Channel? = null
    private var receiver: BroadcastReceiver? = null
    private var lastPeers: List<WifiP2pDevice> = emptyList()
    private var lastConnected: Boolean = false
    private var lastIsGroupOwner: Boolean = false
    private var lastGroupOwnerAddress: String? = null

    fun register(flutterEngine: FlutterEngine, activity: Activity) {
        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "isAvailable" -> result.success(isAvailable(activity))
                "enable" -> handleEnable(activity, result)
                "disable" -> handleDisable(activity, result)
                "discoverPeers" -> handleDiscover(result)
                "getPeers" -> result.success(peersToMap())
                "connect" -> handleConnect(call, result)
                "getConnectionInfo" -> result.success(connectionInfoMap())
                "removeGroup" -> handleRemoveGroup(result)
                else -> result.notImplemented()
            }
        }
    }

    private fun isAvailable(context: Context): Boolean {
        return context.packageManager.hasSystemFeature(
            PackageManager.FEATURE_WIFI_DIRECT,
        )
    }

    private fun handleEnable(activity: Activity, result: MethodChannel.Result) {
        if (manager != null) {
            result.success(true)
            return
        }
        val mgr = activity.getSystemService(Context.WIFI_P2P_SERVICE) as? WifiP2pManager
        if (mgr == null) {
            result.error("NO_P2P", "WifiP2pManager not available", null)
            return
        }
        manager = mgr
        p2pChannel = mgr.initialize(activity, activity.mainLooper, null)

        val intentFilter = IntentFilter().apply {
            addAction(WifiP2pManager.WIFI_P2P_STATE_CHANGED_ACTION)
            addAction(WifiP2pManager.WIFI_P2P_PEERS_CHANGED_ACTION)
            addAction(WifiP2pManager.WIFI_P2P_CONNECTION_CHANGED_ACTION)
            addAction(WifiP2pManager.WIFI_P2P_THIS_DEVICE_CHANGED_ACTION)
        }
        val r = object : BroadcastReceiver() {
            override fun onReceive(ctx: Context, intent: Intent) {
                onP2pBroadcast(intent)
            }
        }
        receiver = r
        activity.registerReceiver(r, intentFilter)
        result.success(true)
    }

    private fun handleDisable(activity: Activity, result: MethodChannel.Result) {
        try {
            receiver?.let { activity.unregisterReceiver(it) }
        } catch (_: Exception) {}
        receiver = null
        manager = null
        p2pChannel = null
        lastPeers = emptyList()
        lastConnected = false
        lastIsGroupOwner = false
        lastGroupOwnerAddress = null
        result.success(true)
    }

    private fun onP2pBroadcast(intent: Intent) {
        val mgr = manager ?: return
        val ch = p2pChannel ?: return
        when (intent.action) {
            WifiP2pManager.WIFI_P2P_PEERS_CHANGED_ACTION -> {
                mgr.requestPeers(ch, PeerListListener { peerList ->
                    lastPeers = peerList.deviceList.toList()
                })
            }
            WifiP2pManager.WIFI_P2P_CONNECTION_CHANGED_ACTION -> {
                mgr.requestConnectionInfo(ch) { info ->
                    lastConnected = info.groupFormed
                    lastIsGroupOwner = info.isGroupOwner
                    lastGroupOwnerAddress = info.groupOwnerAddress?.hostAddress
                }
                // Also refresh group info — useful when client wants the
                // owner's IP after connection completes.
                mgr.requestGroupInfo(ch, GroupInfoListener { /* state cached above */ })
            }
        }
    }

    private fun handleDiscover(result: MethodChannel.Result) {
        val mgr = manager
        val ch = p2pChannel
        if (mgr == null || ch == null) {
            result.error("NOT_ENABLED", "Call enable() first", null)
            return
        }
        mgr.discoverPeers(ch, object : WifiP2pManager.ActionListener {
            override fun onSuccess() {
                result.success(true)
            }

            override fun onFailure(reason: Int) {
                result.error(
                    "DISCOVERY_FAILED",
                    "discoverPeers failed: ${reasonToText(reason)}",
                    null,
                )
            }
        })
    }

    private fun peersToMap(): List<Map<String, Any?>> {
        return lastPeers.map {
            mapOf(
                "deviceAddress" to it.deviceAddress,
                "deviceName" to it.deviceName,
                "primaryDeviceType" to (it.primaryDeviceType ?: ""),
                "status" to it.status,
            )
        }
    }

    private fun connectionInfoMap(): Map<String, Any?> = mapOf(
        "connected" to lastConnected,
        "isGroupOwner" to lastIsGroupOwner,
        "groupOwnerAddress" to lastGroupOwnerAddress,
    )

    private fun handleConnect(call: MethodCall, result: MethodChannel.Result) {
        val mgr = manager
        val ch = p2pChannel
        if (mgr == null || ch == null) {
            result.error("NOT_ENABLED", "Call enable() first", null)
            return
        }
        val deviceAddress = call.argument<String>("deviceAddress")
        val isReceiver = call.argument<Boolean>("isReceiver") ?: false
        if (deviceAddress == null) {
            result.error("BAD_ARGUMENT", "deviceAddress required", null)
            return
        }
        val config = WifiP2pConfig().apply {
            this.deviceAddress = deviceAddress
            // Receiver pinned as GO so it deterministically owns 192.168.49.1
            // and runs the TCP listener.
            this.groupOwnerIntent = if (isReceiver) 15 else 0
        }
        mgr.connect(ch, config, object : WifiP2pManager.ActionListener {
            override fun onSuccess() {
                result.success(true)
            }
            override fun onFailure(reason: Int) {
                result.error(
                    "CONNECT_FAILED",
                    "connect failed: ${reasonToText(reason)}",
                    null,
                )
            }
        })
    }

    private fun handleRemoveGroup(result: MethodChannel.Result) {
        val mgr = manager
        val ch = p2pChannel
        if (mgr == null || ch == null) {
            result.success(true)
            return
        }
        mgr.removeGroup(ch, object : WifiP2pManager.ActionListener {
            override fun onSuccess() {
                lastConnected = false
                lastIsGroupOwner = false
                lastGroupOwnerAddress = null
                result.success(true)
            }
            override fun onFailure(reason: Int) {
                result.success(false)
            }
        })
    }

    private fun reasonToText(reason: Int): String = when (reason) {
        WifiP2pManager.P2P_UNSUPPORTED -> "P2P_UNSUPPORTED"
        WifiP2pManager.ERROR -> "ERROR"
        WifiP2pManager.BUSY -> "BUSY"
        else -> "code=$reason"
    }
}
