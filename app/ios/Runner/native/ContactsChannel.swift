// iOS native handlers — placeholder per ROADMAP Phase 0. The actual Swift code
// for Contacts / Photos / Calendar / Files is deferred until a Mac is
// available; this file exists so the file structure mirrors the Android side
// and the iOS dev path is unambiguous.
//
// To wire up later:
//   1. Add ContactsChannel, PhotosChannel, CalendarChannel as separate files
//      in this directory.
//   2. In AppDelegate.didInitializeImplicitFlutterEngine, after
//      GeneratedPluginRegistrant.register(...), call:
//        ContactsChannel.register(with: engineBridge.pluginRegistry)
//      (and the same for the other channels).
//   3. Use FlutterMethodChannel(name: "smarterswitch/contacts", ...) and route
//      methods to the Contacts framework. See ARCHITECTURE.md § platform/ios.
//
// No SMS or call-log channel — Apple does not expose those APIs to third-party
// apps. See ARCHITECTURE.md § Platform constraints.

import Flutter
import Foundation

enum ContactsChannel {
    static let name = "smarterswitch/contacts"

    static func register(with registrar: FlutterPluginRegistry) {
        let messenger = registrar.registrar(forPlugin: "ContactsChannel")?.messenger()
        guard let messenger = messenger else { return }
        let channel = FlutterMethodChannel(name: name, binaryMessenger: messenger)
        channel.setMethodCallHandler { call, result in
            switch call.method {
            case "hasReadPermission":
                // TODO: CNContactStore.authorizationStatus(for: .contacts)
                result(FlutterMethodNotImplemented)
            case "readAll":
                // TODO: CNContactStore().enumerateContacts(...)
                result(FlutterMethodNotImplemented)
            default:
                result(FlutterMethodNotImplemented)
            }
        }
    }
}
