import Foundation
import Darwin

/// BSD-socket TCP channel for the eDonkey wire protocol.
///
/// All I/O is blocking but bounded by `SO_RCVTIMEO` / `SO_SNDTIMEO`, and the
/// whole transfer runs on a dedicated dispatch queue (see `NativeED2KBackend`),
/// so it never blocks a Swift concurrency cooperative thread.
final class ED2KSocket {
    private let fd: Int32
    let host: String
    let port: Int

    private static let maxFrame: UInt32 = 4 * 1024 * 1024

    init(host: String, port: Int, timeout: TimeInterval = 8) throws {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = IPPROTO_TCP

        var result: UnsafeMutablePointer<addrinfo>?
        let rc = getaddrinfo(host, String(port), &hints, &result)
        guard rc == 0, let list = result else {
            throw ED2KTransportError.connectionFailed("\(host):\(port) 无法解析 (\(rc))")
        }
        defer { freeaddrinfo(list) }

        var socketFD: Int32 = -1
        var cursor: UnsafeMutablePointer<addrinfo>? = list
        while let ai = cursor {
            let s = socket(ai.pointee.ai_family, ai.pointee.ai_socktype, ai.pointee.ai_protocol)
            if s >= 0 {
                let originalFlags = fcntl(s, F_GETFL)
                _ = fcntl(s, F_SETFL, originalFlags | O_NONBLOCK)
                let cr = connect(s, ai.pointee.ai_addr, ai.pointee.ai_addrlen)
                if cr == 0 || (cr == -1 && errno == EINPROGRESS) {
                    var pfd = pollfd(fd: s, events: Int16(POLLOUT), revents: 0)
                    let pr = poll(&pfd, 1, Int32(timeout * 1000))
                    if pr > 0 {
                        var err: Int32 = 0
                        var len = socklen_t(MemoryLayout<Int32>.size)
                        getsockopt(s, SOL_SOCKET, SO_ERROR, &err, &len)
                        if err == 0 {
                            _ = fcntl(s, F_SETFL, originalFlags)
                            var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
                            setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv,
                                       socklen_t(MemoryLayout<timeval>.size))
                            setsockopt(s, SOL_SOCKET, SO_SNDTIMEO, &tv,
                                       socklen_t(MemoryLayout<timeval>.size))
                            var one: Int32 = 1
                            // macOS has no MSG_NOSIGNAL; without SO_NOSIGPIPE a
                            // peer closing mid-write would SIGKILL the whole app.
                            setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &one,
                                       socklen_t(MemoryLayout<Int32>.size))
                            socketFD = s
                            break
                        }
                    }
                }
                Darwin.close(s)
            }
            cursor = ai.pointee.ai_next
        }

        guard socketFD >= 0 else {
            throw ED2KTransportError.connectionFailed("\(host):\(port) 连接超时或被拒绝")
        }
        self.fd = socketFD
        self.host = host
        self.port = port
    }

    func send(frame: ED2KFrame) throws {
        let data = frame.encoded()
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var sent = 0
            while sent < data.count {
                let n = Darwin.send(fd, base.advanced(by: sent), data.count - sent, 0)
                if n <= 0 {
                    throw ED2KTransportError.ioFailed(String(cString: strerror(errno)))
                }
                sent += n
            }
        }
    }

    private func readExact(_ count: Int) throws -> Data {
        var out = Data()
        out.reserveCapacity(count)
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while out.count < count {
            let want = min(count - out.count, buffer.count)
            let n = buffer.withUnsafeMutableBytes { recv(fd, $0.baseAddress, want, 0) }
            if n == 0 { throw ED2KTransportError.ioFailed("连接被对端关闭") }
            if n < 0 {
                if errno == EINTR { continue }
                throw ED2KTransportError.ioFailed(String(cString: strerror(errno)))
            }
            out.append(contentsOf: buffer[0..<n])
        }
        return out
    }

    /// Read exactly one length-prefixed eDonkey frame.
    func readFrame() throws -> ED2KFrame {
        let header = try readExact(5)
        let marker = header[header.startIndex]
        guard marker == ED2KProto.edonkey || marker == ED2KProto.emuleExt
                || marker == ED2KProto.packed else {
            throw ED2KTransportError.invalidMarker(marker)
        }
        let b = header.startIndex
        let size = UInt32(header[b + 1])
            | (UInt32(header[b + 2]) << 8)
            | (UInt32(header[b + 3]) << 16)
            | (UInt32(header[b + 4]) << 24)
        guard size >= 1 else { throw ED2KTransportError.truncatedFrame }
        guard size <= Self.maxFrame else { throw ED2KTransportError.frameTooLarge(size) }
        let body = try readExact(Int(size))
        let opcode = body[body.startIndex]
        let payload = body.subdata(in: (body.startIndex + 1)..<body.endIndex)
        return ED2KFrame(marker: marker, opcode: opcode, payload: payload)
    }

    func close() { Darwin.close(fd) }
}
