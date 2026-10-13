import Darwin
import Foundation

/// Resolve the UUID through the descriptor's mounted volume, rather than treating
/// st_dev as a durable identifier. Unsupported volumes retain conservative device checks.
enum StorageVolumeIdentity {
    static func uuid(for descriptor: Int32) -> String? {
        var information = stat(), filesystem = statfs()
        guard fstat(descriptor, &information) == 0, fstatfs(descriptor, &filesystem) == 0 else { return nil }
        let mount = withUnsafePointer(to: &filesystem.f_mntonname) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        var mounted = stat()
        guard lstat(mount, &mounted) == 0, mounted.st_dev == information.st_dev,
              let raw = try? URL(fileURLWithPath: mount).resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString,
              let identifier = UUID(uuidString: raw), identifier != UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)) else { return nil }
        var checked = stat()
        guard lstat(mount, &checked) == 0, StorageSpaceNode(checked) == StorageSpaceNode(mounted) else { return nil }
        return identifier.uuidString
    }
}
