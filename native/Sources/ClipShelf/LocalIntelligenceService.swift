import ClipShelfLocalization
import ClipShelfCore
import CryptoKit
import Foundation
import ImageIO
import Vision

/// Local OCR and explicit-context lexical relevance. This is not Apple Intelligence,
/// does not capture the screen, and never fetches links or contacts a model provider.
@MainActor
final class LocalIntelligenceService {
    nonisolated static let defaultRecognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
    nonisolated static let ocrEngineIdentifier = "Apple Vision VNRecognizeTextRequest"
    nonisolated static var ocrEngineRevision: Int { VNRecognizeTextRequest.currentRevision }
    nonisolated static var ocrEngineVersion: String { ProcessInfo.processInfo.operatingSystemVersionString }

    struct OCRSpan: Equatable, Codable, Sendable {
        let utf16Location: Int
        let utf16Length: Int
        let boundingBox: CGRect
    }
    struct OCRRegion: Equatable, Codable, Sendable {
        let text: String
        /// Coordinates refer to the EXIF-oriented image, with lower-left origin.
        let boundingBox: CGRect
        let confidence: Float
        var spans: [OCRSpan] = []
    }
    struct OCRResult: Equatable, Codable, Sendable {
        let text: String
        let regions: [OCRRegion]
        let recognitionLanguages: [String]
        let sourceImageDigest: String
        let engineIdentifier: String
        let engineRevision: Int
        let engineVersion: String
        let orientedPixelSize: CGSize
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
        case imageTooLarge

        var errorDescription: String? {
            switch self {
            case .invalidImage: return L10n.text("无法读取这份图片数据。")
            case .unsupportedLanguages: return L10n.text("当前系统不支持所请求的文字识别语言。")
            case .imageTooLarge: return L10n.text("图片尺寸超出本机识别上限，原图仍保留。")
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
        recognitionLanguages: [String] = LocalIntelligenceService.defaultRecognitionLanguages
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
        let image = try decodedImage(in: imageData)
        let request = VNRecognizeTextRequest()
        request.revision = Self.ocrEngineRevision
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
        try VNImageRequestHandler(cgImage: image, orientation: .up, options: [:]).perform([request])
        try Task.checkCancellation()

        var remainingSpans = 20_000
        let regions = (request.results ?? []).compactMap { observation -> OCRRegion? in
            guard let candidate = observation.topCandidates(1).first,
                  !candidate.string.isEmpty else { return nil }
            var spans: [OCRSpan] = []
            // Vision may return word-level bounds for individual characters at
            // accurate recognition level; retain its actual bounds, never invent them.
            candidate.string.enumerateSubstrings(in: candidate.string.startIndex..<candidate.string.endIndex,
                                                 options: .byComposedCharacterSequences) { _, range, _, stop in
                guard remainingSpans > 0 else { stop = true; return }
                if let rectangle = try? candidate.boundingBox(for: range),
                   rectangle.boundingBox.width > 0, rectangle.boundingBox.height > 0 {
                    let utf16 = NSRange(range, in: candidate.string)
                    spans.append(OCRSpan(utf16Location: utf16.location, utf16Length: utf16.length,
                                         boundingBox: rectangle.boundingBox))
                    remainingSpans -= 1
                }
            }
            return OCRRegion(text: candidate.string, boundingBox: observation.boundingBox,
                             confidence: candidate.confidence, spans: spans)
        }
        try Task.checkCancellation()
        return OCRResult(text: regions.map(\.text).joined(separator: "\n"),
                         regions: regions, recognitionLanguages: request.recognitionLanguages,
                         sourceImageDigest: Self.imageDigest(imageData), engineIdentifier: Self.ocrEngineIdentifier,
                         engineRevision: request.revision, engineVersion: Self.ocrEngineVersion,
                         orientedPixelSize: CGSize(width: image.width, height: image.height))
    }

    nonisolated static func imageDigest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Shared by preview and recognition so EXIF rotations/mirroring have one
    /// coordinate space. It creates a display raster; original bytes are untouched.
    nonisolated static func decodedImage(in data: Data) throws -> CGImage {
        guard !data.isEmpty, let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int, width > 0, height > 0 else {
            throw RecognitionError.invalidImage
        }
        guard width <= 32_768, height <= 32_768, Int64(width) * Int64(height) <= 100_000_000 else {
            throw RecognitionError.imageTooLarge
        }
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: min(4_096, max(width, height)),
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary) else { throw RecognitionError.invalidImage }
        return image
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
