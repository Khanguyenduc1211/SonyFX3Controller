import Foundation
import UIKit

extension Notification.Name {
    static let cameraViewModelDidChange = Notification.Name("CameraViewModelDidChange")
}

final class CameraViewModel {
    static let shared = CameraViewModel()
    private let bridge = SonyCameraBridge()
    private(set) var profile = CameraProfileStore.load()
    private(set) var properties: [UInt16: NSDictionary] = [:]
    private(set) var connected = false
    private(set) var recordState: UInt32 = UInt32.max
    var recordingStartedAt: Date?
    var onChange: (() -> Void)?
    private var statePoller: Timer?
    private var refreshInFlight = false

    private init() {
        NotificationCenter.default.addObserver(
            forName: Notification.Name("SonyCameraBridgeStateDidChange"),
            object: bridge,
            queue: .main
        ) { [weak self] note in
            guard let self else { return }

            let bridged = self.bridge.stateSnapshot()
            var converted: [UInt16: NSDictionary] = [:]
            for (key, value) in bridged {
                converted[key.uint16Value] = value as NSDictionary
            }
            self.properties = converted

            let previous = self.recordState
            self.recordState = note.userInfo?["recordState"] as? UInt32 ?? UInt32.max
            if previous != 1 && self.recordState == 1 {
                self.recordingStartedAt = Date()
            }
            if self.recordState != 1 {
                self.recordingStartedAt = nil
            }

            self.notifyChange()
        }
    }

    private func notifyChange() {
        onChange?()
        NotificationCenter.default.post(name: .cameraViewModelDidChange, object: self)
    }

    func connect(
        host: String,
        username: String,
        password: String,
        trust: Bool = false,
        done: @escaping (String, String?) -> Void
    ) {
        let old = profile
        profile.host = host
        profile.username = username
        if old.host != host || old.username != username {
            profile.fingerprint = ""
        }

        CameraProfileStore.save(profile)
        CameraProfileStore.savePassword(password, for: profile)

        bridge.connectHost(
            host,
            username: username,
            password: password,
            trustedFingerprint: trust ? profile.fingerprint : profile.fingerprint
        ) { [weak self] ok, needsTrust, message, fingerprint in
            guard let self else { return }
            if ok {
                self.connected = true
                self.startPolling()
                self.notifyChange()
                done(message, nil)
            } else if needsTrust {
                done(message, fingerprint)
            } else {
                done(message, nil)
            }
        }
    }

    func trustAndConnect(
        host: String,
        username: String,
        password: String,
        fingerprint: String,
        done: @escaping (String) -> Void
    ) {
        profile = CameraProfile(host: host, username: username, fingerprint: fingerprint)
        CameraProfileStore.save(profile)
        CameraProfileStore.savePassword(password, for: profile)

        bridge.connectHost(
            host,
            username: username,
            password: password,
            trustedFingerprint: fingerprint
        ) { [weak self] ok, _, message, _ in
            guard let self else { return }
            self.connected = ok
            if ok { self.startPolling() }
            self.notifyChange()
            done(message)
        }
    }

    func disconnect() {
        statePoller?.invalidate()
        statePoller = nil
        refreshInFlight = false
        bridge.disconnect()
        connected = false
        properties = [:]
        recordState = UInt32.max
        recordingStartedAt = nil
        notifyChange()
    }

    func refresh(_ done: @escaping (String) -> Void) {
        bridge.refresh { _, message in done(message) }
    }

    func values(for property: UInt16) -> [Int64] {
        guard let propertyState = properties[property] else { return [] }

        let supported = propertyState["getSetValues"] as? [NSNumber] ?? []
        if !supported.isEmpty {
            return supported.map { $0.int64Value }
        }

        let fallback = propertyState["setValues"] as? [NSNumber] ?? []
        if !fallback.isEmpty {
            return fallback.map { $0.int64Value }
        }

        guard
            let minimum = (propertyState["rangeMinimum"] as? NSNumber)?.int64Value,
            let maximum = (propertyState["rangeMaximum"] as? NSNumber)?.int64Value,
            let step = (propertyState["rangeStep"] as? NSNumber)?.int64Value,
            step > 0,
            maximum >= minimum
        else {
            return []
        }

        let count = ((maximum - minimum) / step) + 1
        guard count > 0, count <= 512 else { return [] }
        return (0..<Int(count)).map { minimum + Int64($0) * step }
    }

    func current(for property: UInt16) -> Int64? {
        (properties[property]?["current"] as? NSNumber)?.int64Value
    }

    func writable(_ property: UInt16) -> Bool {
        (properties[property]?["writable"] as? NSNumber)?.boolValue == true &&
        (properties[property]?["enabled"] as? NSNumber)?.boolValue == true
    }

    func enabled(_ property: UInt16) -> Bool {
        (properties[property]?["enabled"] as? NSNumber)?.boolValue == true
    }

    func cineEIActive() -> Bool {
        guard let raw = current(for: 0xE000) else { return false }
        let mode = UInt16(truncatingIfNeeded: raw)
        return mode == 0x0301 || mode == 0x0302
    }

    // Formatting below mirrors the working ESP32 controller. The PTP raw
    // values remain authoritative for writes; this only converts Sony's raw
    // representation into the same human-readable value shown by the camera.
    func displayValue(for property: UInt16, value: Int64) -> String {
        switch property {
        case 0xD21E, 0xD022, 0xD023:
            return String(value)

        case 0xD020:
            switch UInt8(truncatingIfNeeded: value) {
            case 0x01: return "HIGH"
            case 0x02: return "LOW"
            default: return String(format: "0x%02X", UInt8(truncatingIfNeeded: value))
            }

        case 0xD20D:
            let raw = UInt32(truncatingIfNeeded: value)
            let numerator = UInt16(raw >> 16)
            let denominator = UInt16(raw & 0xFFFF)
            if numerator != 0 && denominator != 0 {
                return "\(numerator)/\(denominator)"
            }
            return String(format: "0x%08X", raw)

        case 0x5007:
            return String(format: "F%.1f", Double(value) / 100.0)

        case 0x500E:
            switch UInt32(truncatingIfNeeded: value) {
            case 0x00000001: return "M"
            case 0x00010002: return "P"
            case 0x00020003: return "A"
            case 0x00030004: return "S"
            case 0x00048000: return "AUTO"
            case 0x00048001: return "AUTO+"
            default: return "--"
            }

        case 0x5005:
            switch UInt16(truncatingIfNeeded: value) {
            case 0x0002: return "AWB"
            case 0x0004: return "DAY"
            case 0x0006: return "TUNG"
            case 0x0007: return "FLASH"
            case 0x8010: return "CLOUD"
            case 0x8011: return "SHADE"
            case 0x8012: return "KELVIN"
            case 0x8020: return "CUST1"
            case 0x8021: return "CUST2"
            case 0x8022: return "CUST3"
            default: return String(format: "WB 0x%04X", UInt16(truncatingIfNeeded: value))
            }

        case 0xD20F:
            return "\(UInt16(truncatingIfNeeded: value))K"

        case 0xD210:
            return formatWBTint(UInt8(truncatingIfNeeded: value), positive: "G", negative: "M")

        case 0xD21C:
            return formatWBTint(UInt8(truncatingIfNeeded: value), positive: "A", negative: "B")

        case 0xE000:
            switch UInt16(truncatingIfNeeded: value) {
            case 0x0301: return "Cine EI"
            case 0x0302: return "Cine EI Quick"
            case 0x0501: return "Flexible ISO"
            default: return String(format: "LOG 0x%04X", UInt16(truncatingIfNeeded: value))
            }

        case 0x500A:
            switch UInt16(truncatingIfNeeded: value) {
            case 0x0001: return "MF"
            case 0x0002: return "AF-S"
            case 0x8004: return "AF-C"
            case 0x8005: return "AF-A"
            case 0x8006: return "DMF"
            default: return "--"
            }

        case 0xD22C:
            switch UInt16(truncatingIfNeeded: value) {
            case 0x0001: return "WIDE"
            case 0x0002: return "ZONE"
            case 0x0003: return "CENTER"
            case 0x0101: return "FLEX SPOT S"
            case 0x0102: return "FLEX SPOT M"
            case 0x0103: return "FLEX SPOT L"
            case 0x0104: return "EXPAND SPOT"
            case 0x0201: return "LOCK WIDE"
            case 0x0202: return "LOCK ZONE"
            case 0x0203: return "LOCK CENTER"
            case 0x0204: return "LOCK SPOT S"
            case 0x0205: return "LOCK SPOT M"
            case 0x0206: return "LOCK SPOT L"
            case 0x0207: return "LOCK EXPAND"
            default: return "FOCUS AREA"
            }

        case 0xD213:
            switch UInt8(truncatingIfNeeded: value) {
            case 0x01: return "UNLOCK"
            case 0x02: return "AF-S LOCKED"
            case 0x03: return "AF-S LOW CONTRAST"
            case 0x05: return "AF-C TRACKING"
            case 0x06: return "AF-C FOCUSED"
            case 0x07: return "AF-C LOW CONTRAST"
            default: return "AF STATUS --"
            }

        case 0xD241:
            switch UInt8(truncatingIfNeeded: value) {
            case 0x08: return "XAVC S 4K"
            case 0x09: return "XAVC S HD"
            case 0x0B: return "XAVC HS 4K"
            case 0x0C: return "XAVC S-L 4K"
            case 0x0D: return "XAVC S-L HD"
            case 0x0E: return "XAVC S-I 4K"
            case 0x0F: return "XAVC S-I HD"
            case 0x14: return "XAVC S-I DCI 4K"
            default: return String(format: "FORMAT 0x%02X", UInt8(truncatingIfNeeded: value))
            }

        case 0xD286:
            switch UInt8(truncatingIfNeeded: value) {
            case 0x01: return "120p"
            case 0x02: return "100p"
            case 0x03: return "60p"
            case 0x04: return "50p"
            case 0x05: return "30p"
            case 0x06: return "25p"
            case 0x07: return "24p"
            case 0x08: return "23.98p"
            case 0x09: return "29.97p"
            case 0x0A: return "59.94p"
            case 0x16: return "24.00p"
            case 0x17: return "119.88p"
            default: return String(format: "FPS 0x%02X", UInt8(truncatingIfNeeded: value))
            }

        case 0xD242:
            return movieRecordSetting(UInt16(truncatingIfNeeded: value))

        case 0xD109:
            return String(format: "PROXY 0x%04X", UInt16(truncatingIfNeeded: value))

        case 0xD0D0:
            return String(format: "S&Q FPS 0x%02X", UInt8(truncatingIfNeeded: value))

        case 0xD0D1:
            return String(format: "S&Q REC 0x%04X", UInt16(truncatingIfNeeded: value))

        case 0xD24A, 0xD258:
            let seconds = UInt32(truncatingIfNeeded: value)
            if seconds == UInt32.max { return "--:--:--" }
            return formatDuration(seconds)

        default:
            return String(value)
        }
    }

    func displayCurrent(for property: UInt16) -> String {
        guard let value = current(for: property) else { return "—" }
        return displayValue(for: property, value: value)
    }

    private func formatWBTint(_ raw: UInt8, positive: String, negative: String) -> String {
        let difference = Int(raw) - 0xC0
        guard difference != 0 else { return "0.00" }

        let amount = Double(abs(difference)) * 0.25
        return "\(difference > 0 ? positive : negative)\(String(format: "%.2f", amount))"
    }

    private func formatDuration(_ seconds: UInt32) -> String {
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let remaining = seconds % 60
        return String(format: "%02u:%02u:%02u", hours, minutes, remaining)
    }

    private func movieRecordSetting(_ value: UInt16) -> String {
        switch value {
        case 0x0026: return "600M 422 10b"
        case 0x0027: return "500M 422 10b"
        case 0x0028: return "400M 420 10b"
        case 0x0029: return "300M 422 10b"
        case 0x002A: return "280M 422 10b"
        case 0x002B: return "250M 422 10b"
        case 0x002C: return "240M 422 10b"
        case 0x002D: return "222M 422 10b"
        case 0x002E: return "200M 422 10b"
        case 0x002F: return "200M 420 10b"
        case 0x0030: return "200M 420 8b"
        case 0x0031: return "185M 422 10b"
        case 0x0032: return "150M 420 10b"
        case 0x0033: return "150M 420 8b"
        case 0x0034: return "140M 422 10b"
        case 0x0035: return "111M 422 10b"
        case 0x0036: return "100M 422 10b"
        case 0x0037: return "100M 420 10b"
        case 0x0038: return "100M 420 8b"
        case 0x0039: return "93M 422 10b"
        case 0x003A: return "89M 422 10b"
        case 0x003B: return "75M 420 10b"
        case 0x003C: return "60M 420 8b"
        case 0x003D: return "50M 422 10b"
        case 0x003E: return "50M 420 10b"
        case 0x003F: return "50M 420 8b"
        case 0x0040: return "45M 420 10b"
        case 0x0041: return "30M 420 10b"
        case 0x0042: return "25M 420 8b"
        case 0x0043: return "16M 420 8b"
        case 0x0044: return "520M 422 10b"
        case 0x0045: return "260M 422 10b"
        default:
            return String(format: "REC 0x%04X", value)
        }
    }

    func set(_ property: UInt16, to value: Int64, completion: @escaping (String) -> Void) {
        bridge.setProperty(property, value: value) { _, message in completion(message) }
    }

    func control(_ code: UInt16, value: Int64, completion: @escaping (String) -> Void) {
        bridge.control(code, value: value) { _, message in completion(message) }
    }

    func record(_ value: Bool, completion: @escaping (String) -> Void) {
        bridge.setRecording(value) { _, message in completion(message) }
    }

    private func startPolling() {
        statePoller?.invalidate()

        statePoller = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self, self.connected, !self.refreshInFlight else { return }
            self.refreshInFlight = true
            self.bridge.refresh { [weak self] _, _ in
                self?.refreshInFlight = false
            }
        }
    }
}
