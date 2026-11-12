import Foundation
import CoreBluetooth
import CryptoKit

/// Fully event-driven: the PC's Tick notification wakes the app (even in background),
/// the app reads RSSI and answers with a signed heartbeat.
@MainActor
final class BLEManager: NSObject, ObservableObject {
    @Published private(set) var status = "Idle"
    @Published private(set) var rssi: Int?
    @Published private(set) var isEnabled: Bool
    @Published private(set) var hasKey = false

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var heartbeatChar: CBCharacteristic?
    private var pendingChallenge: Data?
    private var key: SymmetricKey?

    override init() {
        isEnabled = UserDefaults.standard.object(forKey: "enabled") as? Bool ?? true
        super.init()
        if let k = KeyStore.load() {
            key = SymmetricKey(data: k)
            hasKey = true
        }
        central = CBCentralManager(delegate: self, queue: nil,
                                   options: [CBCentralManagerOptionRestoreIdentifierKey: Config.restoreID])
    }

    // MARK: - Control

    func setEnabled(_ on: Bool) {
        isEnabled = on
        UserDefaults.standard.set(on, forKey: "enabled")
        if on {
            if central.state == .poweredOn { connectOrScan() }
        } else {
            central.stopScan()
            if let p = peripheral { central.cancelPeripheralConnection(p) }
            heartbeatChar = nil
            rssi = nil
            status = "Disabled"
        }
    }

    @discardableResult
    func setKey(base64: String) -> Bool {
        let trimmed = base64.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = Data(base64Encoded: trimmed), data.count >= 32 else {
            status = "Invalid key"
            return false
        }
        guard KeyStore.save(data) else {
            status = "Keychain error"
            return false
        }
        key = SymmetricKey(data: data)
        hasKey = true
        return true
    }

    // MARK: - Internals

    private func connectOrScan() {
        guard isEnabled else { return }
        if let p = peripheral {
            if p.state == .connected {
                p.discoverServices([Config.serviceUUID])
            } else {
                status = "Waiting for PC…"
                central.connect(p)          // pending connect never times out, works in background
            }
        } else {
            status = "Searching for PC…"
            central.scanForPeripherals(withServices: [Config.serviceUUID])
        }
    }

    private func answer(challenge: Data, rssi value: Int) {
        guard let p = peripheral, let ch = heartbeatChar else { return }
        guard let key else {
            status = "No key — paste it below"
            return
        }
        var payload = challenge
        payload.append(UInt8(bitPattern: Int8(clamping: value)))
        let mac = HMAC<SHA256>.authenticationCode(for: payload, using: key)
        payload.append(contentsOf: Data(mac).prefix(8))
        p.writeValue(payload, for: ch, type: .withResponse)
    }
}

// MARK: - CoreBluetooth delegates (delivered on main queue)

extension BLEManager: CBCentralManagerDelegate, CBPeripheralDelegate {

    nonisolated func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        let restored = (dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral])?.first
        MainActor.assumeIsolated {
            guard let restored else { return }
            peripheral = restored
            restored.delegate = self
        }
    }

    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let state = central.state
        MainActor.assumeIsolated {
            switch state {
            case .poweredOn:    connectOrScan()
            case .unauthorized: status = "Bluetooth permission denied"
            default:            status = "Bluetooth unavailable"
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any], rssi RSSI: NSNumber) {
        MainActor.assumeIsolated {
            self.central.stopScan()
            self.peripheral = peripheral
            peripheral.delegate = self
            status = "Connecting…"
            self.central.connect(peripheral)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        MainActor.assumeIsolated {
            status = "Discovering…"
            peripheral.discoverServices([Config.serviceUUID])
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral,
                                    error: Error?) {
        MainActor.assumeIsolated {
            self.peripheral = nil
            connectOrScan()
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                                    error: Error?) {
        MainActor.assumeIsolated {
            heartbeatChar = nil
            pendingChallenge = nil
            rssi = nil
            connectOrScan()
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        MainActor.assumeIsolated {
            guard let svc = peripheral.services?.first(where: { $0.uuid == Config.serviceUUID }) else {
                status = "Service not found"
                return
            }
            peripheral.discoverCharacteristics([Config.heartbeatUUID, Config.tickUUID], for: svc)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService,
                                error: Error?) {
        MainActor.assumeIsolated {
            let chars = service.characteristics ?? []
            heartbeatChar = chars.first { $0.uuid == Config.heartbeatUUID }
            guard heartbeatChar != nil, let tick = chars.first(where: { $0.uuid == Config.tickUUID }) else {
                status = "Characteristics not found"
                return
            }
            peripheral.setNotifyValue(true, for: tick)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic,
                                error: Error?) {
        MainActor.assumeIsolated {
            status = error == nil ? "Connected" : "Subscribe failed: \(error!.localizedDescription)"
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic,
                                error: Error?) {
        let uuid = characteristic.uuid
        let value = characteristic.value.map { Data($0) }
        MainActor.assumeIsolated {
            guard error == nil, uuid == Config.tickUUID, let value, value.count == 8 else { return }
            pendingChallenge = value
            peripheral.readRSSI()
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        MainActor.assumeIsolated {
            guard let challenge = pendingChallenge else { return }
            pendingChallenge = nil
            let value = RSSI.intValue
            guard error == nil, value != 127 else { return }   // 127 = unavailable → PC will time out
            rssi = value
            answer(challenge: challenge, rssi: value)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic,
                                error: Error?) {
        MainActor.assumeIsolated {
            if let error {
                status = "Rejected: \(error.localizedDescription)"
            } else if status != "Connected" {
                status = "Connected"
            }
        }
    }
}
