import Foundation

/// All accepted measurements are nonnegative and their sums fit in Int64. This
/// makes subsequent category/scope grouping safe in any order, without saturating
/// a value and accidentally presenting an exact-looking total.
struct StorageUsageTotals {
    private(set) var logicalBytes: Int64 = 0
    private(set) var allocatedBytes: Int64 = 0

    mutating func append(fileSize: Int64, allocatedBlocks: Int64, isRegularFile: Bool) -> (logical: Int64, allocated: Int64)? {
        guard fileSize >= 0, allocatedBlocks >= 0 else { return nil }
        let (allocated, blockOverflow) = allocatedBlocks.multipliedReportingOverflow(by: 512)
        let logical = isRegularFile ? fileSize : 0
        let (nextLogical, logicalOverflow) = logicalBytes.addingReportingOverflow(logical)
        let (nextAllocated, allocatedOverflow) = allocatedBytes.addingReportingOverflow(allocated)
        guard !blockOverflow, !logicalOverflow, !allocatedOverflow else { return nil }
        logicalBytes = nextLogical; allocatedBytes = nextAllocated
        return (logical, allocated)
    }
}
