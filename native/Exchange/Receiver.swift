import AppKit
import AuthenticationServices
import CryptoKit
import SwiftUI

func base32(_ data: Data) -> String {
  let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
  var bits = 0, buffer = 0, output = ""
  for byte in data {
    buffer = (buffer << 8) | Int(byte)
    bits += 8
    while bits >= 5 {
      bits -= 5
      output.append(alphabet[(buffer >> bits) & 31])
    }
    buffer &= (1 << bits) - 1
  }
  if bits > 0 { output.append(alphabet[buffer << (5 - bits)]) }
  return output
}

@MainActor
func receive(_ data: ASExportedCredentialData, store: Storage = KeychainStorage()) -> String {
  var added = 0, updated = 0, skipped = 0, failed = 0
  for account in data.accounts {
    for item in account.items {
      do {
        guard !item.id.isEmpty, !account.id.isEmpty else { throw invalid() }
        let source = [data.exporterRelyingPartyIdentifier, account.id.base64EncodedString(), item.id.base64EncodedString()]
        let importID = SHA256.hash(data: try encoder.encode(source)).map { String(format: "%02x", $0) }.joined()
        try { () throws -> Void in
          let old = try store.all().first { $0.importID == importID }
          if old?.deletedAt != nil { skipped += 1; return }
          var record = old ?? Record(id: UUID().uuidString, revision: UUID().uuidString, kind: "password",
            name: item.title, provider: "", account: "", environment: "", tags: item.tags, notes: "",
            values: [:], updatedAt: now(), importID: importID)
          record.name = item.title
          record.tags = item.tags
          record.values = [:]
          record.passkeys = nil
          var supported = false
          var seenBasic = false, seenOTP = false
          for credential in item.credentials {
            switch credential {
            case .basicAuthentication(let basic):
              guard !seenBasic else { throw invalid() }
              seenBasic = true
              if let name = basic.userName?.value { record.values["username"] = name }
              if let password = basic.password?.value, !password.isEmpty { record.values["password"] = password; supported = true }
            case .totp(let otp):
              guard !seenOTP else { throw invalid() }
              seenOTP = true
              let uri = "otpauth://totp/account?secret=\(base32(otp.secret))&algorithm=\(otp.algorithm.rawValue)&digits=\(otp.digits)&period=\(otp.period)"
              _ = try currentCode(uri)
              record.values["totp"] = uri
              supported = true
            case .passkey(let key):
              _ = try P256.Signing.PrivateKey(derRepresentation: key.key)
              guard !key.credentialID.isEmpty, !key.userHandle.isEmpty, !key.relyingPartyIdentifier.isEmpty else { throw invalid() }
              let saved = StoredPasskey(credentialID: key.credentialID, rp: key.relyingPartyIdentifier,
                username: key.userName, handle: key.userHandle, key: key.key)
              var keys = record.passkeys ?? []
              if let index = keys.firstIndex(where: { $0.credentialID == saved.credentialID && $0.rp == saved.rp }) {
                keys[index] = saved
              } else { keys.append(saved) }
              record.passkeys = keys
              supported = true
            default: continue
            }
          }
          guard supported else { skipped += 1; return }
          if let url = item.scope?.urls.first(where: { webOrigin($0.absoluteString) != nil }) {
            record.values["url"] = url.absoluteString
          }
          guard try encoder.encode(record).count <= 65536 else { throw invalid() }
          if let old {
            guard old.values != record.values || old.passkeys != record.passkeys ||
              old.name != record.name || old.tags != record.tags else { skipped += 1; return }
            let alert = NSAlert()
            alert.messageText = "更新网站账号“\(old.name)”？"
            alert.addButton(withTitle: "跳过")
            alert.addButton(withTitle: "更新")
            guard alert.runModal() == .alertSecondButtonReturn else { skipped += 1; return }
            record.revision = UUID().uuidString
            record.updatedAt = now()
            try withStoreLock {
              let latest = try store.read(old.id)
              guard latest.revision == old.revision, latest.deletedAt == nil else { throw invalid() }
              try store.replace(record)
            }
            updated += 1
          } else {
            try withStoreLock {
              guard !(try store.all()).contains(where: { $0.importID == importID }) else { throw invalid() }
              try store.insert(record)
            }
            added += 1
          }
        }()
      } catch { failed += 1 }
    }
  }
  return "新增 \(added)，更新 \(updated)，跳过 \(skipped)，失败 \(failed)"
}

#if !TESTING
@main
@MainActor
final class Receiver: NSObject, NSApplicationDelegate {
  private var window: NSWindow?
  private let label = NSTextField(wrappingLabelWithString: "")
  private var observer: NSObjectProtocol?
  static func main() {
    let app = NSApplication.shared
    let delegate = Receiver()
    app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
  }
  private func note(_ value: String) {
    UserDefaults.standard.set(value, forKey: "lastExchangeStatus")
    label.stringValue = value
  }
  func applicationDidFinishLaunching(_ notification: Notification) {
    let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 470, height: 140),
      styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
    w.title = "AKSK Manager"
    w.isReleasedWhenClosed = false
    label.frame = NSRect(x: 24, y: 30, width: 422, height: 75)
    label.stringValue = UserDefaults.standard.string(forKey: "lastExchangeStatus") ??
      "在苹果「密码」中选择项目，然后选取「导出至 App」。"
    w.contentView?.addSubview(label)
    window = w
    w.center()
    w.makeKeyAndOrderFront(nil)
    Task { try? await refreshIdentities() }
    observer = DistributedNotificationCenter.default().addObserver(forName:
      Notification.Name("com.boreas.aksk-manager.changed"), object: nil, queue: .main) { _ in
      Task { try? await refreshIdentities() }
    }
  }
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    window?.makeKeyAndOrderFront(nil)
    return true
  }
  func application(_ application: NSApplication, willContinueUserActivityWithType type: String) -> Bool {
    note("系统正在交接导入请求…")
    return true
  }
  func application(_ application: NSApplication, didFailToContinueUserActivityWithType type: String, error: Error) {
    note("系统未能交付导入请求（错误码 \((error as NSError).code)）。")
  }
  func application(_ application: NSApplication, continue activity: NSUserActivity,
    restorationHandler: @escaping ([any NSUserActivityRestoring]) -> Void) -> Bool {
    guard let token = activity.userInfo?[ASCredentialImportToken] as? UUID else {
      note("已收到系统活动，但未收到有效的凭据导入令牌。")
      return false
    }
    note("已收到系统请求，正在接收所选项目…")
    Task { @MainActor in
      do {
        let data = try await ASCredentialImportManager().importCredentials(token: token)
        let result = receive(data)
        note(result)
        do { try await refreshIdentities() } catch { note(result + "（自动填充索引更新失败）") }
      } catch { note("系统凭据交换失败（错误码 \((error as NSError).code)）。") }
    }
    return true
  }
}
#endif
