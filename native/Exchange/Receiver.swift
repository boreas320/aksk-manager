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

enum ImportChoice { case skip, add, update(String) }

func possibleLogins(_ incoming: Record, in records: [Record]) -> [Record] {
  guard let user = incoming.values["username"], !user.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        (incoming.passkeys ?? []).isEmpty else { return [] }
  let origins = incoming.websiteOrigins
  return records.filter { $0.kind == "password" && $0.deletedAt == nil &&
    $0.values["username"] == user && !$0.websiteOrigins.isDisjoint(with: origins) }
    .sorted { ($0.name, $0.id) < ($1.name, $1.id) }
}

@MainActor
private func chooseLogin(_ incoming: Record, _ matches: [Record]) -> ImportChoice {
  let alert = NSAlert()
  alert.messageText = "发现可能重复的网站账号"
  alert.informativeText = "导入：\(incoming.name) · \(incoming.values["username"] ?? "")\n\(incoming.websiteOrigins.sorted().joined(separator: "、"))\n请选择要更新的已有账号，或单独保存。"
  let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 420, height: 28), pullsDown: false)
  for r in matches {
    let title = "\(r.name) · \(r.websiteOrigins.sorted().joined(separator: "、")) · \(r.updatedAt) · \(r.id.suffix(6))"
    picker.addItem(withTitle: title)
  }
  alert.accessoryView = picker
  alert.addButton(withTitle: "跳过")
  alert.addButton(withTitle: "更新已有")
  alert.addButton(withTitle: "另存为新账号")
  switch alert.runModal() {
  case .alertSecondButtonReturn where matches.indices.contains(picker.indexOfSelectedItem):
    return .update(matches[picker.indexOfSelectedItem].id)
  case .alertThirdButtonReturn: return .add
  default: return .skip
  }
}

@MainActor
func receive(_ data: ASExportedCredentialData, store: Storage = KeychainStorage(),
             choose: ((Record, [Record]) -> ImportChoice)? = nil) -> String {
  var added = 0, updated = 0, skipped = 0, failed = 0, ambiguous = 0
  for account in data.accounts {
    for item in account.items {
      do {
        guard !item.id.isEmpty, !account.id.isEmpty else { throw invalid() }
        let source = [data.exporterRelyingPartyIdentifier, account.id.base64EncodedString(), item.id.base64EncodedString()]
        let importID = SHA256.hash(data: try encoder.encode(source)).map { String(format: "%02x", $0) }.joined()
        try { () throws -> Void in
          // Apple exchange identifiers can change between exports. A passkey's
          // credential ID is scoped to its relying party, not the display name.
          let identities: [(String, Data)] = item.credentials.compactMap {
            guard case .passkey(let k) = $0, !k.credentialID.isEmpty,
                  !k.relyingPartyIdentifier.isEmpty else { return nil }
            return (k.relyingPartyIdentifier.lowercased(), k.credentialID)
          }
          func candidates() throws -> [Record] {
            let records = try store.all()
            let exact = records.filter { $0.importID == importID }
            if !exact.isEmpty { return exact }
            let matched = records.filter { record in
              record.kind == "password" && (record.passkeys ?? []).contains { key in
                identities.contains { $0.0 == key.rp.lowercased() && $0.1 == key.credentialID }
              }
            }
            let active = matched.filter { $0.deletedAt == nil }
            return active.isEmpty ? Array(matched.prefix(1)) : active
          }
          let matches = try candidates()
          guard matches.count <= 1 else { skipped += 1; ambiguous += 1; return }
          let old = matches.first
          if old?.deletedAt != nil { skipped += 1; return }
          var record = old ?? Record(id: UUID().uuidString, revision: UUID().uuidString, kind: "password",
            name: item.title, provider: "", account: "", environment: "", tags: item.tags, notes: "",
            values: [:], updatedAt: now(), importID: importID)
          record.name = item.title
          record.tags = item.tags
          record.values = [:]
          record.passkeys = nil
          var supported = false
          var otpUsername: String?
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
              otpUsername = otp.userName
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
          if record.values["username"] == nil { record.values["username"] = otpUsername }
          guard supported else { skipped += 1; return }
          var seen = Set<String>()
          let urls = (item.scope?.urls ?? []).map(\.absoluteString).filter {
            webOrigin($0) != nil && seen.insert($0).inserted
          }
          record.values["url"] = urls.first
          record.additionalURLs = urls.count > 1 ? Array(urls.dropFirst()) : nil
          guard try encoder.encode(record).count <= 65536 else { throw invalid() }
          var reviewed: Set<String> = []
          if old == nil && identities.isEmpty {
            let possible = possibleLogins(record, in: try store.all())
            reviewed = Set(possible.map { $0.revision + ":" + $0.id })
            if !possible.isEmpty {
              let decision = choose?(record, possible) ?? chooseLogin(record, possible)
              switch decision {
              case .skip: skipped += 1; return
              case .add: break
              case .update(let id):
                guard var target = possible.first(where: { $0.id == id }) else { throw invalid() }
                try withStoreLock {
                  guard try candidates().isEmpty,
                        let current = possibleLogins(record, in: try store.all()).first(where: { $0.id == id }),
                        current.revision == target.revision else { throw invalid() }
                  // Retain local metadata and credentials absent from this export.
                  target.name = record.name
                  target.tags = record.tags
                  target.values.merge(record.values) { _, new in new }
                  target.additionalURLs = record.additionalURLs
                  target.updatedAt = now()
                  target.revision = UUID().uuidString
                  guard try encoder.encode(target).count <= 65536 else { throw invalid() }
                  try store.replace(target)
                }
                updated += 1; return
              }
            }
          }
          if let old {
            guard old.websiteURLs != record.websiteURLs || old.values != record.values || old.passkeys != record.passkeys ||
              old.name != record.name || old.tags != record.tags else { skipped += 1; return }
            let alert = NSAlert()
            alert.messageText = "更新网站账号“\(old.name)”？"
            alert.addButton(withTitle: "跳过")
            alert.addButton(withTitle: "更新")
            guard alert.runModal() == .alertSecondButtonReturn else { skipped += 1; return }
            record.revision = UUID().uuidString
            record.updatedAt = now()
            try withStoreLock {
              let current = try candidates()
              guard current.count == 1, current[0].id == old.id else { throw invalid() }
              let latest = current[0]
              guard latest.revision == old.revision, latest.deletedAt == nil else { throw invalid() }
              try store.replace(record)
            }
            updated += 1
          } else {
            try withStoreLock {
              guard try candidates().isEmpty else { throw invalid() }
              if identities.isEmpty {
                let latest = possibleLogins(record, in: try store.all())
                guard Set(latest.map { $0.revision + ":" + $0.id }) == reviewed else { throw invalid() }
              }
              try store.insert(record)
            }
            added += 1
          }
        }()
      } catch { failed += 1 }
    }
  }
  return "新增 \(added)，更新 \(updated)，跳过 \(skipped)，失败 \(failed)" +
    (ambiguous > 0 ? "（其中 \(ambiguous) 项匹配多个已有账号，已保留原记录，未新增）" : "")
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
    if let url = Bundle.main.url(forResource: "AKSK", withExtension: "icns"),
       let image = NSImage(contentsOf: url) {
      NSApp.applicationIconImage = image
      NSApp.dockTile.display()
    }
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
