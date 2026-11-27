import Darwin
import Foundation
import Security
import CryptoKit

func webOrigin(_ raw: String) -> String? {
  guard let parts = URLComponents(string: raw), parts.scheme?.lowercased() == "https",
    parts.user == nil, parts.password == nil, let host = parts.host?.lowercased(), !host.isEmpty
  else { return nil }
  return "https://" + host + (parts.port.flatMap { $0 == 443 ? nil : ":\($0)" } ?? "")
}

func codeWindow(_ input: String, at time: TimeInterval = Date().timeIntervalSince1970) throws -> (code: String, expires: Double) {
  var seed = input, period = 30, digits = 6, algorithm = "SHA1"
  if input.lowercased().hasPrefix("otpauth:") {
    guard let parts = URLComponents(string: input), parts.host?.lowercased() == "totp" else { throw invalid() }
    var params = [String: String]()
    for item in parts.queryItems ?? [] {
      guard params[item.name] == nil, let value = item.value else { throw invalid() }
      params[item.name] = value
    }
    seed = params["secret"] ?? ""
    period = Int(params["period"] ?? "30") ?? 0
    digits = Int(params["digits"] ?? "6") ?? 0
    algorithm = (params["algorithm"] ?? "SHA1").uppercased()
  }
  guard (1...86400).contains(period), [6, 8].contains(digits), time >= 0 else { throw invalid() }
  let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567".utf8)
  var key = Data(), accumulator = 0, bits = 0
  let normalized = seed.uppercased().filter { !$0.isWhitespace }
  let encoded = normalized.prefix(while: { $0 != "=" })
  guard normalized.dropFirst(encoded.count).allSatisfy({ $0 == "=" }),
    [0,2,4,5,7].contains(encoded.count % 8) else { throw invalid() }
  for byte in encoded.utf8 {
    guard let index = alphabet.firstIndex(of: byte) else { throw invalid() }
    accumulator = (accumulator << 5) | index
    bits += 5
    if bits >= 8 {
      bits -= 8
      key.append(UInt8(accumulator >> bits))
      accumulator &= (1 << bits) - 1
    }
  }
  guard !key.isEmpty, accumulator == 0 else { throw invalid() }
  var counter = UInt64(time / Double(period)).bigEndian
  let message = withUnsafeBytes(of: &counter) { Data($0) }
  let secret = SymmetricKey(data: key)
  let digest: [UInt8]
  switch algorithm {
  case "SHA1": digest = Array(HMAC<Insecure.SHA1>.authenticationCode(for: message, using: secret))
  case "SHA256": digest = Array(HMAC<SHA256>.authenticationCode(for: message, using: secret))
  case "SHA512": digest = Array(HMAC<SHA512>.authenticationCode(for: message, using: secret))
  default: throw invalid()
  }
  let offset = Int(digest[digest.count - 1] & 15)
  let number = digest[offset..<offset+4].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) } & 0x7fffffff
  let code = String(format: "%0*u", digits, number % (digits == 8 ? 100000000 : 1000000))
  return (code, (floor(time / Double(period)) + 1) * Double(period))
}
func currentCode(_ input: String, at time: TimeInterval = Date().timeIntervalSince1970) throws -> String {
  try codeWindow(input, at: time).code
}

func browserRequest(_ request: [String: Any], store: Storage) throws -> Any {
  let origin = try required(request, "origin")
  guard webOrigin(origin) == origin else { throw invalid() }
  func matches(_ record: Record) -> Bool {
    record.kind == "password" && record.deletedAt == nil && record.websiteOrigins.contains(origin)
  }
  switch try required(request, "action") {
  case "accounts":
    return try store.all().filter(matches).map { ["id": $0.id, "name": $0.name, "revision": $0.revision,
      "fields": $0.metadata["fields"] ?? []] }
  case "fill":
    let record = try store.read(required(request, "id"))
    guard matches(record), record.revision == (request["revision"] as? String) else { throw invalid() }
    let field = try required(request, "field")
    if field == "otp_code", let seed = record.values["totp"] { return try currentCode(seed) }
    guard ["username", "password"].contains(field), let value = record.values[field] else { throw invalid() }
    return value
  default: throw invalid()
  }
}

struct Failure: Error {
  let code: String
  let message: String
  var json: [String: Any] { ["code": code, "message": message] }
}
func invalid(_ s: String = "输入无效，请检查字段。") -> Failure { Failure(code: "INVALID_INPUT", message: s) }
func required(_ p: [String: Any], _ key: String) throws -> String {
  guard let s = p[key] as? String, !s.isEmpty, !s.contains("\0") else { throw invalid() }
  return s
}
func keychainFailure(_ s: OSStatus) -> Failure {
  switch s {
  case errSecItemNotFound: return Failure(code: "NOT_FOUND", message: "条目不存在，可能已在其他设备删除。")
  case errSecMissingEntitlement:
    return Failure(code: "MISSING_ENTITLEMENT", message: "本地组件缺少有效的钥匙串签名或配置描述文件。")
  case errSecInteractionNotAllowed, errSecAuthFailed:
    return Failure(code: "KEYCHAIN_LOCKED", message: "系统钥匙串不可访问，请解锁 Mac 并检查系统授权。")
  case errSecUserCanceled: return Failure(code: "ACCESS_DENIED", message: "系统钥匙串访问未获授权。")
  case errSecDuplicateItem: return Failure(code: "CONFLICT", message: "条目已存在，请刷新后重试。")
  default: return Failure(code: "KEYCHAIN_ERROR", message: "钥匙串操作失败（系统状态 \(s)）。")
  }
}
let encoder = JSONEncoder()
let decoder = JSONDecoder()
func now() -> String { ISO8601DateFormatter().string(from: Date()) }
struct StoredPasskey: Codable, Equatable {
  var credentialID: Data
  var rp: String
  var username: String
  var handle: Data
  var key: Data
  // Called by the provider only after local user verification.
  func assertion(clientHash: Data) throws -> (auth: Data, signature: Data) {
    guard clientHash.count == 32 else { throw invalid() }
    var auth = Data(SHA256.hash(data: Data(rp.utf8)))
    auth.append(contentsOf: [0x1d, 0, 0, 0, 0])
    let signer = try P256.Signing.PrivateKey(derRepresentation: key)
    return (auth, try signer.signature(for: auth + clientHash).derRepresentation)
  }
}
struct Record: Codable {
  var id: String
  var revision: String
  var kind: String
  var name: String
  var provider: String
  var account: String
  var environment: String
  var tags: [String]
  var notes: String
  var expiresAt: String?
  var values: [String: String]
  var updatedAt: String
  var deletedAt: String?
  var importID: String?
  var passkeys: [StoredPasskey]?
  var additionalURLs: [String]?
  var websiteURLs: [String] { [values["url"]].compactMap { $0 } + (additionalURLs ?? []) }
  var websiteOrigins: Set<String> { Set(websiteURLs.compactMap(webOrigin)) }
  var accessibleFields: [String] {
    kind == "password" ? values.keys.filter { ["username", "password", "url"].contains($0) } : Array(values.keys)
  }
  func bindable(_ field: String) -> Bool {
    kind != "password" || ["username", "password"].contains(field)
  }
  func commandValue(for field: String) throws -> String? {
    if kind == "password", field == "otp_code", let seed = values["totp"] {
      return try currentCode(seed)
    }
    return bindable(field) ? values[field] : nil
  }
  func matches(_ query: String, includeValues: Bool) -> Bool {
    func normalize(_ text: String) -> String {
      text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                   locale: Locale(identifier: "en_US_POSIX"))
    }
    let terms = normalize(query).split(whereSeparator: { $0.isWhitespace })
    if terms.isEmpty { return true }
    let kinds = ["password": "网站账号 普通密码", "aksk": "云访问密钥 AK/SK AK SK", "token": "API Token 令牌",
                 "database": "数据库连接 database"]
    let labels = ["access_key": "Access Key", "secret_key": "Secret Key",
                  "session_token": "Session Token", "token": "API Token",
                  "engine": "数据库类型", "host": "主机", "port": "端口",
                  "database": "数据库名", "username": "用户名", "password": "密码",
                  "ssl_mode": "TLS 模式 SSL"]
    var text = [id, revision, kind, kinds[kind] ?? kind, name, provider, account,
                environment, notes, updatedAt, deletedAt ?? "", expiresAt ?? ""] + tags
    for field in values.keys { text += [field, labels[field] ?? field] }
    // App-only matching stays in the helper; results still contain metadata only.
    if includeValues {
      text.append(contentsOf: accessibleFields.compactMap { values[$0] })
      text += additionalURLs ?? []
      for passkey in passkeys ?? [] { text += [passkey.username, passkey.rp] }
    }
    let haystack = normalize(text.joined(separator: " "))
    return terms.allSatisfy { haystack.contains($0) }
  }
  var metadata: [String: Any] {
    [
      "id": id, "revision": revision, "kind": kind, "name": name, "provider": provider,
      "account": account, "environment": environment, "tags": tags, "notes": notes,
      "fields": (accessibleFields + (kind == "password" && values["totp"] != nil ? ["otp_code"] : [])).sorted(), "updatedAt": updatedAt,
      "passkeyCount": passkeys?.count ?? 0,
      "expiresAt": expiresAt as Any? ?? NSNull(), "deletedAt": deletedAt as Any? ?? NSNull(),
    ]
  }
}
protocol Storage {
  func all() throws -> [Record]
  func read(_ id: String) throws -> Record
  func insert(_ r: Record) throws
  func replace(_ r: Record) throws
  func remove(_ id: String) throws
}
final class KeychainStorage: Storage {
  let service = "com.boreas.aksk-manager.records.v1"
  let accessGroup = Bundle.main.object(forInfoDictionaryKey: "AKSKAccessGroup") as? String
  func query(_ id: String? = nil) throws -> [String: Any] {
    guard let accessGroup, !accessGroup.contains("$("), !accessGroup.isEmpty else {
      throw Failure(code: "MISSING_ENTITLEMENT", message: "请通过已签名的 AKSKHelper.app 启动本地组件。")
    }
    var q: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service, kSecAttrAccessGroup as String: accessGroup,
      kSecAttrSynchronizable as String: true, kSecUseDataProtectionKeychain as String: true,
    ]
    if let id { q[kSecAttrAccount as String] = id }
    return q
  }
  func decode(_ data: Data) throws -> Record {
    guard let r = try? decoder.decode(Record.self, from: data) else {
      throw Failure(code: "INVALID_RECORD", message: "存在无法读取的条目，请检查版本兼容性。")
    }
    return r
  }
  func all() throws -> [Record] {
    var q = try query()
    q[kSecReturnData as String] = true
    q[kSecMatchLimit as String] = kSecMatchLimitAll
    var result: CFTypeRef?
    let s = SecItemCopyMatching(q as CFDictionary, &result)
    if s == errSecItemNotFound { return [] }
    guard s == errSecSuccess else { throw keychainFailure(s) }
    guard let items = result as? [Data] else { throw invalid() }
    return try items.map(decode)
  }
  func read(_ id: String) throws -> Record {
    var q = try query(id)
    q[kSecReturnData as String] = true
    q[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let s = SecItemCopyMatching(q as CFDictionary, &result)
    guard s == errSecSuccess else { throw keychainFailure(s) }
    guard let data = result as? Data else { throw invalid() }
    return try decode(data)
  }
  func insert(_ r: Record) throws {
    var q = try query(r.id)
    q[kSecValueData as String] = try encoder.encode(r)
    q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
    let s = SecItemAdd(q as CFDictionary, nil)
    guard s == errSecSuccess else { throw keychainFailure(s) }
    changed()
  }
  func replace(_ r: Record) throws {
    let s = SecItemUpdate(
      try query(r.id) as CFDictionary,
      [kSecValueData as String: try encoder.encode(r)] as CFDictionary)
    guard s == errSecSuccess else { throw keychainFailure(s) }
    changed()
  }
  func remove(_ id: String) throws {
    let s = SecItemDelete(try query(id) as CFDictionary)
    guard s == errSecSuccess else { throw keychainFailure(s) }
    changed()
  }
  private func changed() {
    DistributedNotificationCenter.default().postNotificationName(Notification.Name("com.boreas.aksk-manager.changed"),
      object: nil, userInfo: nil, deliverImmediately: true)
  }
}
#if TESTING
  // Compiled only into a separate test executable, never the shipped application.
  final class MemoryStorage: Storage {
    var items: [String: Record] = [:]
    func all() throws -> [Record] { Array(items.values) }
    func read(_ id: String) throws -> Record {
      guard let r = items[id] else { throw keychainFailure(errSecItemNotFound) }
      return r
    }
    func insert(_ r: Record) throws {
      guard items[r.id] == nil else { throw keychainFailure(errSecDuplicateItem) }
      items[r.id] = r
    }
    func replace(_ r: Record) throws {
      _ = try read(r.id)
      items[r.id] = r
    }
    func remove(_ id: String) throws {
      _ = try read(id)
      items.removeValue(forKey: id)
    }
  }
#endif
// Coordinates local read/check/update across sessions, not a global iCloud CAS.
func withStoreLock<T>(_ action: () throws -> T) throws -> T {
  let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
    "Library/Application Support/AKSK Manager")
  try FileManager.default.createDirectory(
    at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
  let fd = open(
    dir.appendingPathComponent("store.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
  guard fd >= 0 else { throw Failure(code: "LOCAL_LOCK_ERROR", message: "无法取得本机存储锁。") }
  defer { close(fd) }
  guard flock(fd, LOCK_EX) == 0 else {
    throw Failure(code: "LOCAL_LOCK_ERROR", message: "无法取得本机存储锁。")
  }
  defer { flock(fd, LOCK_UN) }
  return try action()
}
// Agent updates resolve references under the same local lock as revision checks
// and the final write. Plaintext never crosses the native boundary on this path.
func update(_ p: [String: Any], store: Storage) throws -> Record {
  guard Set(p.keys).isSubset(of: ["id", "revision", "changes", "field_refs", "remove_fields"]),
    let changes = p["changes"] as? [String: Any],
    Set(changes.keys).isSubset(of: ["name", "kind", "provider", "account", "environment", "tags", "notes"]),
    let refs = p["field_refs"] as? [String: [String: Any]], refs.count <= 11,
    let removed = p["remove_fields"] as? [String], removed.count <= 11,
    Set(removed).isDisjoint(with: Set(refs.keys)),
    !changes.isEmpty || !refs.isEmpty || !removed.isEmpty
  else { throw invalid() }
  let old = try store.read(required(p, "id"))
  guard try required(p, "revision") == old.revision else {
    throw Failure(code: "CONFLICT", message: "目标条目已变化，请重新读取元数据后核对。")
  }
  guard old.deletedAt == nil else { throw Failure(code: "TRASHED", message: "目标条目已在回收站。") }
  let fields: Set<String> = ["access_key", "secret_key", "session_token", "token", "engine",
                             "host", "port", "database", "username", "password", "ssl_mode"]
  guard Set(refs.keys).isSubset(of: fields), Set(removed).isSubset(of: fields.intersection(old.values.keys))
  else { throw invalid() }
  var record = old.metadata
  for (key, value) in changes { record[key] = value }
  var values = record["kind"] as? String == old.kind ? old.values : [:]
  for field in removed { values.removeValue(forKey: field) }
  for (destination, ref) in refs {
    guard Set(ref.keys).isSubset(of: ["secret_id", "revision", "field", "json_path"]),
      let path = ref["json_path"] as? [String], path.count <= 16
    else { throw invalid() }
    let source = try store.read(required(ref, "secret_id"))
    guard source.deletedAt == nil else {
      throw Failure(code: "TRASHED", message: "引用来源已在回收站。")
    }
    guard try required(ref, "revision") == source.revision else {
      throw Failure(code: "CONFLICT", message: "引用来源已变化，请重新读取元数据后核对。")
    }
    let field = try required(ref, "field")
    guard source.bindable(field), let raw = source.values[field] else {
      throw invalid("引用字段不存在。")
    }
    var value = raw
    if !path.isEmpty {
      guard let data = raw.data(using: .utf8),
        var selected = try? JSONSerialization.jsonObject(with: data)
      else { throw invalid("引用字段不是有效的 JSON 对象。") }
      for key in path {
        guard let object = selected as? [String: Any], let next = object[key] else {
          throw invalid("JSON 引用路径不存在或不是对象字段。")
        }
        selected = next
      }
      guard let text = selected as? String else { throw invalid("JSON 引用必须指向字符串。") }
      value = text
    }
    values[destination] = value
  }
  record["values"] = values
  return try save(record, store: store)
}

func save(_ p: [String: Any], store: Storage) throws -> Record {
  for key in ["id", "revision", "provider", "account", "environment", "notes"] {
    if let value = p[key], !(value is String) { throw invalid() }
  }
  if let value = p["tags"], !(value is [String]) { throw invalid() }
  if let value = p["values"], !(value is [String: String]) { throw invalid() }
  if let value = p["expiresAt"], !(value is NSNull), !(value is String) { throw invalid() }
  let id = p["id"] as? String ?? ""
  let old = id.isEmpty ? nil : try store.read(id)
  if let old {
    guard p["revision"] as? String == old.revision else {
      throw Failure(code: "CONFLICT", message: "条目已发生变化，请重新打开编辑。")
    }
    guard old.deletedAt == nil else { throw Failure(code: "TRASHED", message: "请先恢复条目。") }
  }
  let name = try required(p, "name").trimmingCharacters(in: .whitespacesAndNewlines)
  let kind = try required(p, "kind")
  guard ["aksk", "token", "database", "password"].contains(kind), !name.isEmpty, name.count <= 160 else { throw invalid() }
  func text(_ key: String, limit: Int = 500) throws -> String {
    let v = p[key] as? String ?? ""
    guard !v.contains("\0"), v.count <= limit else { throw invalid() }
    return v
  }
  let tags = p["tags"] as? [String] ?? []
  guard tags.count <= 30, tags.allSatisfy({ $0.count <= 80 && !$0.contains("\0") }) else {
    throw invalid()
  }
  var values = p["values"] as? [String: String]
  if p["mergeWebsiteFields"] as? Bool == true {
    guard kind == "password", let old, old.kind == kind, let supplied = values else { throw invalid() }
    values = old.values.merging(supplied.filter { !$0.value.isEmpty }) { _, new in new }
  }
  if values == nil, old?.kind == kind { values = old?.values }
  guard let values else { throw invalid("请填写密钥。") }
  let allowed: Set<String>
  let needed: [String]
  switch kind {
  case "password":
    allowed = ["url", "username", "password", "totp"]
    needed = []
    guard (webOrigin(values["url"] ?? "") != nil || (old?.importID != nil && values["url"] == nil)),
      !(values["password"] ?? "").isEmpty || !(values["totp"] ?? "").isEmpty || old?.passkeys?.isEmpty == false
    else { throw invalid("请填写 HTTPS 网址及密码或验证码设置密钥。") }
    if let seed = values["totp"], !seed.isEmpty { _ = try currentCode(seed) }
  case "aksk":
    allowed = ["access_key", "secret_key", "session_token"]
    needed = ["access_key", "secret_key"]
  case "database":
    allowed = ["engine", "host", "port", "database", "username", "password", "ssl_mode"]
    needed = ["engine", "host"]
  default:
    allowed = ["token"]
    needed = ["token"]
  }
  guard Set(values.keys).isSubset(of: allowed), needed.allSatisfy({ !(values[$0] ?? "").isEmpty }),
    values.values.allSatisfy({ !$0.contains("\0") && $0.utf8.count <= 16384 })
  else { throw invalid("请填写所选类型所需的密钥字段。") }
  if kind == "database" {
    guard needed.allSatisfy({ !(values[$0] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
    else { throw invalid("请填写数据库类型和主机。") }
    if let port = values["port"], !port.isEmpty {
      guard port.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
        let number = Int(port), (1...65535).contains(number)
      else { throw invalid("数据库端口必须是 1–65535 的整数。") }
    }
  }
  let r = Record(
    id: old?.id ?? UUID().uuidString, revision: UUID().uuidString, kind: kind, name: name,
    provider: try text("provider"), account: try text("account"),
    environment: try text("environment"), tags: tags,
    notes: try text("notes", limit: 4000), expiresAt: p["expiresAt"] as? String,
    values: values.filter({ !$0.value.isEmpty }), updatedAt: now(), deletedAt: nil,
    importID: kind == "password" ? old?.importID : nil, passkeys: kind == "password" ? old?.passkeys : nil,
    additionalURLs: kind == "password" ? old?.additionalURLs : nil)
  guard try encoder.encode(r).count <= 65536 else { throw invalid("条目过大。") }
  if old == nil { try store.insert(r) } else { try store.replace(r) }
  return r
}
