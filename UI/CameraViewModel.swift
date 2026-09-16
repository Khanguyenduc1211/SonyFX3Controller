import Foundation
import UIKit

final class CameraViewModel {
    static let shared = CameraViewModel()
    private let bridge = SonyCameraBridge()
    private(set) var profile = CameraProfileStore.load()
    // Keep the Objective-C bridge payload as NSDictionary.  This avoids Swift
    // generic-bridging differences between Xcode releases.
    private(set) var properties: [UInt16: NSDictionary] = [:]
    private(set) var connected = false
    private(set) var recordState: UInt32 = UInt32.max
    var recordingStartedAt: Date?
    var onChange: (() -> Void)?
    private var statePoller: Timer?

    private init() {
        NotificationCenter.default.addObserver(forName: Notification.Name("SonyCameraBridgeStateDidChange"), object: bridge, queue: .main) { [weak self] note in
            guard let self else { return }
            let bridged = self.bridge.stateSnapshot()
            var converted: [UInt16: NSDictionary] = [:]
            for (key, value) in bridged { converted[key.uint16Value] = value as NSDictionary }
            self.properties = converted
            let previous = self.recordState; self.recordState = note.userInfo?["recordState"] as? UInt32 ?? UInt32.max
            if previous == 0 && self.recordState == 1 { self.recordingStartedAt = Date() }
            if self.recordState != 1 { self.recordingStartedAt = nil }
            self.onChange?()
        }
    }
    func connect(host: String, username: String, password: String, trust: Bool = false, done: @escaping (String, String?) -> Void) {
        let old = profile; profile.host = host; profile.username = username
        if old.host != host || old.username != username { profile.fingerprint = "" }
        CameraProfileStore.save(profile); CameraProfileStore.savePassword(password, for: profile)
        bridge.connectHost(host, username: username, password: password, trustedFingerprint: trust ? profile.fingerprint : profile.fingerprint) { [weak self] ok, needsTrust, message, fingerprint in
            guard let self else { return }
            if ok { self.connected = true; self.startPolling(); self.onChange?(); done(message, nil) }
            else if needsTrust { done(message, fingerprint) }
            else { done(message, nil) }
        }
    }
    func trustAndConnect(host: String, username: String, password: String, fingerprint: String, done: @escaping (String) -> Void) {
        profile = CameraProfile(host: host, username: username, fingerprint: fingerprint); CameraProfileStore.save(profile); CameraProfileStore.savePassword(password, for: profile)
        bridge.connectHost(host, username: username, password: password, trustedFingerprint: fingerprint) { [weak self] ok, _, message, _ in self?.connected = ok; if ok { self?.startPolling() }; self?.onChange?(); done(message) }
    }
    func disconnect() { statePoller?.invalidate(); statePoller = nil; bridge.disconnect(); connected = false; properties = [:]; recordState = UInt32.max; onChange?() }
    func refresh(_ done: @escaping (String) -> Void) { bridge.refresh { _, message in done(message) } }
    func values(for property: UInt16) -> [Int64] {
        guard let propertyState = properties[property] else { return [] }

        // Sony PTP3 0x9209 enum form contains two UINT16-counted lists.
        // The working ESP32 controller skips the first list and uses the
        // SECOND list as the supported/selectable values.
        let supported = propertyState["getSetValues"] as? [NSNumber] ?? []
        if !supported.isEmpty {
            return supported.map { $0.int64Value }
        }

        // Fallback only for cameras/firmware that expose a single useful list.
        return (propertyState["setValues"] as? [NSNumber] ?? []).map { $0.int64Value }
    }
    func current(for property: UInt16) -> Int64? { (properties[property]?["current"] as? NSNumber)?.int64Value }
    func writable(_ property: UInt16) -> Bool { (properties[property]?["writable"] as? NSNumber)?.boolValue == true && (properties[property]?["enabled"] as? NSNumber)?.boolValue == true }
    func set(_ property: UInt16, to value: Int64, completion: @escaping (String) -> Void) { bridge.setProperty(property, value: value) { _, message in completion(message) } }
    func control(_ code: UInt16, value: Int64, completion: @escaping (String) -> Void) { bridge.control(code, value: value) { _, message in completion(message) } }
    func record(_ value: Bool, completion: @escaping (String) -> Void) { bridge.setRecording(value) { _, message in completion(message) } }
    private func startPolling() {
        statePoller?.invalidate()
        // The event tunnel exists for Sony PTP/IP events; periodic 0x9209 also
        // covers firmware that does not emit every property-change event.
        statePoller = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in self?.bridge.refresh { _, _ in } }
    }
}
