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
    // Backpressure counter: incremented whenever we forward bytes to a TCP
    // channel that's flagged as not-writable. v1 simplification per review
    // feedback — we log a warning at every 1000th occurrence so we get a
    // real-world signal, but do NOT drop bytes (RFB is a stream protocol and
    // dropping frames would corrupt the session). The proper autoRead-toggle
    // implementation is tracked as a follow-up.
    private var blockedWrites: UInt64 = 0

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
            // TODO: proper backpressure — when tcpChannel is not writable,
            // pause WS autoRead and resume on writability-changed. For now,
            // count and periodically log so the metric isn't silent.
            if !tcpChannel.isWritable {
                blockedWrites &+= 1
                if blockedWrites.isMultiple(of: 1000) {
                    Logger.error("WS->TCP bridge: TCP peer not writable",
                        metadata: ["vm": vmName, "blocked_writes": "\(blockedWrites)"])
                }
            }
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
    // Backpressure counter; see WebSocketToTCPHandler.blockedWrites for the
    // v1-simplification rationale.
    private var blockedWrites: UInt64 = 0

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
        // TODO: proper backpressure — when wsChannel is not writable, pause
        // TCP autoRead and resume on writability-changed. v1: count + log.
        if !wsChannel.isWritable {
            blockedWrites &+= 1
            if blockedWrites.isMultiple(of: 1000) {
                Logger.error("TCP->WS bridge: WS peer not writable",
                    metadata: ["vm": vmName, "blocked_writes": "\(blockedWrites)"])
            }
        }
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

// MARK: - Bridge connection registry
//
// Caps concurrent WS<->TCP bridges to protect the daemon (and the host) from
// runaway clients. Per-VM cap stops a single misbehaving viewer from
// exhausting connections; total cap is a fail-safe for the daemon as a whole.
// Loopback-only deployment means the practical attacker surface is small, but
// these limits also prevent honest bugs (tab leaks, etc.) from cascading.

actor BridgeRegistry {
    static let shared = BridgeRegistry()
    private var perVM: [String: Int] = [:]
    private var total: Int = 0
    let maxPerVM: Int = 32
    let maxTotal: Int = 128

    func tryAcquire(vmName: String) -> Bool {
        guard total < maxTotal, (perVM[vmName] ?? 0) < maxPerVM else { return false }
        perVM[vmName, default: 0] += 1
        total += 1
        return true
    }

    func release(vmName: String) {
        if let n = perVM[vmName], n > 0 {
            perVM[vmName] = n - 1
            if perVM[vmName] == 0 { perVM.removeValue(forKey: vmName) }
        }
        if total > 0 { total -= 1 }
    }
}

// MARK: - Pure bridge wireup
//
// Pipeline glue for both sides of the bridge. Hoisted out of installVNCBridge
// so EmbeddedChannel-based tests can call it directly without standing up a
// real TCP socket / WebSocket handshake. installVNCBridge handles resolution
// and TCP connect, then delegates to this function.
//
// Both channels must already be live. The function installs the per-direction
// handlers and the close-cascade. Returns a future that completes when both
// handlers are installed (or fails if either install fails).

func wireBridge(ws: any Channel, tcp: any Channel, vmName: String) -> EventLoopFuture<Void> {
    // Backpressure: bound the write-buffer water marks on both sides so
    // isWritable becomes a meaningful signal. Without this, NIO's default
    // unbounded buffer would let a slow peer's queue grow without bound.
    // We deliberately fire-and-forget the setOption calls; they're best-effort
    // and a non-supported channel (e.g. EmbeddedChannel in tests) shouldn't
    // block the bridge install.
    let waterMark = ChannelOptions.Types.WriteBufferWaterMark(low: 32_768, high: 4_194_304)
    _ = ws.setOption(ChannelOptions.writeBufferWaterMark, value: waterMark)
    _ = tcp.setOption(ChannelOptions.writeBufferWaterMark, value: waterMark)

    let tcpHandler = TCPToWebSocketHandler(wsChannel: ws, vmName: vmName)
    let wsHandler = WebSocketToTCPHandler(tcpChannel: tcp, vmName: vmName)

    return tcp.pipeline.addHandler(tcpHandler).flatMap {
        ws.pipeline.addHandler(wsHandler)
    }.map {
        // Close-cascade: closing one side closes the other so a tab close
        // doesn't leak a TCP connection, and a guest shutdown doesn't leave
        // a half-open WS.
        ws.closeFuture.whenComplete { _ in tcp.close(promise: nil) }
        tcp.closeFuture.whenComplete { _ in ws.close(promise: nil) }
    }
}
