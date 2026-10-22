import Darwin
import Foundation
import Security

/// Chrome's native messaging frames: each JSON message follows its length as a 32-bit number in native byte order.
/// TabScoutChromeHost and the app use the same frames on their socket, so the helper passes messages on whole.
enum NativeMessage {
    static let hostName = "local.tabscout.chrome"
    /// Fixed by the public key in the extension's manifest.json.
    static let extensionID = "dofcmbpicogclehjjkobakjbghefaglp"
    /// Far above anything Tab Scout and its extension exchange; Chrome refuses messages to it over 1 MB anyway.
    static let limit = 1 << 20

    /// Beside Tab Scout's learning data; the helper finds the app here.
    static var socketURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TabScout/chrome.sock")
    }

    static func frame(_ message: Data) -> Data {
        var length = UInt32(message.count)
        return Data(bytes: &length, count: 4) + message
    }

    /// Removes the complete messages at the start of `buffer`, leaving a partial one; nil once a frame is over the limit.
    static func messages(from buffer: inout Data) -> [Data]? {
        var found: [Data] = []
        while buffer.count >= 4 {
            let length = Int(buffer.prefix(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
            guard length <= limit else { return nil }
            guard buffer.count >= 4 + length else { break }
            found.append(Data(buffer.dropFirst(4).prefix(length)))
            buffer = Data(buffer.dropFirst(4 + length))
        }
        return found
    }

    /// Reads one message, waiting for it; nil at the end of the stream or for a frame over the limit.
    static func read(from descriptor: Int32) -> Data? {
        guard let header = read(4, from: descriptor) else { return nil }
        let length = header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        guard length <= limit else { return nil }
        return read(Int(length), from: descriptor)
    }

    private static func read(_ count: Int, from descriptor: Int32) -> Data? {
        var data = Data(count: count)
        var offset = 0
        while offset < count {
            let read = data.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress! + offset, count - offset) }
            if read < 0 && errno == EINTR { continue }
            guard read > 0 else { return nil }
            offset += read
        }
        return data
    }

    static func write(_ data: Data, to descriptor: Int32) -> Bool {
        data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(descriptor, bytes.baseAddress! + offset, bytes.count - offset)
                if written < 0 && errno == EINTR { continue }
                guard written > 0 else { return false }
                offset += written
            }
            return true
        }
    }

    static func address(_ url: URL) -> sockaddr_un? {
        var address = sockaddr_un()
        let path = url.path.utf8CString
        guard path.count <= MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { target in path.withUnsafeBytes { target.copyMemory(from: $0) } }
        return address
    }

    /// A socket connected to `url`, or -1. Writing to it after the other end closes fails instead of raising SIGPIPE.
    static func connect(to url: URL) -> Int32 {
        guard var address = address(url) else { return -1 }
        let socket = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard socket >= 0 else { return -1 }
        noSignalOnClose(socket)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(socket, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else { close(socket); return -1 }
        return socket
    }

    static func noSignalOnClose(_ socket: Int32) {
        var on: Int32 = 1
        setsockopt(socket, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }
}

enum CodeIdentity {
    /// Whether the process at the other end of `socket` runs the code signed at `url`, judged by that code's designated
    /// requirement: its certificate, or for an ad-hoc signed build its exact hash. Another program of the same user
    /// cannot pass, so neither the app nor the helper talks to a stand-in.
    static func peer(of socket: Int32, isSignedLike url: URL) -> Bool {
        var token = audit_token_t()
        var length = socklen_t(MemoryLayout<audit_token_t>.size)
        guard getsockopt(socket, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &length) == 0 else { return false }
        let audit = withUnsafeBytes(of: &token) { Data($0) }
        var code: SecStaticCode?
        var requirement: SecRequirement?
        var peer: SecCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
              SecCodeCopyDesignatedRequirement(code, [], &requirement) == errSecSuccess, let requirement,
              SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributeAudit: audit] as CFDictionary, [], &peer) == errSecSuccess,
              let peer else { return false }
        return SecCodeCheckValidity(peer, [], requirement) == errSecSuccess
    }
}
