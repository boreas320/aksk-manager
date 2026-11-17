import AuthenticationServices
import Foundation

@available(macOS 26.0, *)
func refreshIdentities() async throws {
  let identityStore = ASCredentialIdentityStore.shared
  let state = await identityStore.state()
  guard state.isEnabled else { return }
  var identities: [any ASCredentialIdentity] = []
  for record in try KeychainStorage().all() where record.kind == "password" && record.deletedAt == nil {
    for key in record.passkeys ?? [] {
      identities.append(ASPasskeyCredentialIdentity(relyingPartyIdentifier: key.rp, userName: key.username,
        credentialID: key.credentialID, userHandle: key.handle, recordIdentifier: record.id))
    }
    for origin in record.websiteOrigins.sorted() {
      let service = ASCredentialServiceIdentifier(identifier: origin, type: .URL)
      let username = record.values["username"] ?? record.name
      if record.values["password"] != nil {
        identities.append(ASPasswordCredentialIdentity(serviceIdentifier: service, user: username, recordIdentifier: record.id))
      }
      if record.values["totp"] != nil {
        identities.append(ASOneTimeCodeCredentialIdentity(serviceIdentifier: service, label: username, recordIdentifier: record.id))
      }
    }
  }
  try await identityStore.replaceCredentialIdentities(identities)
}
