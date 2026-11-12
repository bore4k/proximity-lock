import SwiftUI

@main
struct ProximityLockApp: App {
    @StateObject private var ble = BLEManager()

    var body: some Scene {
        WindowGroup {
            ContentView().environmentObject(ble)
        }
    }
}
