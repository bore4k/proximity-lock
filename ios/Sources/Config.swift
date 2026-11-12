import CoreBluetooth

enum Config {
    // Must match GattServer.cs
    static let serviceUUID   = CBUUID(string: "8E3B1A20-5C4D-4F7A-9B21-6D0C3E7F1A01")
    static let heartbeatUUID = CBUUID(string: "8E3B1A21-5C4D-4F7A-9B21-6D0C3E7F1A01")
    static let tickUUID      = CBUUID(string: "8E3B1A22-5C4D-4F7A-9B21-6D0C3E7F1A01")

    static let restoreID = "ProximityLockCentral"
}
