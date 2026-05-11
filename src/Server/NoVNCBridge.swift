import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1
import NIOWebSocket

// MARK: - Path matching helpers
//
// The WebSocket upgrade for noVNC is handled at the channel pipeline level
// (not via the regular HTTP route table) because NIOWebSocketServerUpgrader
// has to be installed before HTTP body framing starts. We match the same
// `/vnc/:name/ws` shape the route table would, but inside the pipeline.

enum NoVNCPath {
    /// Returns the VM name if `path` matches `/vnc/<name>/ws` (and strips
    /// any query string). Returns nil otherwise.
    ///
    /// Names are URL-decoded — the noVNC HTML calls `encodeURIComponent` so
    /// any VM with a space or other URL-unsafe character in its name still
    /// round-trips. The static asset prefix `/vnc/static/...` is explicitly
    /// excluded so it falls through to the normal HTTP route handler.
    static func extractVMName(fromWebSocketPath path: String) -> String? {
        // Strip query string if present.
        let pathOnly = path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? path
        let parts = pathOnly.split(separator: "/").map(String.init)
        // Expect ["vnc", "<name>", "ws"] — exactly 3 segments.
        guard parts.count == 3, parts[0] == "vnc", parts[2] == "ws" else { return nil }
        // Skip the static-asset prefix.
        if parts[1] == "static" { return nil }
        return parts[1].removingPercentEncoding ?? parts[1]
    }
}

// MARK: - VNC URL parsing
//
// Mirrors the same `vnc://:password@host:port` → URLComponents pattern used
// by openVNC(forVM:) in MCPServer.swift. Kept as a nonisolated free function
// so the channel-pipeline glue can call it without bouncing onto MainActor.

struct VNCEndpoint: Sendable {
    let host: String
    let port: Int
    let password: String
}

enum VNCEndpointParseError: Error {
    case missingURL
    case malformedURL(String)
}

func parseVNCEndpoint(_ urlString: String) throws -> VNCEndpoint {
    let httpish = urlString.replacingOccurrences(of: "vnc://", with: "http://")
    guard let comps = URLComponents(string: httpish),
          let host = comps.host,
          let port = comps.port,
          port >= 0, port <= 65535
    else {
        throw VNCEndpointParseError.malformedURL(urlString)
    }
    // RFB auth password is in the userinfo "password" slot in vnc://:pw@host:port.
    let password = comps.password ?? ""
    return VNCEndpoint(host: host, port: port, password: password)
}

// MARK: - WebSocket-to-TCP proxy handlers
//
// Two halves of the bridge:
//
//   browser  --WS frames-->  WebSocketToTCPHandler  --TCP bytes-->  VM VNC server
//   browser  <--WS frames--  TCPToWebSocketHandler  <--TCP bytes--  VM VNC server
//
// The WebSocketToTCPHandler lives in the inbound HTTP pipeline (after the
// WebSocket frame decoder upgraded the connection). It owns the outbound
// TCP channel and forwards every binary frame's payload to it.
//
// The TCPToWebSocketHandler lives in the outbound TCP pipeline. It owns a
// weak reference to the inbound channel (the browser-facing one) and emits
// every ByteBuffer it receives as a binary WebSocket frame. The two halves
// close each other on EOF or error so a tab close doesn't leak a TCP
// connection to the VM, and a guest shutdown doesn't leave a half-open WS.

final class WebSocketToTCPHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = WebSocketFrame
    typealias OutboundOut = WebSocketFrame

    private let tcpChannel: any Channel
    private let vmName: String
    private var closed = false

    init(tcpChannel: any Channel, vmName: String) {
        self.tcpChannel = tcpChannel
        self.vmName = vmName
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = unwrapInboundIn(data)

        switch frame.opcode {
        case .binary, .text, .continuation:
            // Unmask the payload — RFB doesn't know about WebSocket framing,
            // it just wants the raw bytes. NIOWebSocket masks/unmasks based
            // on the frame's maskKey.
            var data = frame.unmaskedData
            // Forward bytes to the VM's VNC TCP socket. No fragmenting — RFB
            // is a stream protocol, the VM handles whatever chunks arrive.
            let bytes = data.readableBytesView
            var buf = tcpChannel.allocator.buffer(capacity: bytes.count)
            buf.writeBytes(bytes)
            tcpChannel.writeAndFlush(buf, promise: nil)

        case .ping:
            // Echo back a pong; ws clients (including browsers via the
            // built-in keepalive) won't normally send ping but be safe.
            let pong = WebSocketFrame(fin: true, opcode: .pong, data: frame.unmaskedData)
            context.writeAndFlush(wrapOutboundOut(pong), promise: nil)

        case .connectionClose:
            closeBoth(context: context, clean: true)

        default:
            // Pong / unknown — ignore.
            break
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        closeBoth(context: context, clean: false)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        Logger.error("WS-to-TCP bridge error",
            metadata: ["vm": vmName, "error": error.localizedDescription])
        closeBoth(context: context, clean: false)
    }

    private func closeBoth(context: ChannelHandlerContext, clean: Bool) {
        guard !closed else { return }
        closed = true
        // Close the TCP side first so the VM's RFB read loop terminates.
        tcpChannel.close(promise: nil)
        // Send a graceful close frame to the browser, then drop the channel.
        if clean {
            let close = WebSocketFrame(fin: true, opcode: .connectionClose, data: ByteBuffer())
            context.writeAndFlush(wrapOutboundOut(close)).whenComplete { _ in
                context.close(promise: nil)
            }
        } else {
            context.close(promise: nil)
        }
    }
}

final class TCPToWebSocketHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    // Strong reference — the WS channel owns the TCP channel via this handler's
    // lifecycle. When the WS closes, the bootstrap's promise will close this
    // TCP channel, which calls channelInactive here and tears down the pair.
    private let wsChannel: any Channel
    private let vmName: String
    private var closed = false

    init(wsChannel: any Channel, vmName: String) {
        self.wsChannel = wsChannel
        self.vmName = vmName
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buffer = unwrapInboundIn(data)
        // Wrap raw RFB bytes in a single binary WebSocket frame. NIO's
        // WebSocketFrameEncoder downstream of the browser-facing channel
        // will mask if it's the client (it's not — we're the server) and
        // emit framing bytes.
        let frame = WebSocketFrame(fin: true, opcode: .binary, data: buffer)
        wsChannel.writeAndFlush(frame, promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        closeBoth()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        Logger.error("TCP-to-WS bridge error",
            metadata: ["vm": vmName, "error": error.localizedDescription])
        closeBoth()
    }

    private func closeBoth() {
        guard !closed else { return }
        closed = true
        // Tell the browser we're done (clean close), then drop both.
        wsChannel.eventLoop.execute {
            let frame = WebSocketFrame(fin: true, opcode: .connectionClose, data: ByteBuffer())
            self.wsChannel.writeAndFlush(frame).whenComplete { _ in
                self.wsChannel.close(promise: nil)
            }
        }
    }
}

// MARK: - VNC endpoint resolver (Sendable trampoline)
//
// The HTTP-upgrade callback runs on a NIO event loop and is not on MainActor.
// LumeController is MainActor-isolated (its `getDetails` reads stored state).
// We hop to MainActor to look up the vncUrl, then return a plain Sendable
// VNCEndpoint that the event loop can use to open the TCP connection.

@MainActor
func resolveVNCEndpoint(forVM name: String) throws -> VNCEndpoint {
    let controller = LumeController()
    let details = try controller.getDetails(name: name, storage: nil)
    guard details.status == "running" else {
        throw VMError.notRunning(name)
    }
    guard let urlString = details.vncUrl else {
        throw VMError.vncNotConfigured
    }
    return try parseVNCEndpoint(urlString)
}
