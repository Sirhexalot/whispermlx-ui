import SwiftUI
import Security

enum TokenStore {
    static let service = "local.whispermlx.ui"
    static let account = "huggingface-token"
    static func load() -> String {
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account, kSecReturnData: true]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
    static func save(_ token: String) {
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
        SecItemDelete(query as CFDictionary)
        let value: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account, kSecValueData: Data(token.utf8)]
        SecItemAdd(value as CFDictionary, nil)
    }
}

struct SettingsView: View {
    @State private var token = TokenStore.load()
    @State private var saved = false

    var body: some View {
        TabView {
            Form {
                Picker("settings.defaultModel", selection: .constant("large-v3")) {
                    Text("model.largeV3").tag("large-v3")
                    Text("model.turbo").tag("large-v3-turbo")
                    Text("model.small").tag("small")
                }
                Text("settings.models.description")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding().tabItem { Label("settings.models.tab", systemImage: "cpu") }
            Form {
                SecureField("Hugging-Face-Token", text: $token)
                Text("settings.token.description")
                    .font(.caption).foregroundStyle(.secondary)
                HStack { Button("settings.token.save") { TokenStore.save(token); saved = true }; if saved { Text("settings.token.saved").foregroundStyle(.green) } }
            }.padding().tabItem { Label("diarization.label", systemImage: "person.2") }
        }.frame(width: 520, height: 260)
    }
}
