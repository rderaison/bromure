import Foundation
import Testing

/// The TestFlight archive runs package plug-ins without a trust prompt, so
/// it may build only reviewed, pinned package revisions. Finding:
/// "TestFlight archives execute unvalidated package build code from
/// floating dependencies" (CWE-829).
@Suite("iOS release package pins")
struct IOSReleasePackagePinsTests {
    static let top = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    static func src(_ rel: String) throws -> String {
        try String(contentsOf: top.appendingPathComponent(rel), encoding: .utf8)
    }

    @Test("The committed Package.resolved pins every declared package inside its requirement")
    func pinsCoverDeclaredPackages() throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["python3", "-I", Self.top.appendingPathComponent("scripts/verify-ios-packages.py").path]
        let err = Pipe()
        p.standardError = err
        p.standardOutput = Pipe()
        guard (try? p.run()) != nil else { return }   // no python3 on this host
        p.waitUntilExit()
        let msg = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(p.terminationStatus == 0, "\(msg)")
    }

    @Test("Both archives build only the verified pins; macro validation stays on")
    func archivesUsePins() throws {
        let j = try Self.src("Jenkinsfile.ios.testflight")
        #expect(!j.contains("-skipMacroValidation"))
        let archives = j.components(separatedBy: "xcodebuild archive \\\n").dropFirst()
        #expect(archives.count == 2)
        for a in archives {
            let call = a.prefix(800)
            #expect(call.contains("-disableAutomaticPackageResolution"))
            #expect(call.contains("-clonedSourcePackagesDirPath \"$SPM_DIR\""))
        }
        // The pins are fetched and checked before the credentialed archive.
        let resolve = try #require(j.range(of: "stage('Resolve packages')"))
        let archive = try #require(j.range(of: "stage('Archive')"))
        #expect(resolve.lowerBound < archive.lowerBound)
        let stage = j[resolve.lowerBound..<archive.lowerBound]
        #expect(!stage.contains("withCredentials"))
        #expect(stage.contains("python3 -I scripts/verify-ios-packages.py \"$SPM_DIR\""))
        #expect(stage.contains("-disableAutomaticPackageResolution"))
        // And the pin file is tracked despite the global Package.resolved ignore.
        #expect(try Self.src(".gitignore").contains(
            "!ios/BromureRemote/BromureRemote.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"))
    }
}
