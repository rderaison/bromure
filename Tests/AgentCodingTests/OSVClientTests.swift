import Foundation
import Testing
@testable import bromure_ac

/// Pure-logic coverage for `OSVClient.Severity`: the CVSS v3.1 base-
/// score calculator, the OSV→severity mapping (including the recent
/// fix where vector-only advisories no longer collapse to `.unknown`),
/// and the `rank` ordering used by the block thresholds. No network.
@Suite("OSV severity logic")
struct OSVClientTests {

    private typealias Severity = OSVClient.Severity

    /// CVSS roundup yields exact 1-decimal values; compare with a tiny
    /// epsilon to be safe against binary-float representation.
    private func approx(_ a: Double?, _ b: Double, _ comment: Comment) {
        guard let a else { Issue.record("expected \(b), got nil — \(comment)"); return }
        #expect(abs(a - b) < 0.001, comment)
    }

    // MARK: - cvssBaseScore

    @Test("Worst-case AV:N vector scores 9.8 (critical)")
    func cvssCritical98() {
        approx(Severity.cvssBaseScore(fromVector: "CVSS:3.1/AV:N/AC:L/PR:N/UI:N/S:U/C:H/I:H/A:H"),
               9.8, "all-high network vector")
    }

    @Test("Confidentiality-only network vector scores 7.5 (high)")
    func cvssHigh75() {
        approx(Severity.cvssBaseScore(fromVector: "CVSS:3.1/AV:N/AC:L/PR:N/UI:N/S:U/C:H/I:N/A:N"),
               7.5, "C:H only")
    }

    @Test("Scope-changed vector applies the 1.08 multiplier (9.9)")
    func cvssScopeChanged() {
        approx(Severity.cvssBaseScore(fromVector: "CVSS:3.1/AV:N/AC:L/PR:L/UI:N/S:C/C:H/I:H/A:H"),
               9.9, "S:C raises the ceiling and changes the PR weight")
    }

    @Test("Low-impact physical vector scores in the low band (1.6)")
    func cvssLow() {
        approx(Severity.cvssBaseScore(fromVector: "CVSS:3.1/AV:P/AC:H/PR:H/UI:R/S:U/C:L/I:N/A:N"),
               1.6, "physical, hard, privileged")
    }

    @Test("No-impact vector scores 0")
    func cvssZeroImpact() {
        approx(Severity.cvssBaseScore(fromVector: "CVSS:3.1/AV:N/AC:L/PR:N/UI:N/S:U/C:N/I:N/A:N"),
               0.0, "C:N/I:N/A:N → impact <= 0")
    }

    @Test("CVSS v3.0 prefix is also accepted")
    func cvss30Accepted() {
        approx(Severity.cvssBaseScore(fromVector: "CVSS:3.0/AV:N/AC:L/PR:N/UI:N/S:U/C:H/I:H/A:H"),
               9.8, "v3.0 uses the same formula")
    }

    @Test("Non-v3 vectors return nil")
    func cvssNonV3Nil() {
        #expect(Severity.cvssBaseScore(fromVector: "CVSS:2.0/AV:N/AC:L/Au:N/C:C/I:C/A:C") == nil)
        // A bare v4-style string lacks the v3 metrics → nil.
        #expect(Severity.cvssBaseScore(fromVector: "CVSS:4.0/AV:N/AC:L/AT:N/PR:N") == nil)
    }

    @Test("Malformed / incomplete vectors return nil")
    func cvssMalformedNil() {
        #expect(Severity.cvssBaseScore(fromVector: "garbage") == nil)
        #expect(Severity.cvssBaseScore(fromVector: "") == nil)
        // Missing required metrics (no AC/PR/…) → nil.
        #expect(Severity.cvssBaseScore(fromVector: "CVSS:3.1/AV:N") == nil)
        // Unknown metric value → nil.
        #expect(Severity.cvssBaseScore(fromVector: "CVSS:3.1/AV:Z/AC:L/PR:N/UI:N/S:U/C:H/I:H/A:H") == nil)
    }

    // MARK: - fromOSV mapping

    @Test("GHSA label wins outright when present")
    func ghsaLabelWins() {
        #expect(Severity.fromOSV(nil, ghsaSeverityLabel: "LOW") == .low)
        #expect(Severity.fromOSV(nil, ghsaSeverityLabel: "MODERATE") == .medium)
        #expect(Severity.fromOSV(nil, ghsaSeverityLabel: "MEDIUM") == .medium)
        #expect(Severity.fromOSV(nil, ghsaSeverityLabel: "HIGH") == .high)
        #expect(Severity.fromOSV(nil, ghsaSeverityLabel: "CRITICAL") == .critical)
        // Case-insensitive.
        #expect(Severity.fromOSV(nil, ghsaSeverityLabel: "critical") == .critical)
    }

    @Test("Vector-only advisory (no GHSA label) maps via CVSS base score — the recent fix")
    func vectorOnlyMaps() {
        // The regression: a `score` carrying a CVSS *vector* string used
        // to leave maxScore at 0 → `.unknown` (rank −1, never blocked).
        let sev: [[String: Any]] = [
            ["type": "CVSS_V3",
             "score": "CVSS:3.1/AV:N/AC:L/PR:N/UI:N/S:U/C:H/I:H/A:H"],
        ]
        #expect(Severity.fromOSV(sev, ghsaSeverityLabel: nil) == .critical)
    }

    @Test("Numeric score string and Double score both rank")
    func numericScores() {
        #expect(Severity.fromOSV([["score": 5.0]], ghsaSeverityLabel: nil) == .medium)
        #expect(Severity.fromOSV([["score": "8.1"]], ghsaSeverityLabel: nil) == .high)
        #expect(Severity.fromOSV([["score": 9.5]], ghsaSeverityLabel: nil) == .critical)
        #expect(Severity.fromOSV([["score": 2.0]], ghsaSeverityLabel: nil) == .low)
    }

    @Test("Highest score across multiple severity entries wins")
    func highestWins() {
        let sev: [[String: Any]] = [
            ["score": 3.0],
            ["score": "CVSS:3.1/AV:N/AC:L/PR:N/UI:N/S:U/C:H/I:H/A:H"],  // 9.8
            ["score": 5.0],
        ]
        #expect(Severity.fromOSV(sev, ghsaSeverityLabel: nil) == .critical)
    }

    @Test("Nil / empty severities with no label is unknown")
    func unknownWhenNothing() {
        #expect(Severity.fromOSV(nil, ghsaSeverityLabel: nil) == .unknown)
        #expect(Severity.fromOSV([], ghsaSeverityLabel: nil) == .unknown)
        // An unrecognised label with no parsable score falls through to unknown.
        #expect(Severity.fromOSV(nil, ghsaSeverityLabel: "WHATEVER") == .unknown)
    }

    // MARK: - rank ordering

    @Test("rank orders critical > high > medium > low > unknown")
    func rankOrdering() {
        #expect(Severity.critical.rank > Severity.high.rank)
        #expect(Severity.high.rank > Severity.medium.rank)
        #expect(Severity.medium.rank > Severity.low.rank)
        #expect(Severity.low.rank > Severity.unknown.rank)
        // unknown is below every real level (best-effort only).
        #expect(Severity.unknown.rank == -1)
        #expect(Severity.low.rank == 0)
    }

    // MARK: - ecosystem mapping

    @Test("osvEcosystem maps internal ids to OSV's case-sensitive names")
    func ecosystemMapping() {
        #expect(OSVClient.osvEcosystem("npm") == "npm")
        #expect(OSVClient.osvEcosystem("pypi") == "PyPI")
        #expect(OSVClient.osvEcosystem("cargo") == "crates.io")
        #expect(OSVClient.osvEcosystem("rubygems") == "RubyGems")
        #expect(OSVClient.osvEcosystem("maven") == "Maven")
        #expect(OSVClient.osvEcosystem("nuget") == "NuGet")
        #expect(OSVClient.osvEcosystem("go") == "Go")
        #expect(OSVClient.osvEcosystem("packagist") == "Packagist")
        #expect(OSVClient.osvEcosystem("brainfuck") == nil)
    }
}
