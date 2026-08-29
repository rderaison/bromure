import Foundation
import Testing
@testable import bromure_ac

@Suite("MLXEngine cache slot selection")
struct MLXEngineSlotTests {

    /// Distinct token streams: `ramp(n)` is 0..<n, `ramp(n, from: k)` shifts
    /// the values so two streams share no accidental prefix.
    private func ramp(_ n: Int, from: Int = 0) -> [Int] {
        Array(from..<(from + n))
    }

    @Test("No slots → fresh")
    func emptySlotSet() {
        #expect(MLXEngine.chooseSlot(prompt: ramp(100), slotTokens: []) == .fresh)
    }

    @Test("Exact continuation reuses its slot")
    func continuation() {
        // Next agent turn: the whole previous transcript plus a new message.
        let previous = ramp(10_000)
        let prompt = previous + ramp(300, from: 50_000)
        #expect(MLXEngine.chooseSlot(prompt: prompt, slotTokens: [previous]) == .reuse(0))
    }

    @Test("Small divergent tail (retokenization / repaired tool call) still reuses")
    func continuationWithDrift() {
        // 38k shared, 4k would be trimmed — within max(1024, prefix/4) = 9.5k.
        let slot = ramp(38_000) + ramp(4_000, from: 100_000)
        let prompt = ramp(38_000) + ramp(500, from: 200_000)
        #expect(MLXEngine.chooseSlot(prompt: prompt, slotTokens: [slot]) == .reuse(0))
    }

    @Test("Sidechain sharing only the system prefix gets a fresh slot")
    func sidechain() {
        // A 40k conversation vs a title-generation request that shares the 5k
        // system prompt: trimming would destroy 35k tokens of cache.
        let conversation = ramp(5_000) + ramp(35_000, from: 100_000)
        let sidechain = ramp(5_000) + ramp(200, from: 200_000)
        #expect(MLXEngine.chooseSlot(prompt: sidechain, slotTokens: [conversation]) == .fresh)
    }

    @Test("Deepest acceptable prefix wins")
    func deepestPrefixWins() {
        let short = ramp(2_000)
        let long = ramp(12_000)
        let prompt = ramp(12_000) + ramp(100, from: 90_000)
        #expect(MLXEngine.chooseSlot(prompt: prompt, slotTokens: [short, long]) == .reuse(1))
    }

    @Test("Empty slot is preferred over destroying a long conversation")
    func emptySlotOverDestruction() {
        let conversation = ramp(5_000) + ramp(35_000, from: 100_000)
        let sidechain = ramp(5_000) + ramp(200, from: 200_000)
        #expect(MLXEngine.chooseSlot(prompt: sidechain,
                                     slotTokens: [conversation, []]) == .reuse(1))
    }

    @Test("Unrelated non-empty slot is not reused")
    func unrelatedSlot() {
        // Shares nothing and would lose 2k > 1024 tokens — different conversation.
        let other = ramp(2_000, from: 100_000)
        #expect(MLXEngine.chooseSlot(prompt: ramp(500), slotTokens: [other]) == .fresh)
    }

    @Test("Loss boundary: exactly max(1024, prefix/4) reuses, one more does not")
    func lossBoundary() {
        let prefix = 8_000   // allowed loss = max(1024, 2000) = 2000
        let prompt = ramp(prefix) + ramp(100, from: 200_000)
        let atLimit = ramp(prefix) + ramp(2_000, from: 100_000)
        let overLimit = ramp(prefix) + ramp(2_001, from: 100_000)
        #expect(MLXEngine.chooseSlot(prompt: prompt, slotTokens: [atLimit]) == .reuse(0))
        #expect(MLXEngine.chooseSlot(prompt: prompt, slotTokens: [overLimit]) == .fresh)
    }

    @Test("Short prompts fall under the absolute floor")
    func absoluteFloor() {
        // Early in a conversation the shared prefix is small; losses under
        // 1024 tokens are always acceptable (cheap to re-prefill anyway).
        let slot = ramp(800) + ramp(1_000, from: 100_000)
        let prompt = ramp(800) + ramp(50, from: 200_000)
        #expect(MLXEngine.chooseSlot(prompt: prompt, slotTokens: [slot]) == .reuse(0))
    }

    @Test("Slot cap is clamped to a sane range")
    func slotCapSane() {
        #expect(MLXEngine.maxCacheSlots >= 1 && MLXEngine.maxCacheSlots <= 8)
    }
}

/// The post-generation ledger/cache reconcile — the guard that keeps a slot's
/// token ledger provably equal to what its cache actually contains. Hybrid
/// models (Qwen3-Next) carry MambaCache layers whose `offset` never advances;
/// reading `.first` there once truncated the ledger to empty every turn while
/// the cache kept the whole request's recurrent state, and the next request
/// reused that poisoned slot with no reset — the "model only answers
/// `<title/>`" bug (omp's title subrequest was the leftover state).
@Suite("MLXEngine slot ledger reconcile")
struct MLXEngineLedgerTests {

    @Test("Aligned cache keeps the slot — hybrid offsets read via max()")
    func hybridAligned() {
        // Layer 0 is a MambaCache reporting 0; the full-attention layers
        // report the true count. max() must be the reference, so the slot
        // (and its prefix reuse) survives.
        #expect(MLXEngine.reconcileLedger(tokenCount: 1_200,
                                          maxOffset: 1_200,
                                          allTrimmable: false) == .keep)
    }

    @Test("Lookahead overshoot on a trimmable cache rewinds the cache")
    func standardOvershoot() {
        #expect(MLXEngine.reconcileLedger(tokenCount: 1_200,
                                          maxOffset: 1_201,
                                          allTrimmable: true) == .trimCache(1))
    }

    @Test("Short cache on a trimmable model clamps the ledger")
    func standardShort() {
        #expect(MLXEngine.reconcileLedger(tokenCount: 1_200,
                                          maxOffset: 1_150,
                                          allTrimmable: true) == .clampLedger(1_150))
    }

    @Test("Overshoot on a non-rewindable (hybrid) cache drops the slot whole")
    func hybridOvershootDrops() {
        // The recurrent state already consumed the extra token and can't be
        // rewound — keeping ANY of it would poison the next continuation.
        #expect(MLXEngine.reconcileLedger(tokenCount: 1_200,
                                          maxOffset: 1_201,
                                          allTrimmable: false) == .dropSlot)
    }

    @Test("Pure-recurrent cache (offset never advances) drops rather than truncates")
    func pureMambaDrops() {
        // The old code clamped the ledger to 0 here and LEFT the cache — an
        // empty-ledger slot chooseSlot then deems 'always acceptable'. It must
        // drop the cache with the ledger.
        #expect(MLXEngine.reconcileLedger(tokenCount: 1_200,
                                          maxOffset: 0,
                                          allTrimmable: false) == .dropSlot)
    }
}
