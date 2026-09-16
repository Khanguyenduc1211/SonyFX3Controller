import Foundation
import Security

struct CameraProfile: Codable, Equatable {
    var host = "192.168.5.46"
    var username = ""
    var fingerprint = ""
    var identityKey: String { "\(host)|\(username)" }
}

enum CameraProfileStore {
    private static let profileKey = "camera.profile"
    static func load() -> CameraProfile { (try? JSONDecoder().decode(CameraProfile.self, from: UserDefaults.standard.data(forKey: profileKey) ?? Data())) ?? CameraProfile() }
    static func save(_ profile: CameraProfile) { UserDefaults.standard.set(try? JSONEncoder().encode(profile), forKey: profileKey) }
    static func password(for profile: CameraProfile) -> String {
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: "SonyFX3Controller", kSecAttrAccount: profile.identityKey, kSecReturnData: true]
        var result: CFTypeRef?; guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
    static func savePassword(_ password: String, for profile: CameraProfile) {
        let base: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: "SonyFX3Controller", kSecAttrAccount: profile.identityKey]
        SecItemDelete(base as CFDictionary)
        var record = base; record[kSecValueData] = password.data(using: .utf8)!; SecItemAdd(record as CFDictionary, nil)
    }
}
