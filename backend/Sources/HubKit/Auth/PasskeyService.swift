import Foundation
import WebAuthn
@preconcurrency import SwiftCBOR

// Wrapper-Protokoll um webauthn-swift (F-04): Die Beta-Bibliothek ist auf einen Commit gepinnt und nur hier sichtbar.
// Ein Austausch betrifft nur `WebAuthnPasskeyService`. Das Protokoll arbeitet mit rohem JSON der Browser-API
// (Base64URL-Felder), so dass weder Routen noch Tests Bibliothekstypen kennen müssen.
// Vorbild (nur gelesen, neu geschrieben): timetrack-backend `WebAuthnService.swift`.

public struct PasskeyOptions: Sendable {
    /// Rohe Challenge-Bytes (werden serverseitig gespeichert).
    public let challenge: Data
    /// JSON-Objekt für `navigator.credentials.create/get({ publicKey })`.
    public let publicKey: Data
}

public struct PasskeyRegistration: Sendable {
    public let credentialID: Data
    public let publicKey: Data
    public let signCount: UInt32
    public let backedUp: Bool
}

public struct PasskeyAssertionInfo: Sendable {
    public let credentialID: Data
    public let userHandle: Data?
}

public struct PasskeyAssertionResult: Sendable {
    public let newSignCount: UInt32
    public let backedUp: Bool
}

public enum PasskeyError: Error, Sendable { case invalid }

public protocol PasskeyService: Sendable {
    func beginRegistration(userID: UUID, userName: String, displayName: String, excludeCredentialIDs: [Data]) throws -> PasskeyOptions
    func finishRegistration(challenge: Data, credentialJSON: Data,
                            isCredentialIDFree: @escaping @Sendable (Data) async throws -> Bool) async throws -> PasskeyRegistration
    func beginAuthentication() throws -> PasskeyOptions
    func assertionInfo(credentialJSON: Data) throws -> PasskeyAssertionInfo
    func finishAuthentication(challenge: Data, credentialJSON: Data, publicKey: Data, signCount: UInt32) throws -> PasskeyAssertionResult
}

public struct WebAuthnPasskeyService: PasskeyService {
    let manager: WebAuthnManager

    public init(rpID: String, rpName: String, origin: String) {
        manager = WebAuthnManager(configuration: .init(relyingPartyID: rpID, relyingPartyName: rpName, relyingPartyOrigin: origin))
    }

    /// Cross-Origin-Aufrufe (iframe) werden abgelehnt.
    private func requireSameOriginClient(_ clientDataJSON: [UInt8]) throws {
        struct Client: Decodable { let crossOrigin: Bool?; let topOrigin: String? }
        guard let c = try? JSONDecoder().decode(Client.self, from: Data(clientDataJSON)), c.crossOrigin != true, c.topOrigin == nil else {
            throw PasskeyError.invalid
        }
    }

    public func beginRegistration(userID: UUID, userName: String, displayName: String, excludeCredentialIDs: [Data]) throws -> PasskeyOptions {
        let options = manager.beginRegistration(user: .init(id: Array(userID.uuidString.utf8), name: userName, displayName: displayName))
        guard var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(options)) as? [String: Any] else { throw PasskeyError.invalid }
        object["authenticatorSelection"] = ["residentKey": "required", "requireResidentKey": true, "userVerification": "required"] as [String: Any]
        object["excludeCredentials"] = excludeCredentialIDs.map { ["type": "public-key", "id": $0.base64URL] }
        return PasskeyOptions(challenge: Data(options.challenge), publicKey: try JSONSerialization.data(withJSONObject: object))
    }

    public func finishRegistration(challenge: Data, credentialJSON: Data,
                                   isCredentialIDFree: @escaping @Sendable (Data) async throws -> Bool) async throws -> PasskeyRegistration {
        let proof: RegistrationCredential
        do { proof = try JSONDecoder().decode(RegistrationCredential.self, from: credentialJSON) } catch { throw PasskeyError.invalid }
        guard !proof.rawID.isEmpty, proof.id.decodedBytes == proof.rawID else { throw PasskeyError.invalid }
        try requireSameOriginClient(proof.attestationResponse.clientDataJSON)
        let credential: Credential
        do {
            credential = try await manager.finishRegistration(challenge: Array(challenge), credentialCreationData: proof,
                                                              requireUserVerification: true) { _ in
                try await isCredentialIDFree(Data(proof.rawID))
            }
        } catch { throw PasskeyError.invalid }
        // Die Bibliothek (Beta) liefert nur die ID der Hülle; sie wird hier an die attestierte ID gebunden.
        guard let attestation = try? CBOR.decode(proof.attestationResponse.attestationObject, options: CBOROptions(maximumDepth: 16)),
              case .byteString(let auth)? = attestation["authData"], auth.count >= 55 else { throw PasskeyError.invalid }
        let length = Int(auth[53]) * 256 + Int(auth[54])
        guard auth.count >= 55 + length, Array(auth[55..<(55 + length)]) == proof.rawID else { throw PasskeyError.invalid }
        return PasskeyRegistration(credentialID: Data(proof.rawID), publicKey: Data(credential.publicKey),
                                   signCount: credential.signCount, backedUp: credential.isBackedUp)
    }

    public func beginAuthentication() throws -> PasskeyOptions {
        let options = manager.beginAuthentication(userVerification: .required)
        return PasskeyOptions(challenge: Data(options.challenge), publicKey: try JSONEncoder().encode(options))
    }

    public func assertionInfo(credentialJSON: Data) throws -> PasskeyAssertionInfo {
        guard let c = try? JSONDecoder().decode(AuthenticationCredential.self, from: credentialJSON),
              !c.rawID.isEmpty, c.id.decodedBytes == c.rawID else { throw PasskeyError.invalid }
        return PasskeyAssertionInfo(credentialID: Data(c.rawID), userHandle: c.response.userHandle.map { Data($0) })
    }

    public func finishAuthentication(challenge: Data, credentialJSON: Data, publicKey: Data, signCount: UInt32) throws -> PasskeyAssertionResult {
        guard let c = try? JSONDecoder().decode(AuthenticationCredential.self, from: credentialJSON) else { throw PasskeyError.invalid }
        try requireSameOriginClient(c.response.clientDataJSON)
        do {
            let v = try manager.finishAuthentication(credential: c, expectedChallenge: Array(challenge), credentialPublicKey: Array(publicKey),
                                                     credentialCurrentSignCount: signCount, requireUserVerification: true)
            return PasskeyAssertionResult(newSignCount: v.newSignCount, backedUp: v.credentialBackedUp)
        } catch { throw PasskeyError.invalid }
    }
}

extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
