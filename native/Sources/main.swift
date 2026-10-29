import Darwin
import Foundation
import Security

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
  var metadata: [String: Any] {
    [
      "id": id, "revision": revision, "kind": kind, "name": name, "provider": provider,
      "account": account, "environment": environment, "tags": tags, "notes": notes,
      "fields": values.keys.sorted(), "updatedAt": updatedAt,
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
  }
  func replace(_ r: Record) throws {
    let s = SecItemUpdate(
      try query(r.id) as CFDictionary,
      [kSecValueData as String: try encoder.encode(r)] as CFDictionary)
    guard s == errSecSuccess else { throw keychainFailure(s) }
  }
  func remove(_ id: String) throws {
    let s = SecItemDelete(try query(id) as CFDictionary)
    guard s == errSecSuccess else { throw keychainFailure(s) }
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
  guard ["aksk", "token", "database"].contains(kind), !name.isEmpty, name.count <= 160 else { throw invalid() }
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
  if values == nil, old?.kind == kind { values = old?.values }
  guard let values else { throw invalid("请填写密钥。") }
  let allowed: Set<String>
  let needed: [String]
  switch kind {
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
    values: values.filter({ !$0.value.isEmpty }), updatedAt: now(), deletedAt: nil)
  guard try encoder.encode(r).count <= 65536 else { throw invalid("条目过大。") }
  if old == nil { try store.insert(r) } else { try store.replace(r) }
  return r
}
// Continuously drain bounded buffers. Publish only after completion to prevent cross-chunk leaks.
final class Capture {
  let lock = NSLock()
  var bytes = Data()
  var truncated = false
  let limit = 524288
  let tail: Int
  init(secrets: [String]) { tail = max(1, secrets.map({ $0.utf8.count }).max() ?? 1) }
  func append(_ data: Data) {
    lock.lock()
    defer { lock.unlock() }
    let remaining = max(0, limit + tail - bytes.count)
    bytes.append(data.prefix(remaining))
    if data.count > remaining { truncated = true }
  }
  func finish(secrets: [String]) -> (String, Bool) {
    lock.lock()
    defer { lock.unlock() }
    let source = [UInt8](bytes)
    var patterns: [UInt8: [[UInt8]]] = [:]
    for value in secrets.sorted(by: { $0.utf8.count > $1.utf8.count }) where !value.isEmpty {
      let needle = [UInt8](value.utf8)
      patterns[needle[0], default: []].append(needle)
    }
    // Scan only original bytes: replacement markers are never matched again. This also
    // keeps short/repeating secrets from causing quadratic replacement or output growth.
    let safeEnd = truncated ? max(0, source.count - tail) : source.count
    let marker = Data("[REDACTED]".utf8)
    var index = 0
    var output = Data()
    while index < safeEnd && output.count < limit {
      let match = patterns[source[index]]?.first { needle in
        index + needle.count <= source.count
          && source[index..<(index + needle.count)].elementsEqual(needle)
      }
      if let match {
        output.append(marker.prefix(limit - output.count))
        index += match.count
      } else {
        output.append(source[index])
        index += 1
      }
    }
    // Invalid UTF-8 may expand when decoded; bound the final encoded result as well.
    let decoded = String(decoding: output, as: UTF8.self)
    var encoded = Data(decoded.utf8.prefix(limit))
    while String(data: encoded, encoding: .utf8) == nil { encoded.removeLast() }
    let text = String(data: encoded, encoding: .utf8) ?? ""
    let clipped = truncated || index < source.count || decoded.utf8.count > limit
    bytes.resetBytes(in: bytes.startIndex..<bytes.endIndex)
    bytes.removeAll(keepingCapacity: false)
    return (text, clipped)
  }
}
final class Job {
  let id = UUID().uuidString
  let createdAt = now()
  let secretIDs: [String]
  let lock = NSLock()
  var pid: pid_t = 0
  var state = "running"
  var exitCode: Int?
  var stdout = ""
  var stderr = ""
  var truncated = false
  var finished = false
  var stopReason: String?
  init(ids: [String]) { secretIDs = ids }
  func status() -> [String: Any] {
    lock.lock()
    defer { lock.unlock() }
    return [
      "id": id, "state": state, "createdAt": createdAt, "secret_ids": secretIDs,
      "exit_code": exitCode as Any? ?? NSNull(), "stdout": stdout, "stderr": stderr,
      "truncated": truncated,
    ]
  }
  func stop(_ reason: String) {
    lock.lock()
    defer { lock.unlock() }
    guard !finished, stopReason == nil else { return }
    stopReason = reason
    if pid > 0 { kill(-pid, SIGKILL) }  // This run's private process group only.
  }
}
func executable(_ command: String, path: String, cwd: String) throws -> String {
  if command.contains("/") {
    let full = command.hasPrefix("/") ? command : (cwd as NSString).appendingPathComponent(command)
    guard FileManager.default.isExecutableFile(atPath: full) else {
      throw Failure(code: "COMMAND_NOT_FOUND", message: "命令不存在或不可执行。")
    }
    return full
  }
  for dir in path.split(separator: ":", omittingEmptySubsequences: false) {
    let candidate = ((dir.isEmpty ? cwd : String(dir)) as NSString).appendingPathComponent(command)
    if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
  }
  throw Failure(code: "COMMAND_NOT_FOUND", message: "命令不存在或不可执行，请提供绝对路径。")
}
func spawn(
  _ argv: [String], cwd: String, env: [String: String], job: Job, secrets: [String], timeout: Double
) throws {
  let path = try executable(argv[0], path: env["PATH"] ?? "/usr/bin:/bin", cwd: cwd)
  var out: [Int32] = [0, 0]
  var err: [Int32] = [0, 0]
  guard pipe(&out) == 0 else { throw Failure(code: "EXEC_FAILED", message: "无法创建输出通道。") }
  guard pipe(&err) == 0 else {
    close(out[0])
    close(out[1])
    throw Failure(code: "EXEC_FAILED", message: "无法创建输出通道。")
  }
  var actions: posix_spawn_file_actions_t?
  var attrs: posix_spawnattr_t?
  posix_spawn_file_actions_init(&actions)
  posix_spawnattr_init(&attrs)
  defer {
    posix_spawn_file_actions_destroy(&actions)
    posix_spawnattr_destroy(&attrs)
  }
  posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
  posix_spawn_file_actions_adddup2(&actions, out[1], STDOUT_FILENO)
  posix_spawn_file_actions_adddup2(&actions, err[1], STDERR_FILENO)
  posix_spawn_file_actions_addchdir_np(&actions, cwd)
  posix_spawnattr_setflags(&attrs, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
  posix_spawnattr_setpgroup(&attrs, 0)
  let args = argv.map { strdup($0) } + [nil]
  let environment = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
  defer { for s in args + environment { free(s) } }
  var pid: pid_t = 0
  let status = args.withUnsafeBufferPointer { a in
    environment.withUnsafeBufferPointer { e in
      posix_spawn(
        &pid, path, &actions, &attrs, UnsafeMutablePointer(mutating: a.baseAddress!),
        UnsafeMutablePointer(mutating: e.baseAddress!))
    }
  }
  close(out[1])
  close(err[1])
  guard status == 0 else {
    close(out[0])
    close(err[0])
    throw Failure(code: "EXEC_FAILED", message: "无法启动命令，请检查路径及执行权限。")
  }
  job.pid = pid
  let stdout = Capture(secrets: secrets)
  let stderr = Capture(secrets: secrets)
  let readers = DispatchGroup()
  for (fd, capture) in [(out[0], stdout), (err[0], stderr)] {
    readers.enter()
    DispatchQueue.global().async {
      defer {
        close(fd)
        readers.leave()
      }
      var buf = [UInt8](repeating: 0, count: 8192)
      while true {
        let n = Darwin.read(fd, &buf, buf.count)
        if n > 0 {
          capture.append(Data(buf.prefix(n)))
        } else if n < 0 && errno == EINTR {
          continue
        } else {
          break
        }
      }
    }
  }
  DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { job.stop("timed_out") }
  let childPID = pid
  DispatchQueue.global().async {
    var status: Int32 = 0
    while waitpid(childPID, &status, 0) == -1 && errno == EINTR {}
    readers.wait()
    let o = stdout.finish(secrets: secrets)
    let e = stderr.finish(secrets: secrets)
    job.lock.lock()
    defer { job.lock.unlock() }
    job.finished = true
    let signal = status & 0x7f
    let code = signal == 0 ? (status >> 8) & 0xff : 128 + signal
    job.exitCode = Int(code)
    job.state = job.stopReason ?? (code == 0 ? "completed" : "failed")
    job.stdout = o.0
    job.stderr = e.0
    job.truncated = o.1 || e.1
  }
}
final class Service {
  let store: Storage
  var jobs: [String: Job] = [:]
  init(store: Storage) { self.store = store }
  func perform(_ method: String, _ p: [String: Any]) throws -> Any {
    switch method {
    case "status":
      _ = try store.all()
      return [
        "keychain": "available", "sync": "managed_by_icloud", "remote_verified": false,
        "version": "0.1.0",
      ]
    case "list":
      let trash = p["trash"] as? Bool ?? false
      let query = (p["query"] as? String ?? "").lowercased()
      return try store.all().filter {
        ($0.deletedAt != nil) == trash
          && (query.isEmpty
            || ([$0.name, $0.provider, $0.account, $0.environment] + $0.tags).joined(separator: " ")
              .lowercased().contains(query))
      }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }.map(\.metadata)
    case "metadata": return try store.read(required(p, "id")).metadata
    case "save": return try withStoreLock { try save(p, store: store).metadata }
    case "reveal":
      let r = try store.read(required(p, "id"))
      guard r.deletedAt == nil else { throw Failure(code: "TRASHED", message: "请先恢复条目。") }
      guard p["revision"] as? String == r.revision else {
        throw Failure(code: "CONFLICT", message: "条目已变化，请刷新。")
      }
      return ["values": r.values]
    case "trash", "restore", "purge":
      return try withStoreLock {
        var r = try store.read(required(p, "id"))
        guard p["revision"] as? String == r.revision else {
          throw Failure(code: "CONFLICT", message: "条目已变化，请刷新。")
        }
        if method == "purge" {
          guard r.deletedAt != nil else { throw Failure(code: "NOT_TRASHED", message: "请先移入回收站。") }
          try store.remove(r.id)
          return ["id": r.id, "removed": true]
        }
        r.deletedAt = method == "trash" ? now() : nil
        r.revision = UUID().uuidString
        r.updatedAt = now()
        try store.replace(r)
        return r.metadata
      }
    case "run":
      guard let argv = p["argv"] as? [String], !argv.isEmpty, argv.count <= 512,
        argv.allSatisfy({ !$0.contains("\0") && $0.utf8.count <= 65536 })
      else { throw invalid() }
      let cwd = try required(p, "cwd")
      var isDir: ObjCBool = false
      guard cwd.hasPrefix("/"), FileManager.default.fileExists(atPath: cwd, isDirectory: &isDir),
        isDir.boolValue
      else { throw invalid("工作目录必须是已存在的绝对路径。") }
      guard let bindings = p["bindings"] as? [String: [String: String]], !bindings.isEmpty,
        bindings.count <= 64
      else { throw invalid("至少指定一个密钥字段引用。") }
      let timeout = (p["timeout_seconds"] as? NSNumber)?.doubleValue ?? 600
      guard timeout >= 0.1, timeout <= 3600 else { throw invalid("超时必须在 0.1 到 3600 秒之间。") }
      guard jobs.values.filter({ $0.status()["state"] as? String == "running" }).count < 8 else {
        throw Failure(code: "BUSY", message: "最多同时运行 8 个任务。")
      }
      if jobs.count >= 64,
        let oldest = jobs.values.filter({ $0.status()["state"] as? String != "running" }).sorted(
          by: { $0.createdAt < $1.createdAt }).first
      {
        jobs.removeValue(forKey: oldest.id)
      }
      var env = ProcessInfo.processInfo.environment.filter {
        ["PATH", "HOME", "TMPDIR", "USER", "LOGNAME", "LANG", "LC_ALL", "SHELL"].contains($0.key)
      }
      var secrets: [String] = []
      var ids = Set<String>()
      for (key, ref) in bindings {
        guard key.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil,
          let id = ref["secret_id"], let field = ref["field"]
        else { throw invalid() }
        let r = try store.read(id)
        guard r.deletedAt == nil else { throw Failure(code: "TRASHED", message: "所选密钥在回收站中。") }
        guard let value = r.values[field], !value.isEmpty else {
          throw Failure(code: "FIELD_NOT_FOUND", message: "所选密钥字段不存在。")
        }
        env[key] = value
        ids.insert(id)
        secrets.append(contentsOf: r.values.values)
      }
      let job = Job(ids: ids.sorted())
      try spawn(argv, cwd: cwd, env: env, job: job, secrets: Array(Set(secrets)), timeout: timeout)
      jobs[job.id] = job
      return job.status()
    case "get_run", "cancel_run":
      let id = try required(p, "id")
      guard let job = jobs[id] else {
        throw Failure(code: "RUN_NOT_FOUND", message: "任务不存在，可能属于其他会话或已被清理。")
      }
      if method == "cancel_run" { job.stop("cancelled") }
      return job.status()
    default: throw Failure(code: "UNKNOWN_METHOD", message: "未知操作。")
    }
  }
  func shutdown() { for job in jobs.values { job.stop("cancelled") } }
}
let store: Storage
#if TESTING
  store = MemoryStorage()
#else
  store = KeychainStorage()
#endif
let service = Service(store: store)
while let line = readLine(strippingNewline: true) {
  var id: Any = NSNull()
  var response: [String: Any]
  do {
    guard line.utf8.count <= 1_048_576, let input = line.data(using: .utf8),
      let request = try JSONSerialization.jsonObject(with: input) as? [String: Any],
      let requestID = request["id"] as? Int, let method = request["method"] as? String,
      let payload = request["payload"] as? [String: Any]
    else { throw invalid() }
    id = requestID
    response = ["id": id, "ok": true, "data": try service.perform(method, payload)]
  } catch let error as Failure { response = ["id": id, "ok": false, "error": error.json] } catch {
    response = [
      "id": id, "ok": false,
      "error": Failure(code: "INTERNAL_ERROR", message: "本地操作失败，已省略可能含有密钥的诊断详情。").json,
    ]
  }
  if let data = try? JSONSerialization.data(withJSONObject: response, options: [.sortedKeys]) {
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([10]))
  }
}
service.shutdown()
