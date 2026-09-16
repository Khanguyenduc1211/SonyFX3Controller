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
