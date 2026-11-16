import AppKit
import AuthenticationServices
import CryptoKit
import LocalAuthentication
import OSLog

final class Provider: ASCredentialProviderViewController {
  private let audit = Logger(subsystem: "com.boreas.aksk-manager.exchange.provider", category: "credential-request")
  override func prepareInterfaceForExtensionConfiguration() {
    Task { @MainActor in
      do {
        try await refreshIdentities()
        extensionContext.completeExtensionConfigurationRequest()
      } catch { extensionContext.cancelRequest(withError: ASExtensionError(.failed)) }
    }
  }
  override func loadView() { view = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 180)) }
  override func provideCredentialWithoutUserInteraction(for request: any ASCredentialRequest) {
    audit.notice("Credential selection requires local verification")
    extensionContext.cancelRequest(withError: ASExtensionError(.userInteractionRequired))
  }
  override func prepareInterfaceToProvideCredential(for request: any ASCredentialRequest) {
    Task { @MainActor in
      var stage = "identity"
      do {
        guard let id = request.credentialIdentity.recordIdentifier else { throw invalid() }
        let label = request.credentialIdentity.serviceIdentifier.identifier
        stage = "local-verification"
        audit.notice("Interactive credential request started")
        guard try await LAContext().evaluatePolicy(.deviceOwnerAuthentication,
          localizedReason: "使用 AKSK Manager 登录 \(label)") else { throw invalid() }
        stage = "lookup"
        let record = try KeychainStorage().read(id)
        guard record.kind == "password", record.deletedAt == nil else { throw invalid() }
        if let assertion = request as? ASPasskeyCredentialRequest,
          let identity = assertion.credentialIdentity as? ASPasskeyCredentialIdentity,
          let key = record.passkeys?.first(where: { $0.rp == identity.relyingPartyIdentifier &&
            $0.credentialID == identity.credentialID && $0.handle == identity.userHandle }),
          assertion.clientDataHash.count == 32 {
          stage = "signature"
          let (auth, signature) = try key.assertion(clientHash: assertion.clientDataHash)
          let response = ASPasskeyAssertionCredential(userHandle: key.handle, relyingParty: key.rp,
            signature: signature, clientDataHash: assertion.clientDataHash,
            authenticatorData: auth, credentialID: key.credentialID)
          audit.notice("Passkey assertion signed; submitting to system")
          _ = await extensionContext.completeAssertionRequest(using: response)
        } else {
          guard let origin = webOrigin(label), webOrigin(record.values["url"] ?? "") == origin else { throw invalid() }
          if request.credentialIdentity is ASOneTimeCodeCredentialIdentity, let seed = record.values["totp"] {
            _ = await extensionContext.completeOneTimeCodeRequest(using: ASOneTimeCodeCredential(code: try currentCode(seed)))
          } else if request.credentialIdentity is ASPasswordCredentialIdentity, let password = record.values["password"] {
            extensionContext.completeRequest(withSelectedCredential: ASPasswordCredential(
              user: record.values["username"] ?? "", password: password))
          } else { throw invalid() }
        }
      } catch {
        audit.error("Request failed at \(stage, privacy: .public), code \((error as NSError).code, privacy: .public)")
        extensionContext.cancelRequest(withError: ASExtensionError(.userCanceled))
      }
    }
  }
}
