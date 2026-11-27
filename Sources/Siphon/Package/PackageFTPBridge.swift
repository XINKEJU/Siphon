import Foundation

/// Wires the real FTP lister into `PackageResolver`. Kept in its own file so the
/// package parsers can be compiled and tested without curl/ExternalRunner.
public enum PackageFTPBridge {
    public static func install() {
        PackageResolver.ftpLister = { url in
            let entries = try await FTPDirectoryLister.list(url)
            return entries.map {
                PackageFTPEntry(name: $0.name, size: $0.size, isDirectory: $0.isDirectory)
            }
        }
    }
}