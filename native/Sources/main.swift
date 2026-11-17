import Darwin
import Foundation
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
    case "list", "ui_list":
      let trash = p["trash"] as? Bool ?? false
      let query = p["query"] as? String ?? ""
      return try store.all().filter {
        ($0.deletedAt != nil) == trash
          && $0.matches(query, includeValues: method == "ui_list")
      }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }.map { r in
        var metadata = r.metadata
        if method == "ui_list", r.kind == "password", r.deletedAt == nil {
          metadata["website"] = ["url": r.values["url"] ?? r.passkeys?.first?.rp ?? "",
                                 "username": r.values["username"] ?? r.passkeys?.first?.username ?? ""]
          metadata["websiteURLs"] = r.websiteURLs
          metadata["passkeyInfo"] = (r.passkeys ?? []).map { "\($0.username) · \($0.rp)" }
        }
        return metadata
      }
    case "metadata": return try store.read(required(p, "id")).metadata
    case "save": return try withStoreLock { try save(p, store: store).metadata }
    case "update": return try withStoreLock { try update(p, store: store).metadata }
    case "reveal", "otp":
      let r = try store.read(required(p, "id"))
      guard r.deletedAt == nil else { throw Failure(code: "TRASHED", message: "请先恢复条目。") }
      guard p["revision"] as? String == r.revision else {
        throw Failure(code: "CONFLICT", message: "条目已变化，请刷新。")
      }
      if method == "otp" {
        guard r.kind == "password", let seed = r.values["totp"] else { throw invalid() }
        let window = try codeWindow(seed)
        return ["code": window.code, "expires": window.expires]
      }
      var visible = r.values.filter { r.accessibleFields.contains($0.key) }
      if r.kind == "password", let seed = r.values["totp"] { visible["otp_code"] = try currentCode(seed) }
      if let keys = r.passkeys, !keys.isEmpty {
        visible["passkey_info"] = keys.map { "\($0.username) · \($0.rp)" }.joined(separator: "\n")
      }
      return ["values": visible]
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
        guard r.bindable(field), let value = r.values[field], !value.isEmpty else {
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
if CommandLine.arguments.dropFirst().first == "--browser" {
  let input = FileHandle.standardInput
  func readExactly(_ length: Int) -> Data {
    var result = Data()
    while result.count < length {
      let part = input.readData(ofLength: length - result.count)
      if part.isEmpty { break }
      result.append(part)
    }
    return result
  }
  let header = readExactly(4)
  guard header.count == 4 else { exit(1) }
  let length = Int(header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian)
  guard (1...65536).contains(length) else { exit(1) }
  var reply: [String: Any] = ["ok": false]
  if let request = (try? JSONSerialization.jsonObject(with: readExactly(length))) as? [String: Any],
    let data = try? browserRequest(request, store: store) { reply = ["ok": true, "data": data] }
  guard let body = try? JSONSerialization.data(withJSONObject: reply), body.count < 1048576 else { exit(1) }
  var size = UInt32(body.count).littleEndian
  FileHandle.standardOutput.write(withUnsafeBytes(of: &size) { Data($0) })
  FileHandle.standardOutput.write(body)
  exit(0)
}
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
