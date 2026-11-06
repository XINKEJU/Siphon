#!/usr/bin/env python3
"""Minimal eDonkey/eMule peer + server fixture for the native ED2K backend.

Speaks the real TCP wire protocol (0xE3 marker, u32-LE length-prefixed frames)
so the Swift client is validated against an independent implementation, not a
mock of its own API.

Usage:
    python3 ed2k_peer.py <fixture.bin> <port> [--corrupt-block N] [--as-server]

Frames: [marker:1][size:u32 LE = 1 + len(payload)][opcode:1][payload]
"""
import socketserver
import struct
import sys

EDONKEY = 0xE3
EMULE = 0xC5

OP_HELLO = 0x01
OP_SENDINGPART = 0x46
OP_REQUESTPARTS = 0x47
OP_END_OF_DOWNLOAD = 0x49
OP_HELLOANSWER = 0x4C
OP_STARTUPLOADREQ = 0x54
OP_ACCEPTUPLOADREQ = 0x55
OP_REQUESTPARTS64 = 0xA3
OP_SENDINGPART64 = 0xA2

OP_GETSOURCES = 0x19
OP_FOUND_SOURCES = 0x42
OP_IDCHANGE = 0x40
OP_LOGIN = 0x01


def frame(opcode, payload=b"", marker=EDONKEY):
    return struct.pack("<BIB", marker, 1 + len(payload), opcode) + payload


class PeerHandler(socketserver.BaseRequestHandler):
    def read_frame(self):
        def exact(n):
            buf = b""
            while len(buf) < n:
                chunk = self.request.recv(n - len(buf))
                if not chunk:
                    raise EOFError
                buf += chunk
            return buf

        # Header is 5 bytes: <marker:B><size:I>. `size` counts the opcode byte,
        # so the first byte of the `size`-byte body is the opcode.
        header = exact(5)
        marker, size = struct.unpack("<BI", header)
        if size < 1 or size > 4 * 1024 * 1024:
            raise ValueError("bad frame size %d" % size)
        body = exact(size)
        return marker, body[0], body[1:]

    def handle(self):
        self.request.settimeout(10)
        data = self.server.fixture
        corrupt = self.server.corrupt_block
        as_server = self.server.as_server

        try:
            while True:
                marker, opcode, payload = self.read_frame()
                if as_server:
                    if opcode == OP_LOGIN and marker == EDONKEY:
                        self.request.sendall(frame(OP_IDCHANGE, struct.pack("<I", 12345)))
                    elif opcode == OP_GETSOURCES:
                        # <fileHash 16><size u32>[<size u64>] — echo the hash.
                        count = 1
                        body = payload[:16] + bytes([count])
                        body += bytes([127, 0, 0, 1]) + struct.pack("<H", self.server.peer_port)
                        self.request.sendall(frame(OP_FOUND_SOURCES, body))
                    continue

                if marker == EDONKEY and opcode == OP_HELLO:
                    # Client hello is followed by an eMule info frame; answer once.
                    # Payload is a client-info blob the client does not parse.
                    self.request.sendall(frame(OP_HELLOANSWER, payload[:16] + b"\x00" * 6))
                elif marker == EMULE and opcode == OP_HELLO:
                    continue  # eMule extension info
                elif marker == EDONKEY and opcode == OP_STARTUPLOADREQ:
                    self.request.sendall(frame(OP_ACCEPTUPLOADREQ))
                elif marker == EDONKEY and opcode == OP_REQUESTPARTS:
                    # <fileHash 16><start[3] u32><end[3] u32>
                    starts = struct.unpack("<III", payload[16:28])
                    ends = struct.unpack("<III", payload[28:40])
                    for start, end in zip(starts, ends):
                        if end <= start or end > len(data):
                            continue
                        chunk = bytearray(data[start:end])
                        idx = start // (180 * 1024)
                        if corrupt is not None and idx == corrupt and chunk:
                            chunk[0] ^= 0xFF
                        body = payload[:16] + struct.pack("<II", start, end) + bytes(chunk)
                        self.request.sendall(frame(OP_SENDINGPART, body))
                elif marker == EMULE and opcode == OP_REQUESTPARTS64:
                    starts = struct.unpack("<QQQ", payload[16:40])
                    ends = struct.unpack("<QQQ", payload[40:64])
                    for start, end in zip(starts, ends):
                        if end <= start or end > len(data):
                            continue
                        chunk = data[start:end]
                        body = payload[:16] + struct.pack("<QQ", start, end) + chunk
                        self.request.sendall(frame(OP_SENDINGPART64, body, marker=EMULE))
                elif marker == EDONKEY and opcode == OP_END_OF_DOWNLOAD:
                    break
        except (EOFError, ConnectionError, socketserver.socket.timeout, OSError):
            pass


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True

    def __init__(self, addr, handler, fixture, corrupt, peer_port, as_server):
        self.fixture = fixture
        self.corrupt_block = corrupt
        self.peer_port = peer_port
        self.as_server = as_server
        super().__init__(addr, handler)


def main():
    path, port = sys.argv[1], int(sys.argv[2])
    corrupt = None
    as_server = False
    for i, arg in enumerate(sys.argv):
        if arg == "--corrupt-block":
            corrupt = int(sys.argv[i + 1])
        if arg == "--as-server":
            as_server = True
    peer_port = 18770
    for i, arg in enumerate(sys.argv):
        if arg == "--peer-port":
            peer_port = int(sys.argv[i + 1])

    with open(path, "rb") as f:
        fixture = f.read()

    with Server(("127.0.0.1", port), PeerHandler, fixture,
                corrupt, peer_port, as_server) as srv:
        srv.serve_forever()


if __name__ == "__main__":
    main()
