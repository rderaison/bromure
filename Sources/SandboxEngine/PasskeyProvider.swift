import AppKit
import AuthenticationServices
import Foundation

/// Result types for passkey operations.
public struct PasskeyCreateResult {
    public let credentialId: String  // base64
    public let attestationObject: String  // base64
    public let clientDataJSON: String  // base64
}

public struct PasskeyGetResult {
    public let credentialId: String  // base64
    public let authenticatorData: String  // base64
    public let signature: String  // base64
    public let userHandle: String  // base64
    public let clientDataJSON: String  // base64
}

public struct PasswordGetResult {
    public let username: String
    public let password: String
}

/// What the ASAuthorizationController returned for a get request.
public enum CredentialGetResult {
    case passkey(PasskeyGetResult)
    case password(PasswordGetResult)
}

/// Wraps ASAuthorizationController for passkey create/get operations.
///
/// Uses the browser-specific `clientData:` API path on
/// `ASAuthorizationPlatformPublicKeyCredentialProvider`, which lets us set the
/// web origin so relying parties see the correct origin in clientDataJSON.
/// Requires `com.apple.developer.web-browser.public-key-credential` entitlement.
///
/// Each instance handles a single request. Create a new PasskeyProvider for each
/// WebAuthn operation — ASAuthorizationController is not reusable.
@MainActor
final class PasskeyProvider: NSObject, ASAuthorizationControllerDelegate,
    ASAuthorizationControllerPresentationContextProviding
{
    private weak var window: NSWindow?
    private var createContinuation: CheckedContinuation<PasskeyCreateResult, Error>?
    private var getContinuation: CheckedContinuation<CredentialGetResult, Error>?

    init(window: NSWindow) {
        self.window = window
    }

    // MARK: - Create Passkey

    func createPasskey(
        rpId: String,
        origin: String,
        challenge: Data,
        userId: Data,
        userName: String,
        displayName: String
    ) async throws -> PasskeyCreateResult {
        let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(
            relyingPartyIdentifier: rpId
        )
        let clientData = ASPublicKeyCredentialClientData(
            challenge: challenge,
            origin: origin
        )
        let request = provider.createCredentialRegistrationRequest(
            clientData: clientData,
            name: userName,
            userID: userId
        )
        request.displayName = displayName
        request.userVerificationPreference = .preferred

        let controller = ASAuthorizationController(authorizationRequests: [request])
        controller.delegate = self
        controller.presentationContextProvider = self

        return try await withCheckedThrowingContinuation { continuation in
            self.createContinuation = continuation
            controller.performRequests()
        }
    }

    // MARK: - Get Passkey

    func getCredential(
        rpId: String,
        origin: String,
        challenge: Data,
        allowedCredentialIDs: [Data] = []
    ) async throws -> CredentialGetResult {
        let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(
            relyingPartyIdentifier: rpId
        )
        let clientData = ASPublicKeyCredentialClientData(
            challenge: challenge,
            origin: origin
        )
        let passkeyRequest = provider.createCredentialAssertionRequest(clientData: clientData)
        if !allowedCredentialIDs.isEmpty {
            passkeyRequest.allowedCredentials = allowedCredentialIDs.map {
                ASAuthorizationPlatformPublicKeyCredentialDescriptor(credentialID: $0)
            }
        }

        let controller = ASAuthorizationController(authorizationRequests: [passkeyRequest])
        controller.delegate = self
        controller.presentationContextProvider = self

        return try await withCheckedThrowingContinuation { continuation in
            self.getContinuation = continuation
            controller.performRequests()
        }
    }

    // MARK: - ASAuthorizationControllerDelegate

    func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithAuthorization authorization: ASAuthorization
    ) {
        if let registration = authorization.credential
            as? ASAuthorizationPlatformPublicKeyCredentialRegistration
        {
            let result = PasskeyCreateResult(
                credentialId: registration.credentialID.base64EncodedString(),
                attestationObject: registration.rawAttestationObject?.base64EncodedString() ?? "",
                clientDataJSON: registration.rawClientDataJSON.base64EncodedString()
            )
            createContinuation?.resume(returning: result)
            createContinuation = nil

        } else if let assertion = authorization.credential
            as? ASAuthorizationPlatformPublicKeyCredentialAssertion
        {
            let result = PasskeyGetResult(
                credentialId: assertion.credentialID.base64EncodedString(),
                authenticatorData: assertion.rawAuthenticatorData.base64EncodedString(),
                signature: assertion.signature.base64EncodedString(),
                userHandle: assertion.userID.base64EncodedString(),
                clientDataJSON: assertion.rawClientDataJSON.base64EncodedString()
            )
            getContinuation?.resume(returning: .passkey(result))
            getContinuation = nil

        } else if let passwordCredential = authorization.credential
            as? ASPasswordCredential
        {
            let result = PasswordGetResult(
                username: passwordCredential.user,
                password: passwordCredential.password
            )
            getContinuation?.resume(returning: .password(result))
            getContinuation = nil
        }
    }

    func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithError error: Error
    ) {
        if let cont = createContinuation {
            cont.resume(throwing: error)
            createContinuation = nil
        }
        if let cont = getContinuation {
            cont.resume(throwing: error)
            getContinuation = nil
        }
    }

    // MARK: - ASAuthorizationControllerPresentationContextProviding

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        window ?? NSApp.keyWindow ?? NSWindow()
    }
}
