import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1
import NIOWebSocket

// MARK: - Error Types

enum PortError: Error, LocalizedError {
    case alreadyInUse(port: UInt16)

    var errorDescription: String? {
        switch self {
        case .alreadyInUse(let port):
            return "Port \(port) is already in use by another process"
        }
    }
}

// MARK: - NIO Channel Handler

/// Accumulates HTTP/1.1 request parts delivered by NIOHTTP1's decoder (which
/// already handles Content-Length / chunked-encoding reassembly), then
/// dispatches the complete request to the Server's route handlers.
private final class HTTPChannelHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private var requestHead: HTTPRequestHead?
    private var bodyBuffer: ByteBuffer = ByteBuffer()
    private let server: Server

    init(server: Server) {
        self.server = server
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head):
            requestHead = head
            bodyBuffer.clear()
        case .body(var buf):
            bodyBuffer.writeBuffer(&buf)
        case .end:
            guard let head = requestHead else { return }
            let bodyData: Data? =
                bodyBuffer.readableBytes > 0 ? Data(bodyBuffer.readableBytesView) : nil
            var headers: [String: String] = [:]
            for (name, value) in head.headers {
                headers[name.description] = value
            }
            let request = HTTPRequest(
                method: head.method.rawValue,
                path: head.uri,
                headers: headers,
                body: bodyData
            )
            Logger.info(
                "Received request",
                metadata: [
                    "method": request.method,
                    "path": request.path,
                    "body": String(data: bodyData ?? Data(), encoding: .utf8) ?? "",
                ])

            // Bridge to Swift concurrency via an EventLoopPromise so that
            // ChannelHandlerContext (non-Sendable) is only ever accessed on
            // the event loop — never sent across actor boundaries.
            let promise = context.eventLoop.makePromise(of: HTTPResponse.self)
            let srv = server
            Task {
                do {
                    let response = try await srv.handleRequest(request)
                    promise.succeed(response)
                } catch {
                    promise.succeed(srv.errorResponse(error))
                }
            }
            promise.futureResult.whenComplete { result in
                let response: HTTPResponse
                switch result {
                case .success(let r): response = r
                case .failure(let e): response = srv.errorResponse(e)
                }
                HTTPChannelHandler.writeResponse(response, to: context)
            }
        }
    }

    private static func writeResponse(_ response: HTTPResponse, to context: ChannelHandlerContext) {
        var nioHeaders = HTTPHeaders()
        for (k, v) in response.headers {
            nioHeaders.add(name: k, value: v)
        }
        if let body = response.body {
            nioHeaders.replaceOrAdd(name: "Content-Length", value: "\(body.count)")
        }
        let status = HTTPResponseStatus(statusCode: response.statusCode.rawValue)
        let head = HTTPResponseHead(version: .http1_1, status: status, headers: nioHeaders)

        Logger.info(
            "Sending response",
            metadata: [
                "statusCode": "\(response.statusCode.rawValue)",
                "body": String(data: response.body ?? Data(), encoding: .utf8) ?? "",
            ])

        context.eventLoop.execute {
            context.write(NIOAny(HTTPServerResponsePart.head(head)), promise: nil)
            if let body = response.body {
                var buf = context.channel.allocator.buffer(capacity: body.count)
                buf.writeBytes(body)
                context.write(NIOAny(HTTPServerResponsePart.body(.byteBuffer(buf))), promise: nil)
            }
            context.writeAndFlush(NIOAny(HTTPServerResponsePart.end(nil)), promise: nil)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        Logger.error("Channel error", metadata: ["error": error.localizedDescription])
        context.close(promise: nil)
    }
}

// MARK: - Server Class

final class Server: @unchecked Sendable {

    // MARK: - Route Type

    private struct Route {
        let method: String
        let path: String
        let handler: (HTTPRequest) async throws -> HTTPResponse

        func matches(_ request: HTTPRequest) -> Bool {
            if method != request.method { return false }

            let routeParts = path.split(separator: "/")
            let requestParts = request.path.split(separator: "/")

            if routeParts.count != requestParts.count { return false }

            for (routePart, requestPart) in zip(routeParts, requestParts) {
                if routePart.hasPrefix(":") { continue }
                if routePart != requestPart { return false }
            }

            return true
        }

        func extractParams(_ request: HTTPRequest) -> [String: String] {
            var params: [String: String] = [:]
            let routeParts = path.split(separator: "/")
            let requestPathOnly = request.path.split(separator: "?", maxSplits: 1)[0]
            let requestParts = requestPathOnly.split(separator: "/")

            for (routePart, requestPart) in zip(routeParts, requestParts) {
                if routePart.hasPrefix(":") {
                    params[String(routePart.dropFirst())] = String(requestPart)
                }
            }
            return params
        }
    }

    // MARK: - Properties

    private let portNumber: UInt16
    private let controller: LumeController
    private var routes: [Route]
    // _channelLock guards both _serverChannel and _eventLoopGroup, which are
    // written in start() and read in stop() — potentially from different tasks.
    private let _channelLock = NSLock()
    private var _serverChannel: (any Channel)?
    private var _eventLoopGroup: (any EventLoopGroup)?

    private var serverChannel: (any Channel)? {
        get { _channelLock.withLock { _serverChannel } }
        set { _channelLock.withLock { _serverChannel = newValue } }
    }
    private var eventLoopGroup: (any EventLoopGroup)? {
        get { _channelLock.withLock { _eventLoopGroup } }
        set { _channelLock.withLock { _eventLoopGroup = newValue } }
    }

    // MARK: - Initialization

    init(port: UInt16 = 7777) {
        self.portNumber = port
        self.controller = LumeController()
        self.routes = []
        self.setupRoutes()
    }

    // MARK: - Route Setup

    private func setupRoutes() {
        routes = [
            // Built-in web dashboard. Served at "/" and "/dashboard" so a fresh
            // bushel install gives users a UI without a separate Python service.
            Route(
                method: "GET", path: "/",
                handler: { [weak self] _ in
                    guard let self else { throw HTTPError.internalError }
                    return try await self.handleDashboard()
                }),
            Route(
                method: "GET", path: "/dashboard",
                handler: { [weak self] _ in
                    guard let self else { throw HTTPError.internalError }
                    return try await self.handleDashboard()
                }),
            Route(
                method: "GET", path: "/lume/vms",
                handler: { [weak self] request in
                    guard let self else { throw HTTPError.internalError }
                    let storage = self.extractQueryParam(request: request, name: "storage")
                    return try await self.handleListVMs(storage: storage)
                }),
            Route(
                method: "GET", path: "/lume/vms/:name",
                handler: { [weak self] request in
                    guard let self else { throw HTTPError.internalError }
                    let params = self.extractPathParams(pattern: "/lume/vms/:name", from: request)
                    guard let name = params["name"] else {
                        return HTTPResponse(statusCode: .badRequest, body: "Missing VM name")
                    }
                    let storage = self.extractQueryParam(request: request, name: "storage")
                    return try await self.handleGetVM(name: name, storage: storage)
                }),
            Route(
                method: "DELETE", path: "/lume/vms/:name",
                handler: { [weak self] request in
                    guard let self else { throw HTTPError.internalError }
                    let params = self.extractPathParams(pattern: "/lume/vms/:name", from: request)
                    guard let name = params["name"] else {
                        return HTTPResponse(statusCode: .badRequest, body: "Missing VM name")
                    }
                    let storage = self.extractQueryParam(request: request, name: "storage")
                    return try await self.handleDeleteVM(name: name, storage: storage)
                }),
            Route(
                method: "POST", path: "/lume/vms",
                handler: { [weak self] request in
                    guard let self else { throw HTTPError.internalError }
                    return try await self.handleCreateVM(request.body)
                }),
            Route(
                method: "POST", path: "/lume/vms/clone",
                handler: { [weak self] request in
                    guard let self else { throw HTTPError.internalError }
                    return try await self.handleCloneVM(request.body)
                }),
            Route(
                method: "PATCH", path: "/lume/vms/:name",
                handler: { [weak self] request in
                    guard let self else { throw HTTPError.internalError }
                    let params = self.extractPathParams(pattern: "/lume/vms/:name", from: request)
                    guard let name = params["name"] else {
                        return HTTPResponse(statusCode: .badRequest, body: "Missing VM name")
                    }
                    return try await self.handleSetVM(name: name, body: request.body)
                }),
            Route(
                method: "POST", path: "/lume/vms/:name/run",
                handler: { [weak self] request in
                    guard let self else { throw HTTPError.internalError }
                    let params = self.extractPathParams(pattern: "/lume/vms/:name/run", from: request)
                    guard let name = params["name"] else {
                        return HTTPResponse(statusCode: .badRequest, body: "Missing VM name")
                    }
                    return try await self.handleRunVM(name: name, body: request.body)
                }),
            Route(
                method: "POST", path: "/lume/vms/:name/stop",
                handler: { [weak self] request in
                    guard let self else { throw HTTPError.internalError }
                    let params = self.extractPathParams(
                        pattern: "/lume/vms/:name/stop", from: request)
                    guard let name = params["name"] else {
                        return HTTPResponse(statusCode: .badRequest, body: "Missing VM name")
                    }
                    Logger.info(
                        "Processing stop VM request",
                        metadata: ["method": request.method, "path": request.path])
                    var storage: String? = nil
                    if let bodyData = request.body, !bodyData.isEmpty {
                        do {
                            if let json = try JSONSerialization.jsonObject(with: bodyData)
                                as? [String: Any],
                                let bodyStorage = json["storage"] as? String
                            {
                                storage = bodyStorage
                            }
                        } catch {}
                    }
                    return try await self.handleStopVM(name: name, storage: storage)
                }),
            Route(
                method: "POST", path: "/lume/vms/:name/setup",
                handler: { [weak self] request in
                    guard let self else { throw HTTPError.internalError }
                    let params = self.extractPathParams(
                        pattern: "/lume/vms/:name/setup", from: request)
                    guard let name = params["name"] else {
                        return HTTPResponse(statusCode: .badRequest, body: "Missing VM name")
                    }
                    return try await self.handleSetupVM(name: name, body: request.body)
                }),
            Route(
                method: "GET", path: "/lume/ipsw",
                handler: { [weak self] _ in
                    guard let self else { throw HTTPError.internalError }
                    return try await self.handleIPSW()
                }),
            Route(
                method: "POST", path: "/lume/pull",
                handler: { [weak self] request in
                    guard let self else { throw HTTPError.internalError }
                    return try await self.handlePull(request.body)
                }),
            Route(
                method: "POST", path: "/lume/pull/start",
                handler: { [weak self] request in
                    guard let self else { throw HTTPError.internalError }
                    return try await self.handlePullStart(request.body)
                }),
            Route(
                method: "POST", path: "/lume/prune",
                handler: { [weak self] _ in
                    guard let self else { throw HTTPError.internalError }
                    return try await self.handlePruneImages()
                }),
            Route(
                method: "GET", path: "/lume/images",
                handler: { [weak self] request in
                    guard let self else { throw HTTPError.internalError }
                    return try await self.handleGetImages(request)
                }),
            Route(
                method: "GET", path: "/lume/config",
                handler: { [weak self] _ in
                    guard let self else { throw HTTPError.internalError }
                    return try await self.handleGetConfig()
                }),
            Route(
                method: "POST", path: "/lume/config",
                handler: { [weak self] request in
                    guard let self else { throw HTTPError.internalError }
                    return try await self.handleUpdateConfig(request.body)
                }),
            Route(
                method: "GET", path: "/lume/config/locations",
                handler: { [weak self] _ in
                    guard let self else { throw HTTPError.internalError }
                    return try await self.handleGetLocations()
                }),
            Route(
                method: "POST", path: "/lume/config/locations",
                handler: { [weak self] request in
                    guard let self else { throw HTTPError.internalError }
                    return try await self.handleAddLocation(request.body)
                }),
            Route(
                method: "DELETE", path: "/lume/config/locations/:name",
                handler: { [weak self] request in
                    guard let self else { throw HTTPError.internalError }
                    let params = self.extractPathParams(
                        pattern: "/lume/config/locations/:name", from: request)
                    guard let name = params["name"] else {
                        return HTTPResponse(statusCode: .badRequest, body: "Missing location name")
                    }
                    return try await self.handleRemoveLocation(name)
                }),
            Route(
                method: "GET", path: "/lume/logs",
                handler: { [weak self] request in
                    guard let self else { throw HTTPError.internalError }
                    let type = self.extractQueryParam(request: request, name: "type")
                    let linesParam = self.extractQueryParam(request: request, name: "lines")
                    let lines = linesParam.flatMap { Int($0) }
                    return try await self.handleGetLogs(type: type, lines: lines)
                }),
            Route(
                method: "POST", path: "/lume/config/locations/default/:name",
                handler: { [weak self] request in
                    guard let self else { throw HTTPError.internalError }
                    let params = self.extractPathParams(
                        pattern: "/lume/config/locations/default/:name", from: request)
                    guard let name = params["name"] else {
                        return HTTPResponse(statusCode: .badRequest, body: "Missing location name")
                    }
                    return try await self.handleSetDefaultLocation(name)
                }),
            Route(
                method: "POST", path: "/lume/vms/push",
                handler: { [weak self] request in
                    guard let self else { throw HTTPError.internalError }
                    return try await self.handlePush(request.body)
                }),
            Route(
                method: "GET", path: "/lume/host/status",
                handler: { [weak self] _ in
                    guard let self else { throw HTTPError.internalError }
                    return try await self.handleGetHostStatus()
                }),
            // Browser-based VNC viewer (noVNC). Serves the HTML page that
            // auto-connects to /vnc/<name>/ws. The WebSocket upgrade for
            // /vnc/<name>/ws does NOT go through this route table — it's
            // intercepted at the channel-pipeline level by the WebSocket
            // upgrader installed in start(). See NoVNCBridge.swift.
            Route(
                method: "GET", path: "/vnc/:name",
                handler: { [weak self] request in
                    guard let self else { throw HTTPError.internalError }
                    let params = self.extractPathParams(pattern: "/vnc/:name", from: request)
                    guard let name = params["name"] else {
                        return HTTPResponse(statusCode: .badRequest, body: "Missing VM name")
                    }
                    return try await self.handleVNCViewer(name: name)
                }),
        ]
    }

    // MARK: - Helpers

    private func extractQueryParam(request: HTTPRequest, name: String) -> String? {
        let parts = request.path.split(separator: "?", maxSplits: 1)
        guard parts.count > 1 else { return nil }
        let queryString = String(parts[1])
        if let urlComponents = URLComponents(string: "http://placeholder.com?" + queryString),
            let queryItems = urlComponents.queryItems
        {
            return queryItems.first(where: { $0.name == name })?.value?.removingPercentEncoding
        }
        return nil
    }

    private func extractPathParams(pattern: String, from request: HTTPRequest) -> [String: String] {
        var params: [String: String] = [:]
        let routeParts = pattern.split(separator: "/")
        let requestPathOnly = request.path.split(separator: "?", maxSplits: 1)[0]
        let requestParts = requestPathOnly.split(separator: "/")
        for (routePart, requestPart) in zip(routeParts, requestParts) {
            if routePart.hasPrefix(":") {
                params[String(routePart.dropFirst())] = String(requestPart)
            }
        }
        return params
    }

    // MARK: - Server Lifecycle

    func start() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
        eventLoopGroup = group
        let srv = self

        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                // Install a WebSocket upgrader alongside the HTTP pipeline.
                // Requests that come in on /vnc/<name>/ws and carry the
                // standard Upgrade headers are intercepted by the upgrader;
                // everything else stays HTTP and gets dispatched through
                // HTTPChannelHandler as before.
                let upgrader = NIOWebSocketServerUpgrader(
                    shouldUpgrade: { (channel: any Channel, head: HTTPRequestHead) in
                        // Return non-nil HTTPHeaders to accept the upgrade,
                        // or nil to reject. We accept only the exact path
                        // /vnc/<name>/ws (and let the bridge fail later if
                        // the VM isn't running — keeps the upgrade path
                        // cheap and contention-free).
                        let path = head.uri.split(separator: "?", maxSplits: 1).first.map(String.init) ?? head.uri
                        let parts = path.split(separator: "/").map(String.init)
                        let ok = parts.count == 3 && parts[0] == "vnc" && parts[2] == "ws" && parts[1] != "static"
                        return channel.eventLoop.makeSucceededFuture(ok ? HTTPHeaders() : nil)
                    },
                    upgradePipelineHandler: { (channel: any Channel, head: HTTPRequestHead) in
                        // Path was already validated in shouldUpgrade — extract the name.
                        let vmName = NoVNCPath.extractVMName(fromWebSocketPath: head.uri) ?? ""
                        return Server.installVNCBridge(on: channel, vmName: vmName)
                    }
                )

                return channel.pipeline.configureHTTPServerPipeline(
                    withServerUpgrade: (upgraders: [upgrader], completionHandler: { _ in })
                ).flatMap {
                    // Add the regular HTTP request handler. On a successful
                    // WebSocket upgrade NIO removes HTTPServerRequestDecoder
                    // /Encoder from the pipeline, so this handler stops
                    // seeing data — which is exactly what we want.
                    channel.pipeline.addHandler(HTTPChannelHandler(server: srv))
                }
            }

        do {
            let channel = try await bootstrap.bind(host: "127.0.0.1", port: Int(portNumber)).get()
            serverChannel = channel
            Logger.info("Server started", metadata: ["port": "\(portNumber)"])
            try await channel.closeFuture.get()
        } catch let ioError as IOError where ioError.errnoCode == EADDRINUSE {
            try? await group.shutdownGracefully()
            throw PortError.alreadyInUse(port: portNumber)
        } catch {
            try? await group.shutdownGracefully()
            throw error
        }
        try? await group.shutdownGracefully()
    }

    func stop() {
        serverChannel?.close(promise: nil)
        if let group = eventLoopGroup {
            Task { try? await group.shutdownGracefully() }
        }
    }

    // MARK: - Request Handling

    func handleRequest(_ request: HTTPRequest) async throws -> HTTPResponse {
        Logger.info(
            "Parsed request",
            metadata: [
                "method": request.method,
                "path": request.path,
                "body": String(data: request.body ?? Data(), encoding: .utf8) ?? "",
            ])

        // Variable-depth prefix match for vendored noVNC static assets.
        // noVNC ships nested directories (core/rfb.js, core/crypto/aes.js,
        // vendor/pako/lib/zlib/inflate.js, …) which don't fit the route
        // table's "fixed path-segment count" matcher, so we special-case
        // them here.
        let pathOnly = request.path.split(separator: "?", maxSplits: 1)[0]
        if request.method == "GET" && pathOnly.hasPrefix("/vnc/static/") {
            let assetPath = String(pathOnly.dropFirst("/vnc/static/".count))
            return await handleVNCStatic(assetPath: assetPath)
        }

        guard let route = routes.first(where: { $0.matches(request) }) else {
            return HTTPResponse(statusCode: .notFound, body: "Not found")
        }

        let response = try await route.handler(request)

        Logger.info(
            "Sending response",
            metadata: [
                "statusCode": "\(response.statusCode.rawValue)",
                "body": String(data: response.body ?? Data(), encoding: .utf8) ?? "",
            ])

        return response
    }

    func errorResponse(_ error: Error) -> HTTPResponse {
        HTTPResponse(
            statusCode: .internalServerError,
            headers: ["Content-Type": "application/json"],
            body: try! JSONEncoder().encode(APIError(message: error.localizedDescription))
        )
    }

    // MARK: - WebSocket VNC bridge

    /// Wires up the noVNC WebSocket-to-TCP bridge after a successful
    /// HTTP-to-WebSocket upgrade.
    ///
    /// The flow:
    /// 1. Hop to MainActor to resolve the VM's VNC URL (vnc://:pw@host:port).
    /// 2. Open an outbound TCP connection to that host:port on the same
    ///    event loop the WebSocket channel is running on (keeps both halves
    ///    of the proxy on the same thread — no cross-loop dispatch needed
    ///    for the per-frame hot path).
    /// 3. Install the per-direction handlers: WS frames → TCP bytes on the
    ///    WS channel, TCP bytes → WS frames on the TCP channel.
    /// 4. If resolution or TCP connect fails, send a close frame so the
    ///    browser sees a clean disconnect rather than a hanging connection.
    static func installVNCBridge(on wsChannel: any Channel, vmName: String) -> EventLoopFuture<Void> {
        let promise = wsChannel.eventLoop.makePromise(of: Void.self)
        let eventLoop = wsChannel.eventLoop

        // Resolve VNC endpoint off the event loop (MainActor isolation).
        Task { @MainActor in
            do {
                let endpoint = try resolveVNCEndpoint(forVM: vmName)
                Logger.info("VNC bridge: VM resolved",
                    metadata: ["vm": vmName, "host": endpoint.host, "port": "\(endpoint.port)"])

                // Open TCP connection to the VM's VNC server. We use the same
                // event-loop group so both sides land on the same loop —
                // cheaper context switching for the per-frame copy.
                let bootstrap = ClientBootstrap(group: eventLoop)
                    .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                    .channelInitializer { tcpChannel in
                        tcpChannel.pipeline.addHandler(TCPToWebSocketHandler(
                            wsChannel: wsChannel, vmName: vmName))
                    }

                bootstrap.connect(host: endpoint.host, port: endpoint.port).whenComplete { result in
                    switch result {
                    case .success(let tcpChannel):
                        // Now install the inbound side on the WS channel.
                        let inbound = WebSocketToTCPHandler(
                            tcpChannel: tcpChannel, vmName: vmName)
                        wsChannel.pipeline.addHandler(inbound).whenComplete { addResult in
                            switch addResult {
                            case .success:
                                Logger.info("VNC bridge ready", metadata: ["vm": vmName])
                                // Close one → close the other.
                                wsChannel.closeFuture.whenComplete { _ in
                                    tcpChannel.close(promise: nil)
                                }
                                tcpChannel.closeFuture.whenComplete { _ in
                                    wsChannel.close(promise: nil)
                                }
                                promise.succeed(())
                            case .failure(let err):
                                Logger.error("VNC bridge: failed to install WS handler",
                                    metadata: ["vm": vmName, "error": err.localizedDescription])
                                tcpChannel.close(promise: nil)
                                wsChannel.close(promise: nil)
                                promise.fail(err)
                            }
                        }
                    case .failure(let err):
                        Logger.error("VNC bridge: TCP connect failed",
                            metadata: ["vm": vmName, "error": err.localizedDescription])
                        // Send a close frame so the browser sees a clean
                        // disconnect rather than a stalled connection.
                        let close = WebSocketFrame(
                            fin: true, opcode: .connectionClose, data: ByteBuffer())
                        wsChannel.writeAndFlush(close).whenComplete { _ in
                            wsChannel.close(promise: nil)
                        }
                        promise.fail(err)
                    }
                }
            } catch {
                Logger.error("VNC bridge: VM resolution failed",
                    metadata: ["vm": vmName, "error": error.localizedDescription])
                eventLoop.execute {
                    let close = WebSocketFrame(
                        fin: true, opcode: .connectionClose, data: ByteBuffer())
                    wsChannel.writeAndFlush(close).whenComplete { _ in
                        wsChannel.close(promise: nil)
                    }
                }
                promise.fail(error)
            }
        }
        return promise.futureResult
    }
}
