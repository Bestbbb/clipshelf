import ClipShelfCore
import Foundation

// Synthetic data only. The benchmark always creates and removes its own temporary database.
struct Samples: Codable {
    let name: String
    let resultCount: Int
    let sampleCount: Int
    let p50Milliseconds: Double
    let p95Milliseconds: Double
    let maxMilliseconds: Double
    let samplesMilliseconds: [Double]

    init(name: String, resultCount: Int, times: [Double]) {
        let ordered = times.sorted()
        self.name = name; self.resultCount = resultCount; sampleCount = times.count
        p50Milliseconds = ordered[max(0, Int(ceil(Double(ordered.count) * 0.50)) - 1)]
        p95Milliseconds = ordered[max(0, Int(ceil(Double(ordered.count) * 0.95)) - 1)]
        maxMilliseconds = ordered.last!
        samplesMilliseconds = times
    }
}

struct Report: Codable {
    let generatedAt: Date
    let operatingSystem: String
    let processorCount: Int
    let physicalMemoryBytes: UInt64
    let fixtureVersion: Int
    let rows: Int
    let fixtureTextBytes: Int
    let fixtureRepresentationBytes: Int
    let populationMilliseconds: Double
    let firstConnectionOpenMilliseconds: Double
    let firstPageMilliseconds: Double
    let notes: [String]
    let measurements: [Samples]
}

enum BenchmarkError: Error { case invalidArguments, unexpectedResult(String) }

func measured<T>(_ body: () throws -> T) rethrows -> (T, Double) {
    let start = DispatchTime.now().uptimeNanoseconds
    let value = try body()
    let elapsed = DispatchTime.now().uptimeNanoseconds - start
    return (value, Double(elapsed) / 1_000_000)
}

func argument(_ key: String, default value: Int) throws -> Int {
    guard let index = CommandLine.arguments.firstIndex(of: key) else { return value }
    guard CommandLine.arguments.indices.contains(index + 1), let parsed = Int(CommandLine.arguments[index + 1]), parsed > 0 else {
        throw BenchmarkError.invalidArguments
    }
    return parsed
}

func fixtureID(_ index: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-4000-8000-%012llX", Int64(index)))!
}

func run() throws -> Report {
    let rows = try argument("--rows", default: 10_000)
    let iterations = try argument("--iterations", default: 100)
    guard (1_000...100_000).contains(rows), (10...1_000).contains(iterations) else { throw BenchmarkError.invalidArguments }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("clipshelf-benchmark-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let databaseURL = directory.appendingPathComponent("history.sqlite3")
    let epoch = Date(timeIntervalSinceReferenceDate: 800_000_000)
    let padding = String(repeating: "clipboard sample text 编辑器 片段\n", count: 20)
    var textBytes = 0, representationBytes = 0
    let (_, populationTime) = try measured {
        let store = try HistoryStore(databaseURL: databaseURL)
        for index in 0..<5 {
            _ = try store.createPinboard(name: "Fixture \(index)")
        }
        let boards = try store.pinboards()
        for index in 0..<rows {
            let category = index % 20
            var parts: [ClipboardPart] = []
            let text: String
            if category == 0 {
                text = "https://example.invalid/fixture/\(index)"
            } else if category == 1 || category == 2 {
                text = "截图 \(index)"
                let bytes = Data(repeating: UInt8(index % 251), count: 4_096)
                parts = [ClipboardPart(representations: [ClipboardRepresentation(typeIdentifier: "public.png", data: bytes)])]
            } else if category == 3 {
                text = "file:///synthetic-fixture/document-\(index).pdf"
                parts = [ClipboardPart(representations: [ClipboardRepresentation(typeIdentifier: "public.file-url", data: Data(text.utf8))])]
            } else {
                text = "条目 \(index)\n" + padding + (index % 997 == 0 ? " 稀有检索词 rare-needle" : "")
                if category == 4 {
                    parts = [ClipboardPart(representations: [ClipboardRepresentation(typeIdentifier: "public.html", data: Data(("<p>" + text + "</p>").utf8))])]
                }
            }
            let ocr = category == 1 ? "识别文字 OCR indexed screenshot \(index)" : nil
            let record = ClipboardRecord(id: fixtureID(index + 1), text: text,
                                         sourceApp: "Fixture App \(index % 5)", sourceBundleID: "test.fixture.app\(index % 5)",
                                         copiedAt: epoch.addingTimeInterval(Double(index)), parts: parts,
                                         renamedTitle: index % 13 == 0 ? "Renamed title \(index)" : nil,
                                         ocrText: ocr, pinboardID: index % 7 == 0 ? boards[index % boards.count].id : nil)
            _ = try store.create(record)
            textBytes += text.utf8.count + (ocr?.utf8.count ?? 0)
            representationBytes += parts.flatMap(\.representations).reduce(0) { $0 + $1.data.count }
        }
    }
    let (store, openTime) = try measured { try HistoryStore(databaseURL: databaseURL) }
    let (firstPage, firstPageTime) = try measured { try store.searchMetadata(HistoryQuery(limit: 300)) }
    guard firstPage.count == 300 else { throw BenchmarkError.unexpectedResult("first page") }
    let boards = try store.pinboards()
    let scenarios: [(String, HistoryQuery)] = [
        ("latest_300_metadata", HistoryQuery(limit: 300)),
        ("common_ascii", HistoryQuery(text: "clipboard", limit: 300)),
        ("common_chinese", HistoryQuery(text: "编辑器", limit: 300)),
        ("rare_mixed_language_full_scan", HistoryQuery(text: "稀有检索词 rare-needle", limit: 300)),
        ("absent_literal_full_scan", HistoryQuery(text: "absent_100%_' OR 1=1 --", limit: 300)),
        ("ocr_only", HistoryQuery(text: "OCR indexed screenshot", limit: 300)),
        ("type_source_date_board", HistoryQuery(kind: .text, sourceBundleID: "test.fixture.app4",
                                                copiedAfter: epoch.addingTimeInterval(Double(rows / 3)),
                                                copiedBefore: epoch.addingTimeInterval(Double(rows * 2 / 3)),
                                                pinboardIDs: [boards[4].id], limit: 300)),
    ]
    var measurements: [Samples] = []
    for (name, query) in scenarios {
        let expected = try store.searchMetadata(query).map(\.id)
        if name == "absent_literal_full_scan", !expected.isEmpty { throw BenchmarkError.unexpectedResult(name) }
        if name != "absent_literal_full_scan", expected.isEmpty { throw BenchmarkError.unexpectedResult(name) }
        for _ in 0..<5 { _ = try store.searchMetadata(query) }
        var times: [Double] = []
        for _ in 0..<iterations {
            let (result, time) = try measured { try store.searchMetadata(query) }
            guard result.map(\.id) == expected else { throw BenchmarkError.unexpectedResult(name) }
            times.append(time)
        }
        measurements.append(Samples(name: name, resultCount: expected.count, times: times))
    }
    var reopenTimes: [Double] = [], connectionTimes: [Double] = []
    for _ in 0..<iterations {
        let (reopened, connectionTime) = try measured { try HistoryStore(databaseURL: databaseURL) }
        let (page, time) = try measured { try reopened.searchMetadata(HistoryQuery(limit: 300)) }
        guard page.count == 300 else { throw BenchmarkError.unexpectedResult("reopened page") }
        reopenTimes.append(time)
        connectionTimes.append(connectionTime)
    }
    measurements.append(Samples(name: "first_300_after_connection_reopen", resultCount: 300, times: reopenTimes))
    measurements.append(Samples(name: "connection_reopen_including_schema_checks", resultCount: rows, times: connectionTimes))
    return Report(generatedAt: Date(), operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
                  processorCount: ProcessInfo.processInfo.processorCount, physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory,
                  fixtureVersion: 1, rows: rows, fixtureTextBytes: textBytes, fixtureRepresentationBytes: representationBytes,
                  populationMilliseconds: populationTime, firstConnectionOpenMilliseconds: openTime, firstPageMilliseconds: firstPageTime,
                  notes: ["Run with swift run -c release ClipShelfHistoryBenchmark --rows \(rows) --iterations \(iterations).",
                          "80% text (including 5% HTML), 5% links, 10% synthetic image bytes, 5% file URL references; 5 source apps, 5 pinboards, mixed Chinese/English and OCR fields.",
                          "Metadata queries do not load representation files. Fixture images measure storage metadata and are not rendering fixtures.",
                          "Five warmups per scenario; nearest-rank percentiles; all raw timing samples retained.",
                          "Database connection reopen is measured with the operating system file cache warm; this is not a cold disk benchmark.",
                          "Connection reopen includes HistoryStore initialization and schema checks; the separate first-page sample starts after initialization. Reopen samples have no additional warmup.",
                          "Measures synchronous core query and metadata decoding only. UI debounce, IME, rendering, animation, and end-to-end 100 ms acceptance are outside this measurement.",
                          "Only this benchmark's temporary database is touched; synthetic fixture and files are removed on exit."],
                  measurements: measurements)
}

do {
    let report = try run()
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(report)
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
} catch {
    FileHandle.standardError.write(Data("Benchmark failed: \(error)\n".utf8))
    exit(1)
}
