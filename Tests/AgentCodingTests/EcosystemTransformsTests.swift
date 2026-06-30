import Foundation
import Testing
@testable import bromure_ac

/// Pure filename / timestamp helpers used by the age-gate metadata
/// transforms. No HTTP, no clock.
@Suite("Ecosystem transform helpers")
struct EcosystemTransformsTests {

    // MARK: - PyPI filename → version

    @Test("sdist filename version is taken after the last hyphen")
    func sdistVersion() {
        #expect(EcosystemTransforms.pypiVersionFromFilename("requests-2.31.0.tar.gz") == "2.31.0")
        #expect(EcosystemTransforms.pypiVersionFromFilename("Flask-3.0.0.tar.gz") == "3.0.0")
        #expect(EcosystemTransforms.pypiVersionFromFilename("foo-1.2.zip") == "1.2")
    }

    @Test("sdist with a hyphenated package name splits on the LAST hyphen")
    func sdistHyphenName() {
        #expect(EcosystemTransforms.pypiVersionFromFilename(
            "typing-extensions-4.9.0.tar.gz") == "4.9.0")
    }

    @Test("wheel filename version is the second hyphen-separated segment")
    func wheelVersion() {
        #expect(EcosystemTransforms.pypiVersionFromFilename(
            "numpy-1.26.0-cp311-cp311-macosx.whl") == "1.26.0")
        #expect(EcosystemTransforms.pypiVersionFromFilename(
            "charset_normalizer-3.3.2-cp312-cp312-win_amd64.whl") == "3.3.2")
    }

    @Test("Unrecognised extension yields nil")
    func unknownExtension() {
        #expect(EcosystemTransforms.pypiVersionFromFilename("readme.txt") == nil)
        #expect(EcosystemTransforms.pypiVersionFromFilename("requests-2.31.0") == nil)
    }

    @Test("Malformed wheel with too few segments yields nil")
    func malformedWheel() {
        #expect(EcosystemTransforms.pypiVersionFromFilename("foo.whl") == nil)
    }

    // MARK: - PyPIMetadataClient.earliestUploadTime

    private func body(_ json: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: json)
    }

    @Test("earliestUploadTime picks the earliest upload across urls[]")
    func earliestUpload() {
        let data = body([
            "urls": [
                ["upload_time_iso_8601": "2023-06-01T12:00:00.000000Z"],
                ["upload_time_iso_8601": "2023-05-15T08:30:00.000000Z"],
                ["upload_time_iso_8601": "2023-07-20T00:00:00.000000Z"],
            ],
        ])
        let earliest = PyPIMetadataClient.earliestUploadTime(in: data)
        let expected = ISO8601DateFormatter().date(from: "2023-05-15T08:30:00Z")
        #expect(earliest != nil)
        if let earliest, let expected {
            #expect(abs(earliest.timeIntervalSince(expected)) < 1.0)
        }
    }

    @Test("earliestUploadTime falls back to upload_time when iso field absent")
    func earliestUploadFallback() {
        // The fallback reads the `upload_time` field, but still parses it as
        // ISO-8601 — which requires a timezone designator. (A bare, tz-less
        // "2022-01-01T00:00:00" is rejected by both formatters → nil.)
        let data = body([
            "urls": [
                ["upload_time": "2022-01-01T00:00:00Z"],
            ],
        ])
        let earliest = PyPIMetadataClient.earliestUploadTime(in: data)
        #expect(earliest != nil)
    }

    @Test("earliestUploadTime returns nil when there is no urls array")
    func earliestUploadNoUrls() {
        #expect(PyPIMetadataClient.earliestUploadTime(in: body(["info": ["version": "1.0"]])) == nil)
        #expect(PyPIMetadataClient.earliestUploadTime(in: Data("not json".utf8)) == nil)
    }

    @Test("earliestUploadTime ignores entries with unparseable timestamps")
    func earliestUploadIgnoresJunk() {
        let data = body([
            "urls": [
                ["upload_time_iso_8601": "not-a-date"],
                ["upload_time_iso_8601": "2021-03-03T03:03:03.000000Z"],
            ],
        ])
        let earliest = PyPIMetadataClient.earliestUploadTime(in: data)
        let expected = ISO8601DateFormatter().date(from: "2021-03-03T03:03:03Z")
        #expect(earliest != nil)
        if let earliest, let expected {
            #expect(abs(earliest.timeIntervalSince(expected)) < 1.0)
        }
    }
}
