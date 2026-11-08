import Foundation

/// Guards the "transfer finished" claim made by engines that only observe a
/// child-process exit code or a local copy result.
///
/// `CurlEngine`, `LocalEngine` and `SystemTransferEngine` used to read the
/// destination's size and immediately set `total = downloaded = size` before
/// reporting `.completed`. That is circular: whatever is on disk becomes the
/// definition of success. A zero-byte or truncated result therefore looked
/// identical to a healthy download, and when the user supplied no checksum
/// nothing else ever challenged it.
///
/// The engines now supply independent evidence (curl's `%{size_download}` plus
/// the resume offset, the `data:` payload length, or the source file size) and
/// refuse to complete when the on-disk file disagrees.
public enum CompletionSizePolicy {
    public struct Evidence: Sendable {
        public var exists: Bool
        public var isRegularFile: Bool
        public var actualBytes: Int64
        /// Bytes written during this run (curl `%{size_download}`), if known.
        public var reportedBytes: Int64?
        /// Independently known total (resume offset + reported, source size, …).
        public var expectedBytes: Int64?
        /// A legitimately empty payload, e.g. `data:,` or an empty HTTP body.
        public var allowsEmpty: Bool

        public init(exists: Bool, isRegularFile: Bool, actualBytes: Int64,
                    reportedBytes: Int64?, expectedBytes: Int64?,
                    allowsEmpty: Bool = false) {
            self.exists = exists
            self.isRegularFile = isRegularFile
            self.actualBytes = actualBytes
            self.reportedBytes = reportedBytes
            self.expectedBytes = expectedBytes
            self.allowsEmpty = allowsEmpty
        }
    }

    /// `nil` means the completion is trustworthy; otherwise a user-facing
    /// reason that the engine should surface as an error state.
    public static func failure(_ e: Evidence) -> String? {
        guard e.exists else { return "目标文件不存在，传输没有真正落盘" }
        guard e.isRegularFile else {
            return "目标不是普通文件（目录、符号链接或特殊文件），无法确认完成"
        }
        if let expected = e.expectedBytes, expected >= 0, e.actualBytes != expected {
            return "完成尺寸不符：期望 \(expected) 字节，实际 \(e.actualBytes) 字节"
        }
        if let reported = e.reportedBytes, reported > 0, e.actualBytes < reported {
            return "落盘尺寸 \(e.actualBytes) 小于引擎上报的 \(reported) 字节"
        }
        if e.actualBytes == 0, !e.allowsEmpty, (e.expectedBytes ?? 0) == 0 {
            return "目标文件为空，疑似传输被截断或未写入"
        }
        return nil
    }

    /// Read the on-disk evidence. `attributesOfItem` follows symlinks, so the
    /// symbolic-link flag is checked separately with resource values.
    public static func evidence(at url: URL, reported: Int64? = nil,
                                expected: Int64? = nil,
                                allowsEmpty: Bool = false) -> Evidence {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let type = attrs?[.type] as? FileAttributeType
        let isLink = (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?
            .isSymbolicLink ?? false
        return Evidence(
            exists: attrs != nil,
            isRegularFile: type == .typeRegular && !isLink,
            actualBytes: (attrs?[.size] as? NSNumber)?.int64Value ?? 0,
            reportedBytes: reported,
            expectedBytes: expected,
            allowsEmpty: allowsEmpty)
    }

    public static func failure(at url: URL, reported: Int64? = nil,
                               expected: Int64? = nil,
                               allowsEmpty: Bool = false) -> String? {
        failure(evidence(at: url, reported: reported, expected: expected,
                         allowsEmpty: allowsEmpty))
    }
}
