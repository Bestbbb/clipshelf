import AppKit
import ClipShelfCore
@testable import ClipShelf
import XCTest

@MainActor
final class ContextSuggestionServiceTests: XCTestCase {
    private var syntheticTarget: PasteCoordinator.Target { .init(application: .current, window: nil, focusedElement: nil) }

    func testUnavailableModelAndPauseNeverCaptureOrGenerate() async throws {
        var captures = 0, generations = 0
        let service = ContextSuggestionService(availability: { .unavailable("Synthetic unavailable model") }, capture: { _, _ in
            captures += 1; return "never read"
        }, generate: { _, _ in generations += 1; return [] })
        let records = try metadata([ClipboardRecord(text: "Synthetic record")])
        do {
            _ = try await service.request(target: syntheticTarget, records: records, excludedBundleIDs: [])
            XCTFail("Unavailable model must fail before capture")
        } catch { XCTAssertEqual(error as? ContextSuggestionService.SuggestionError, .unavailable("Synthetic unavailable model")) }
        do {
            _ = try await service.request(target: syntheticTarget, records: records, excludedBundleIDs: [], captureAllowed: false)
            XCTFail("Pause must fail before capture")
        } catch { XCTAssertEqual(error as? ContextSuggestionService.SuggestionError, .paused) }
        XCTAssertEqual(captures, 0)
        XCTAssertEqual(generations, 0)
    }

    func testCaptureRefusalNeverFeedsTheModel() async throws {
        for refusal in [ContextSuggestionService.SuggestionError.secureField, .excludedApplication, .screenRecordingRequired, .targetChanged] {
            var generated = false
            let service = ContextSuggestionService(availability: { .available }, capture: { _, _ in throw refusal }, generate: { _, _ in generated = true; return [] })
            do {
                _ = try await service.request(target: syntheticTarget, records: try metadata([ClipboardRecord(text: "Synthetic")]), excludedBundleIDs: [])
                XCTFail("Capture refusal should fail")
            } catch { XCTAssertEqual(error as? ContextSuggestionService.SuggestionError, refusal) }
            XCTAssertFalse(generated)
        }
    }

    func testExcludedRecordsAreRemovedAndContextAndCandidatesAreBounded() async throws {
        let blocked = ClipboardRecord(text: "do not disclose", sourceBundleID: "test.excluded")
        let records = try metadata([blocked] + (0..<80).map { ClipboardRecord(text: "Synthetic \($0) " + String(repeating: "word ", count: 500)) })
        var generated = false
        let service = ContextSuggestionService(availability: { .available }, capture: { _, _ in String(repeating: "Synthetic window ", count: 500) }, generate: { context, candidates in
            generated = true
            XCTAssertLessThanOrEqual(context.count, 1_200)
            XCTAssertLessThanOrEqual(candidates.count, 12)
            XCTAssertFalse(candidates.contains { $0.id == blocked.id })
            XCTAssertTrue(candidates.allSatisfy { $0.text.count <= 180 && $0.title.count <= 48 })
            return candidates.prefix(2).map { .init(id: $0.id, reason: "Synthetic model reason") }
        })
        let result = try await service.request(target: syntheticTarget, records: records, excludedBundleIDs: ["test.excluded"])
        XCTAssertTrue(generated)
        XCTAssertEqual(result.suggestions.count, 2)
        XCTAssertLessThanOrEqual(result.candidateCount, 12)
    }

    func testFinalSuggestionsRequireModelAndRejectInventedOrDuplicateIDs() async throws {
        let record = ClipboardRecord(text: "Synthetic address 123")
        let service = ContextSuggestionService(availability: { .available }, capture: { _, _ in "Fill address" }, generate: { _, _ in
            [.init(id: UUID(), reason: "Invented"), .init(id: record.id, reason: "Contains address\n" + String(repeating: "x", count: 500)), .init(id: record.id, reason: "Duplicate")]
        })
        let result = try await service.request(target: syntheticTarget, records: try metadata([record]), excludedBundleIDs: [])
        XCTAssertEqual(result.suggestions.map(\.id), [record.id])
        XCTAssertEqual(result.suggestions[0].reason.count, 160)
        XCTAssertFalse(result.suggestions[0].reason.contains("\n"))
        let failing = ContextSuggestionService(availability: { .available }, capture: { _, _ in "Synthetic address" }, generate: { _, _ in throw NSError(domain: "Synthetic model failure", code: 1) })
        do {
            _ = try await failing.request(target: syntheticTarget, records: try metadata([record]), excludedBundleIDs: [])
            XCTFail("Model failure must not silently return lexical rankings")
        } catch { XCTAssertEqual(error as? ContextSuggestionService.SuggestionError, .modelFailed) }
    }

    func testCancellationDiscardsCapturedContextBeforeModelInvocation() async throws {
        var continuation: CheckedContinuation<String, Never>?
        var modelInvoked = false
        let service = ContextSuggestionService(availability: { .available }, capture: { _, _ in
            await withCheckedContinuation { continuation = $0 }
        }, generate: { _, _ in modelInvoked = true; return [] })
        let records = try metadata([ClipboardRecord(text: "Synthetic")])
        let target = syntheticTarget
        let work = Task { try await service.request(target: target, records: records, excludedBundleIDs: []) }
        for _ in 0..<100 where continuation == nil { await Task.yield() }
        XCTAssertNotNil(continuation)
        service.cancel()
        continuation?.resume(returning: "Synthetic sensitive context")
        do { _ = try await work.value; XCTFail("Cancelled generation must not publish") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(modelInvoked)
    }

    func testEmptyHistoryAndEmptyContextDoNotInventSuggestions() async throws {
        var captures = 0, generations = 0
        let service = ContextSuggestionService(availability: { .available }, capture: { _, _ in captures += 1; return "  " }, generate: { _, _ in generations += 1; return [] })
        do { _ = try await service.request(target: syntheticTarget, records: [], excludedBundleIDs: []); XCTFail("Empty history") }
        catch { XCTAssertEqual(error as? ContextSuggestionService.SuggestionError, .noCandidates) }
        XCTAssertEqual(captures, 0)
        do { _ = try await service.request(target: syntheticTarget, records: try metadata([ClipboardRecord(text: "Synthetic")]), excludedBundleIDs: []); XCTFail("Empty context") }
        catch { XCTAssertEqual(error as? ContextSuggestionService.SuggestionError, .noContext) }
        XCTAssertEqual(captures, 1)
        XCTAssertEqual(generations, 0)
    }

    func testSystemModelSyntheticSmokeWhenAvailable() async throws {
        guard case .available = ContextSuggestionService.availability else {
            throw XCTSkip("Apple Intelligence is unavailable on this test machine; no real-model claim.")
        }
        let candidate = ContextSuggestionService.Candidate(id: UUID(), title: "Example address", text: "123 Example Street, Example City")
        let results = try await ContextSuggestionService.generateWithSystemModel(context: "A synthetic contact form asks for a street address.", candidates: [candidate])
        XCTAssertTrue(results.allSatisfy { $0.id == candidate.id })
        XCTAssertLessThanOrEqual(results.count, 5)
    }

    private func metadata(_ records: [ClipboardRecord]) throws -> [ClipboardRecordMetadata] {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SuggestionTests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try HistoryStore(databaseURL: directory.appendingPathComponent("synthetic.sqlite3"))
        for record in records { _ = try store.create(record) }
        return try store.searchMetadata(HistoryQuery(limit: 1_000))
    }
}
