import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A managed profile's mTLS client for the cloud trace ingest (macOS: a
/// URLSession whose delegate presents the profile's org-CA leaf). Linux's
/// URLSession can't present a client certificate, and the NIOSSL client
/// that will isn't written yet: until then every request fails with
/// `CloudTraceMTLSUnavailable`, and nothing leaves the host.
// partial: no mTLS on Linux yet (to come: AsyncHTTPClient + NIOSSL with the leaf from BACSecretStore)
// @port-skip linux-only: the Linux side of the CloudTraceMTLS seam (CloudTraceUploader.swift has the Apple one)
public enum CloudTraceMTLS {
    // @port-skip linux-only: CloudTraceMTLS seam
    public static func makeClient(profileId: UUID, timeout: TimeInterval) -> CloudTraceMTLSClient {
        UnavailableCloudTraceClient()
    }

    /// No identity is cached on Linux yet: nothing to forget.
    // @port-skip linux-only: CloudTraceMTLS seam
    public static func purgeIdentity(profileId: UUID) {}
}

public struct CloudTraceMTLSUnavailable: Error, CustomStringConvertible {
    // @port-skip linux-only: CloudTraceMTLS seam
    public var description: String { "cloud trace upload needs mTLS, which bromure-ac on Linux doesn't support yet" }
}

// @port-skip linux-only: CloudTraceMTLS seam
final class UnavailableCloudTraceClient: CloudTraceMTLSClient, @unchecked Sendable {
    // @port-skip linux-only: CloudTraceMTLS seam
    func send(_ req: URLRequest, completion: @escaping @Sendable (Data?, URLResponse?, Error?) -> Void) {
        DispatchQueue.global(qos: .utility).async { completion(nil, nil, CloudTraceMTLSUnavailable()) }
    }

    // @port-skip linux-only: CloudTraceMTLS seam
    func shutdown() {}
}
