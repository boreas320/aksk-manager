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
    let scope = ASImportableCredentialScope(urls: [URL(string: "https://" + rp)!])
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
    let stored = record.passkeys![0]
    let hash = Data(SHA256.hash(data: Data("fixture challenge".utf8)))
    let (auth, signature) = try stored.assertion(clientHash: hash)
    let verifier = try P256.Signing.PrivateKey(derRepresentation: stored.key).publicKey
    let sig = try P256.Signing.ECDSASignature(derRepresentation: signature)
    precondition(auth.prefix(32) == Data(SHA256.hash(data: Data(rp.utf8))))
    precondition(verifier.isValidSignature(sig, for: auth + hash))
    var first = records.first { $0.name == "first" }!
    var req = ["action": "fill", "origin": "https://" + rp, "id": first.id,
               "revision": first.revision, "field": "password"]
    let password = try browserRequest(req, store: store) as? String
    precondition(password == "demo-password")
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
    precondition(edited.passkeys == record.passkeys)
  }
}
