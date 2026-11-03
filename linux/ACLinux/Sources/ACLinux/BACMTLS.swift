import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The install's mTLS client for Bromure's cloud (event ingest, HTTP trace
/// ingest, egress-IP heartbeat; macOS: URLSession + BACMTLSDelegate
/// presenting the org-CA leaf). Linux's URLSession can't present a client
/// certificate and the NIOSSL client that will isn't written yet: every
/// request fails with BACMTLSUnavailable, and nothing leaves the host.
// partial: no mTLS on Linux yet (to come: AsyncHTTPClient + NIOSSL with the leaf from BACSecretStore)
// @port-skip linux-only: the Linux side of CloudMTLSClient.swift's BACMTLS seam
enum BACMTLS {
    // @port-skip linux-only: BACMTLS seam
    static func makeClient(timeout: TimeInterval) -> BACMTLSClient { UnavailableBACMTLSClient() }

    /// No identity is cached on Linux yet: nothing to forget.
    // @port-skip linux-only: BACMTLS seam
    static func purgeIdentity() {}
}

struct BACMTLSUnavailable: Error, CustomStringConvertible {
    // @port-skip linux-only: BACMTLS seam
    var description: String { "Bromure cloud uploads need mTLS, which bromure-ac on Linux doesn't support yet" }
}

// @port-skip linux-only: BACMTLS seam
final class UnavailableBACMTLSClient: BACMTLSClient, @unchecked Sendable {
    // @port-skip linux-only: BACMTLS seam
    func send(_ req: URLRequest, completion: @escaping @Sendable (Data?, URLResponse?, Error?) -> Void) {
        DispatchQueue.global(qos: .utility).async { completion(nil, nil, BACMTLSUnavailable()) }
    }

    // @port-skip linux-only: BACMTLS seam
    func shutdown(cancelling: Bool) {}
}
