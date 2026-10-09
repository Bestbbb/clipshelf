import ClipShelfCore
import Foundation
import ImageIO
import Vision

/// Local OCR and explicit-context lexical relevance. This is not Apple Intelligence,
/// does not capture the screen, and never fetches links or contacts a model provider.
@MainActor
final class LocalIntelligenceService {
    struct OCRRegion: Equatable, Sendable {
        let text: String
        /// Vision-normalized coordinates (0...1), with the origin at the lower left.
        let boundingBox: CGRect
        let confidence: Float
    }

    struct OCRResult: Equatable, Sendable {
        let text: String
        let regions: [OCRRegion]
        let recognitionLanguages: [String]
    }

    struct Suggestion: Equatable, Sendable {
        let recordID: UUID
        /// A relative lexical score, not a probability or a model confidence.
        let score: Double
        let matchedTerms: [String]
    }

    enum RecognitionError: LocalizedError {
        case invalidImage
        case unsupportedLanguages

        var errorDescription: String? {
            switch self {
            case .invalidImage: return "无法读取这份图片数据。"
            case .unsupportedLanguages: return "当前系统不支持所请求的文字识别语言。"
            }
        }
    }

    private var recognitionGeneration: UInt64 = 0
    private var recognitionTask: Task<OCRResult, Error>?
    private var recognitionWork: RecognitionWork?
    private var suggestionGeneration: UInt64 = 0
    private var suggestionTask: Task<[Suggestion], Error>?

    /// The newest request supersedes previous OCR work. Caller cancellation also
    /// cancels Vision, and a superseded result is never returned as current output.
    func recognizeText(
        in imageData: Data,
        recognitionLanguages: [String] = ["zh-Hans", "zh-Hant", "en-US"]
    ) async throws -> OCRResult {
        cancelRecognition()
        let generation = recognitionGeneration
        let work = RecognitionWork()
        let task = Task.detached(priority: .utility) {
            try Self.performRecognition(imageData, languages: recognitionLanguages, work: work)
        }
        recognitionTask = task
        recognitionWork = work
        defer {
            if recognitionGeneration == generation {
                recognitionTask = nil
                recognitionWork = nil
            }
        }
        return try await withTaskCancellationHandler {
            do {
                let result = try await task.value
                try Task.checkCancellation()
                guard generation == recognitionGeneration else { throw CancellationError() }
                return result
            } catch {
                if Task.isCancelled || task.isCancelled || generation != recognitionGeneration {
                    throw CancellationError()
                }
                throw error
            }
        } onCancel: {
            task.cancel()
            work.cancel()
        }
    }

    func cancelRecognition() {
        recognitionGeneration &+= 1
        recognitionTask?.cancel()
        recognitionWork?.cancel()
        recognitionTask = nil
        recognitionWork = nil
    }

    /// Only user-provided context is inspected. Empty or unrelated context yields
    /// no suggestions instead of silently treating recent items as relevant.
    func rankedSuggestions(
        contextString: String,
        records: [ClipboardRecord],
        limit: Int = 10
    ) async throws -> [Suggestion] {
        cancelSuggestions()
        let generation = suggestionGeneration
        let task = Task.detached(priority: .userInitiated) {
            try Self.rank(contextString: contextString, records: records, limit: limit)
        }
        suggestionTask = task
        defer {
            if generation == suggestionGeneration { suggestionTask = nil }
        }
        return try await withTaskCancellationHandler {
            let result = try await task.value
            try Task.checkCancellation()
            guard generation == suggestionGeneration else { throw CancellationError() }
            return result
        } onCancel: {
            task.cancel()
        }
    }

    func suggestions(
        contextString: String,
        records: [ClipboardRecord],
        limit: Int = 10
    ) async throws -> [UUID] {
        try await rankedSuggestions(contextString: contextString, records: records, limit: limit)
            .map(\.recordID)
    }

    func cancelSuggestions() {
        suggestionGeneration &+= 1
        suggestionTask?.cancel()
        suggestionTask = nil
    }

    nonisolated private static func performRecognition(
        _ imageData: Data,
        languages: [String],
        work: RecognitionWork
    ) throws -> OCRResult {
        try Task.checkCancellation()
        guard !imageData.isEmpty,
              let source = CGImageSourceCreateWithData(imageData as CFData, nil),
              CGImageSourceGetCount(source) > 0 else { throw RecognitionError.invalidImage }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        let supported = Set(try request.supportedRecognitionLanguages())
        let availableLanguages = languages.filter { supported.contains($0) }
        if !languages.isEmpty {
            guard !availableLanguages.isEmpty else { throw RecognitionError.unsupportedLanguages }
            request.recognitionLanguages = availableLanguages
        }
        guard work.install(request) else { throw CancellationError() }
        defer { work.release() }
        try Task.checkCancellation()
        try VNImageRequestHandler(data: imageData, options: [:]).perform([request])
        try Task.checkCancellation()

        let regions = (request.results ?? []).compactMap { observation -> OCRRegion? in
            guard let candidate = observation.topCandidates(1).first,
                  !candidate.string.isEmpty else { return nil }
            return OCRRegion(text: candidate.string, boundingBox: observation.boundingBox,
                             confidence: candidate.confidence)
        }
        return OCRResult(text: regions.map(\.text).joined(separator: "\n"),
                         regions: regions, recognitionLanguages: request.recognitionLanguages)
    }

    private struct IndexedRecord {
        let record: ClipboardRecord
        let bodyTerms: Set<String>
        let sourceTerms: Set<String>
        let normalizedBody: String
        let inputIndex: Int
    }

    nonisolated private static func rank(
        contextString: String,
        records: [ClipboardRecord],
        limit: Int
    ) throws -> [Suggestion] {
        try Task.checkCancellation()
        guard limit > 0 else { return [] }
        let normalizedContext = normalize(String(contextString.prefix(8_192)))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let query = Set(terms(in: normalizedContext).sorted().prefix(128))
        guard !query.isEmpty else { return [] }

        var indexed: [IndexedRecord] = []
        var frequencies: [String: Int] = [:]
        for (offset, record) in records.enumerated() {
            if offset.isMultiple(of: 64) { try Task.checkCancellation() }
            // Bound per-record work; snippets remain unchanged in storage.
            let normalizedBody = normalize(String(record.text.prefix(16_384)))
            let bodyTerms = terms(in: normalizedBody).intersection(query)
            let sourceTerms = terms(in: normalize(record.sourceApp ?? "")).intersection(query)
            let matches = bodyTerms.union(sourceTerms)
            guard !matches.isEmpty else { continue }
            for term in matches { frequencies[term, default: 0] += 1 }
            indexed.append(IndexedRecord(record: record, bodyTerms: bodyTerms,
                                         sourceTerms: sourceTerms, normalizedBody: normalizedBody,
                                         inputIndex: offset))
        }

        var scored: [(suggestion: Suggestion, copiedAt: Date, inputIndex: Int)] = []
        for (offset, item) in indexed.enumerated() {
            if offset.isMultiple(of: 64) { try Task.checkCancellation() }
            let matches = item.bodyTerms.union(item.sourceTerms).sorted()
            var score = 2 * Double(matches.count) / Double(query.count)
            for term in matches {
                let rarity = log(1 + Double(records.count + 1) / Double((frequencies[term] ?? 0) + 1))
                score += rarity * (item.bodyTerms.contains(term) ? 1 : 0.3)
            }
            if normalizedContext.count > 1, item.normalizedBody.contains(normalizedContext) {
                score += 2
            }
            scored.append((Suggestion(recordID: item.record.id, score: score, matchedTerms: matches),
                           item.record.copiedAt, item.inputIndex))
        }
        scored.sort {
            if $0.suggestion.score != $1.suggestion.score { return $0.suggestion.score > $1.suggestion.score }
            if $0.copiedAt != $1.copiedAt { return $0.copiedAt > $1.copiedAt }
            return $0.inputIndex < $1.inputIndex
        }
        try Task.checkCancellation()
        var seen: Set<UUID> = []
        var results: [Suggestion] = []
        for item in scored where seen.insert(item.suggestion.recordID).inserted {
            results.append(item.suggestion)
            if results.count == limit { break }
        }
        return results
    }

    nonisolated private static func normalize(_ string: String) -> String {
        string.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                       locale: Locale(identifier: "en_US_POSIX")).lowercased()
    }

    /// Word terms plus adjacent Han pairs keep Chinese substring queries useful
    /// without claiming semantic understanding or shipping an external model.
    nonisolated private static func terms(in string: String) -> Set<String> {
        let stopWords: Set<String> = ["the", "and", "for", "with", "this", "that", "from", "into",
                                      "are", "was", "were", "your", "you", "our", "of", "to", "in",
                                      "on", "an", "is", "it", "as", "at", "be", "a"]
        var result: Set<String> = []
        for word in string.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "_" }) {
            let token = String(word)
            if !stopWords.contains(token) { result.insert(token) }
            var hanRun: [Character] = []
            func flushHanRun() {
                if hanRun.count > 1 {
                    for index in 0..<(hanRun.count - 1) {
                        result.insert(String(hanRun[index...index + 1]))
                    }
                } else if let only = hanRun.first {
                    result.insert(String(only))
                }
                hanRun.removeAll(keepingCapacity: true)
            }
            for character in word {
                if let scalar = character.unicodeScalars.first,
                   (0x3400...0x4DBF).contains(scalar.value)
                    || (0x4E00...0x9FFF).contains(scalar.value)
                    || (0x20000...0x323AF).contains(scalar.value) {
                    hanRun.append(character)
                } else {
                    flushHanRun()
                }
            }
            flushHanRun()
        }
        return result
    }
}

/// Cancellation may arrive before Vision has been configured or while perform is
/// running. The latch prevents a late install from escaping cancellation.
private final class RecognitionWork: @unchecked Sendable {
    private let lock = NSLock()
    private var request: VNRecognizeTextRequest?
    private var cancelled = false

    func install(_ request: VNRecognizeTextRequest) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else { return false }
        self.request = request
        return true
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let current = request
        lock.unlock()
        current?.cancel()
    }

    func release() {
        lock.lock()
        request = nil
        lock.unlock()
    }
}
