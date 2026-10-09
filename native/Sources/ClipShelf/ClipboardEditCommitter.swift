import ClipShelfCore
import Foundation

/// Image OCR is part of the edit's one revision, so derived indexing cannot
/// invalidate the newly returned preview reference or its Undo capability.
@MainActor
enum ClipboardEditCommitter {
    typealias Recognizer = (Data) async throws -> LocalIntelligenceService.OCRResult

    static func commit(_ edited: ClipboardRecord, snapshot: ClipboardEditSnapshot,
                       store: HistoryStore, cache: OCRDerivedCache,
                       recognize: Recognizer? = nil) async throws -> HistorySelectionEditUndo {
        let originalImage = OCRDerivedCache.imageData(in: snapshot.record)
        let newImage = OCRDerivedCache.imageData(in: edited)
        let imageChanged = originalImage != newImage
        var submitted = edited
        var recognition: LocalIntelligenceService.OCRResult?
        if imageChanged {
            submitted.ocrText = nil
            if let newImage {
                do {
                    let result: LocalIntelligenceService.OCRResult
                    if let recognize { result = try await recognize(newImage) }
                    else { result = try await LocalIntelligenceService().recognizeText(in: newImage) }
                    guard result.sourceImageDigest == LocalIntelligenceService.imageDigest(newImage) else {
                        throw OCRDerivedCache.CacheError.invalidResult
                    }
                    recognition = result
                    submitted.ocrText = result.text
                } catch is CancellationError { throw CancellationError() }
                catch { /* A local OCR failure must not prevent saving the image. */ }
            }
        }
        try Task.checkCancellation()
        let candidate = submitted
        let recomputedOCR = recognition.map { ClipboardImageOCR(text: $0.text, sourceImageDigest: $0.sourceImageDigest) }
        // This final transaction rechecks the snapshot after any OCR suspension.
        let undo = try await Task.detached(priority: .userInitiated) {
            try store.commitEdit(candidate, snapshot: snapshot, recomputedOCR: recomputedOCR)
        }.value
        if imageChanged {
            // Only committed content invalidates the old cache. Finish before UI
            // completion, which may immediately start another preview/rotation.
            try? await cache.remove(recordID: candidate.id, beforeRevision: undo.committedReference.revision)
            if let recognition, let newImage {
                var saved = candidate
                saved.revision = undo.committedReference.revision
                try? await cache.store(recognition, for: saved, imageData: newImage, sourceStore: store)
            }
        }
        return undo
    }
}
