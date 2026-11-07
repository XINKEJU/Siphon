import Foundation
import Darwin

/// 下载前的磁盘空间预检与文件预分配。
///
/// 稀疏文件（`truncate`）只改变逻辑长度、不占用真实空间，因此磁盘剩余
/// 2 GB 时 4 GB 的任务照样能启动，写到一半才报 ENOSPC，已下字节全部作废。
/// 预检在传输开始前挡住这种必然失败的任务；`preallocate` 则提前向文件系统
/// 申请真实磁盘块（APFS 可能忽略该请求，属正常情况）。
public enum DiskSpaceGuard {
    /// 预留 10% 余量，避免刚好写满影响系统与其他应用。
    public static let headroom: Double = 0.1

    /// 目录所在卷的可用空间（优先 important usage，更贴近实际可写量）。
    public static func availableBytes(for directory: URL) -> Int64? {
        var probe = directory
        if !FileManager.default.fileExists(atPath: probe.path) {
            probe = probe.deletingLastPathComponent()
        }
        let keys: Set<URLResourceKey> = [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey
        ]
        guard let values = try? probe.resourceValues(forKeys: keys) else { return nil }
        if let v = values.volumeAvailableCapacityForImportantUsage { return Int64(v) }
        if let v = values.volumeAvailableCapacity { return Int64(v) }
        return nil
    }

    /// 校验剩余空间是否够写 `total - alreadyWritten` 字节（含余量）。
    /// 取不到卷信息时放行，避免在特殊文件系统上误伤下载。
    public static func ensureCapacity(total: Int64, alreadyWritten: Int64,
                                      directory: URL) throws {
        guard total > 0 else { return }
        let needed = total - max(0, alreadyWritten)
        guard needed > 0 else { return }
        guard let available = availableBytes(for: directory) else { return }
        let required = needed + Int64(Double(needed) * headroom)
        guard available >= required else {
            throw NetFailure.insufficientDisk(
                "还需要 \(human(required))，该卷仅剩 \(human(available))")
        }
    }

    private static func human(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// 尽力申请真实磁盘块。连续分配失败时退回非连续分配；
    /// 文件系统不支持（ENOTSUP）或 APFS 忽略请求都不算错误。
    public static func preallocate(_ handle: FileHandle, total: Int64) {
        guard total > 0 else { return }
        var store = fstore_t()
        store.fst_flags = UInt32(F_ALLOCATECONTIG)
        store.fst_posmode = F_PEOFPOSMODE
        store.fst_offset = 0
        store.fst_length = total
        store.fst_bytesalloc = 0
        if fcntl(handle.fileDescriptor, F_PREALLOCATE, &store) == -1 {
            store.fst_flags = UInt32(F_ALLOCATEALL)
            _ = fcntl(handle.fileDescriptor, F_PREALLOCATE, &store)
        }
    }
}
