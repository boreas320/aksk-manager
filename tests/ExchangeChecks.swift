import AuthenticationServices
import CryptoKit
import Foundation

@main
struct ExchangeChecks {
  @MainActor static func main() throws {
    let store = MemoryStorage()
    let rp = "accounts.example.invalid"
    let seed = Data("12345678901234567890".utf8)
    let uri = "otpauth://totp/example?digits=8&secret=" + base32(seed)
    let code = try currentCode(uri, at: 59)
    precondition(code == "94287082")
    let scope = ASImportableCredentialScope(urls: [URL(string: "https://" + rp)!, URL(string: "https://second.invalid/login")!, URL(string: "https://second.invalid/other")!])
    func passkey(_ id: UInt8) -> ASImportableCredential {
      .passkey(.init(credentialID: Data([id]), relyingPartyIdentifier: rp, userName: "demo",
        userDisplayName: "Demo", userHandle: Data([id]), key: P256.Signing.PrivateKey().derRepresentation))
    }
    let basic = ASImportableCredential.basicAuthentication(.init(
      userName: .init(id: nil, fieldType: .string, value: "demo"), password: .init(id: nil, fieldType: .concealedString, value: "demo-password")))
    let otp = ASImportableCredential.totp(.init(secret: seed, period: 30, digits: 8, userName: "demo", algorithm: .sha1))
    let items = [
      ASImportableItem(id: Data([1]), created: Date(), lastModified: Date(), title: "first", scope: scope,
        credentials: [basic, otp, passkey(1), passkey(2)]),
      ASImportableItem(id: Data([2]), created: Date(), lastModified: Date(), title: "second", scope: scope,
        credentials: [passkey(3)]),
    ]
    let account = ASImportableAccount(id: Data([9]), userName: "owner", email: "", collections: [], items: items)
    let export = ASExportedCredentialData(accounts: [account], formatVersion: .v1,
      exporterRelyingPartyIdentifier: "example.invalid", exporterDisplayName: "Fixture", timestamp: Date())
    precondition(receive(export, store: store).hasPrefix("新增 2"))
    precondition(receive(export, store: store).contains("跳过 2"))
    let records = try store.all()
    precondition(records.count == 2 && records.first { $0.name == "first" }?.passkeys?.count == 2)
    let record = records.first { $0.name == "second" }!
    precondition(record.matches("demo", includeValues: true))
    precondition(!record.matches("demo", includeValues: false))
    var rotated = export
    rotated.accounts[0].id = Data([99])
    precondition(receive(rotated, store: store).hasPrefix("新增 0，更新 0，跳过 2"))
    var duplicate = record
    duplicate.id = UUID().uuidString
    duplicate.importID = "different"
    try store.insert(duplicate)
    precondition(receive(rotated, store: store).contains("1 项匹配多个已有账号"))
    let after = try store.all()
    precondition(after.count == 3 && after.contains { $0.id == duplicate.id && $0.revision == duplicate.revision })
    // An import with no passkey and a changed source ID must ask, even
    // when it uniquely matches an existing login. Each button is exercised.
    var weakExport = rotated
    weakExport.accounts[0].items = [ASImportableItem(id: Data([12]), created: Date(), lastModified: Date(),
      title: "renamed login", scope: scope, credentials: [basic])]
    let target = records.first { $0.name == "first" }!
    precondition(receive(weakExport, store: store) { _, found in
      precondition(found.map(\.id) == [target.id])
      return .skip
    }.contains("跳过 1"))
    precondition(receive(weakExport, store: store) { _, _ in .update(target.id) }.contains("更新 1"))
    let preserved = try store.read(target.id)
    precondition(preserved.name == "renamed login" && preserved.passkeys == target.passkeys &&
      preserved.values["totp"] == target.values["totp"])
    precondition(receive(weakExport, store: store) { _, _ in .add }.hasPrefix("新增 1"))
    var probe = preserved
    probe.passkeys = nil
    probe.additionalURLs = nil
    probe.values["url"] = "https://second.invalid:443/changed"
    precondition(possibleLogins(probe, in: [preserved]).count == 1)
    for url in ["https://second.invalid:444/", "https://sub.second.invalid/", "http://second.invalid/"] {
      probe.values["url"] = url
      precondition(possibleLogins(probe, in: [preserved]).isEmpty)
    }
    probe.values["url"] = "https://second.invalid"
    for username in ["", "other"] {
      probe.values["username"] = username
      precondition(possibleLogins(probe, in: [preserved]).isEmpty)
    }
    let stored = record.passkeys![0]
    let hash = Data(SHA256.hash(data: Data("fixture challenge".utf8)))
    let (auth, signature) = try stored.assertion(clientHash: hash)
    let verifier = try P256.Signing.PrivateKey(derRepresentation: stored.key).publicKey
    let sig = try P256.Signing.ECDSASignature(derRepresentation: signature)
    precondition(auth.prefix(32) == Data(SHA256.hash(data: Data(rp.utf8))))
    precondition(verifier.isValidSignature(sig, for: auth + hash))
    var first = try store.read(target.id)
    var req = ["action": "fill", "origin": "https://" + rp, "id": first.id,
               "revision": first.revision, "field": "password"]
    let password = try browserRequest(req, store: store) as? String
    precondition(password == "demo-password")
    precondition(first.websiteURLs.count == 3 && first.websiteOrigins.count == 2)
    req["origin"] = "https://second.invalid"
    let secondary = try browserRequest(req, store: store) as? String
    precondition(secondary == password)
    req["field"] = "otp_code"
    let otpValue = try browserRequest(req, store: store) as? String
    precondition(otpValue?.count == 8)
    for field in ["key", "passkeys", "totp"] {
      req["field"] = field
      precondition((try? browserRequest(req, store: store)) == nil)
    }
    req["field"] = "password"
    req["origin"] = "https://elsewhere.invalid"
    precondition((try? browserRequest(req, store: store)) == nil)
    req["origin"] = "https://" + rp
    first.deletedAt = now()
    try store.replace(first)
    precondition((try? browserRequest(req, store: store)) == nil)
    let edited = try save(record.metadata.merging(["name": "renamed"]) { _, new in new }, store: store)
    precondition(edited.passkeys == record.passkeys && edited.websiteURLs == record.websiteURLs)
  }
}
