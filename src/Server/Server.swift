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
    // InboundIn is declared as `Any` rather than HTTPServerRequestPart so that
    // unwrapInboundIn doesn't force-cast. After a successful WebSocket upgrade
    // this handler may still be in the pipeline while the WS frame decoder is
    // added by NIO at position .last (i.e. *after* this handler in inbound
    // order), and the first buffered WS frame can arrive as raw IOData before
    // we get a chance to remove the handler. With InboundIn = HTTPServerRequestPart
    // that cast hit fatalError("tried to decode as type HTTPPart…"). With
    // InboundIn = Any we get Any, do a safe `as?` cast, and pass through any
    // non-HTTP data to the next handler.
    typealias InboundIn = Any
    typealias OutboundOut = HTTPServerResponsePart

    private var requestHead: HTTPRequestHead?
    private var bodyBuffer: ByteBuffer = ByteBuffer()
    private let server: Server

    init(server: Server) {
        self.server = server
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard let part = unwrapInboundIn(data) as? HTTPServerRequestPart else {
            // Not HTTP — most likely a WS frame after upgrade. Forward unchanged
            // to the next handler (the WS bridge), which knows what to do with it.
            context.fireChannelRead(data)
            return
        }
        switch part {
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

    /// Pipeline name for the custom HTTPChannelHandler. Referenced when the
    /// WebSocket upgrader needs to remove this handler before installing the
    /// VNC bridge — otherwise the post-upgrade WS frames hit
    /// HTTPChannelHandler's HTTPServerRequestPart force-cast and crash.
    static let httpAppHandlerName = "bushel.http_app_handler"

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
                method: "GET", path: "/lume/vms/:name/metadata",
                handler: { [weak self] request in
                    guard let self else { throw HTTPError.internalError }
                    let params = self.extractPathParams(
                        pattern: "/lume/vms/:name/metadata", from: request)
                    guard let name = params["name"] else {
                        return HTTPResponse(statusCode: .badRequest, body: "Missing VM name")
                    }
                    let storage = self.extractQueryParam(request: request, name: "storage")
                    return try await self.handleGetMetadata(name: name, storage: storage)
                }),
            Route(
                method: "PUT", path: "/lume/vms/:name/metadata",
                handler: { [weak self] request in
                    guard let self else { throw HTTPError.internalError }
                    let params = self.extractPathParams(
                        pattern: "/lume/vms/:name/metadata", from: request)
                    guard let name = params["name"] else {
                        return HTTPResponse(statusCode: .badRequest, body: "Missing VM name")
                    }
                    let storage = self.extractQueryParam(request: request, name: "storage")
                    return try await self.handlePutMetadata(
                        name: name, storage: storage, body: request.body)
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
                let port = self.portNumber
                let upgrader = NIOWebSocketServerUpgrader(
                    // 1 MiB max frame: VNC FramebufferUpdate messages can carry
                    // a full-screen worth of pixels (default noVNC NIO setting
                    // of 16 KiB is far too small for retina resolutions).
                    maxFrameSize: 1 << 20,
                    shouldUpgrade: { (channel: any Channel, head: HTTPRequestHead) in
                        // Return non-nil HTTPHeaders to accept the upgrade,
                        // or nil to reject. Path → Origin → VM existence,
                        // each cheapest-first.

                        // 1. Path shape: /vnc/<name>/ws, not /vnc/static/.
                        let path = head.uri.split(separator: "?", maxSplits: 1).first.map(String.init) ?? head.uri
                        let parts = path.split(separator: "/").map(String.init)
                        guard parts.count == 3, parts[0] == "vnc", parts[2] == "ws",
                              parts[1] != "static"
                        else {
                            return channel.eventLoop.makeSucceededFuture(nil)
                        }

                        // 2. Origin allowlist: browsers don't enforce SOP on
                        // WebSocket handshake, so any page can otherwise
                        // initiate a WS to localhost:7777 and drive the user's
                        // VM. Missing Origin is allowed (non-browser clients
                        // like Python WS libs and command-line `wscat` don't
                        // send one). Match case-insensitively (browsers
                        // always send lowercase scheme/host, but be robust).
                        if let origin = head.headers["origin"].first {
                            let allowed: Swift.Set<String> = [
                                "http://127.0.0.1:\(port)",
                                "http://localhost:\(port)",
                            ]
                            guard allowed.contains(origin.lowercased()) else {
                                Logger.error("Rejecting WS upgrade: Origin not in allowlist",
                                    metadata: ["origin": origin])
                                return channel.eventLoop.makeSucceededFuture(nil)
                            }
                        }

                        // 3. VM existence: resolve via MainActor; reject if
                        // the VM isn't running or doesn't have VNC configured
                        // so the browser sees a clean 426 rather than a 101
                        // followed by an immediate close.
                        //
                        // 4. CRITICAL: remove HTTPChannelHandler from the
                        // pipeline before the upgrade completes. NIO adds the
                        // WS frame decoder at `.last` during upgrade, which
                        // ends up *after* HTTPChannelHandler — so the first
                        // post-upgrade WS frame reaches HTTPChannelHandler as
                        // raw IOData and crashes its force-cast to
                        // HTTPServerRequestPart. Doing this here (during
                        // shouldUpgrade) instead of in upgradePipelineHandler
                        // is essential: HTTPServerProtocolUpgradeHandler
                        // buffers exactly one read between shouldUpgrade
                        // returning and upgradePipelineHandler running, and
                        // that buffered byte arrives before our callback gets
                        // a chance to clean up the pipeline.
                        let vmName = NoVNCPath.extractVMName(fromWebSocketPath: head.uri) ?? ""

                        // 5. Subprotocol negotiation. noVNC's RFB client sends
                        // `Sec-WebSocket-Protocol: binary` in its handshake;
                        // when the server doesn't echo a matching value back
                        // in the 101 response, browsers fail the handshake
                        // with code 1006 / 1005 and noVNC reports "Connection
                        // closed". We accept "binary" (the only protocol we
                        // need to support today — RFB is a pure byte stream).
                        // If the client sent multiple proposals, echo the
                        // first match; otherwise omit the header entirely
                        // (RFC 6455: server may omit if it doesn't pick one,
                        // and curl / python / wscat all send no subprotocol).
                        let requestedProtocols = head.headers["sec-websocket-protocol"]
                            .flatMap { $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
                        let chosenProtocol: String? = requestedProtocols.contains("binary") ? "binary" : nil

                        let promise = channel.eventLoop.makePromise(of: HTTPHeaders?.self)
                        Task { @MainActor in
                            do {
                                _ = try resolveVNCEndpoint(forVM: vmName)
                                // Hop back to the event loop for the
                                // synchronous pipeline operation.
                                channel.eventLoop.execute {
                                    do {
                                        try channel.pipeline.syncOperations
                                            .removeHandler(name: Server.httpAppHandlerName)
                                        var responseHeaders = HTTPHeaders()
                                        if let chosenProtocol = chosenProtocol {
                                            responseHeaders.add(
                                                name: "Sec-WebSocket-Protocol",
                                                value: chosenProtocol)
                                        }
                                        promise.succeed(responseHeaders)
                                    } catch {
                                        Logger.error(
                                            "Rejecting WS upgrade: cannot remove HTTPChannelHandler",
                                            metadata: ["error": String(describing: error)])
                                        promise.succeed(nil)
                                    }
                                }
                            } catch {
                                Logger.info("Rejecting WS upgrade: VM resolution failed",
                                    metadata: ["vm": vmName, "error": error.localizedDescription])
                                promise.succeed(nil)
                            }
                        }
                        return promise.futureResult
                    },
                    upgradePipelineHandler: { (channel: any Channel, head: HTTPRequestHead) in
                        // HTTPChannelHandler was already removed in shouldUpgrade
                        // (see the comment there for why this can't be deferred
                        // until here). All we do is install the bridge.
                        let vmName = NoVNCPath.extractVMName(fromWebSocketPath: head.uri) ?? ""
                        return Server.installVNCBridge(on: channel, vmName: vmName)
                    }
                )

                return channel.pipeline.configureHTTPServerPipeline(
                    withServerUpgrade: (upgraders: [upgrader], completionHandler: { _ in })
                ).flatMap {
                    // Name the HTTP app handler so the WS upgrade path can
                    // remove it before bridging (see comment above).
                    channel.pipeline.addHandler(
                        HTTPChannelHandler(server: srv),
                        name: Server.httpAppHandlerName
                    )
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
    /// 1. Acquire a slot from BridgeRegistry. If the per-VM or total cap is
    ///    saturated, send a 1013 ("Try again later") close and bail.
    /// 2. Hop to MainActor to resolve the VM's VNC URL (vnc://:pw@host:port).
    ///    Returns a Sendable VNCEndpoint via an EventLoopPromise — all
    ///    pipeline / channel mutations happen on the event loop afterwards.
    /// 3. Open an outbound TCP connection to the VNC server on the same
    ///    event loop as the WS channel (cheap context switching for the
    ///    per-frame copy).
    /// 4. Delegate per-direction handler wireup to `wireBridge`, which is
    ///    Channel-protocol-typed (works with EmbeddedChannel for tests).
    /// 5. If anything fails, send a close frame so the browser sees a clean
    ///    disconnect rather than a hanging connection.
    static func installVNCBridge(on wsChannel: any Channel, vmName: String) -> EventLoopFuture<Void> {
        let promise = wsChannel.eventLoop.makePromise(of: Void.self)
        let eventLoop = wsChannel.eventLoop

        // Step 1: acquire a bridge slot. Reject with close-frame if saturated.
        Task {
            let acquired = await BridgeRegistry.shared.tryAcquire(vmName: vmName)
            if !acquired {
                Logger.error("VNC bridge: connection cap reached",
                    metadata: ["vm": vmName])
                eventLoop.execute {
                    // 1013 — "Try again later" (per RFC 6455 / RFC 7232 §11.7
                    // "WebSocket Close Code Number Registry"). NIO doesn't
                    // ship a named case for it, so use .unknown(1013).
                    sendCloseAndDrop(wsChannel: wsChannel, code: .unknown(1013))
                }
                promise.fail(BridgeError.tooManyConnections)
                return
            }
            // Ensure we release on close regardless of which side initiates.
            wsChannel.closeFuture.whenComplete { _ in
                Task { await BridgeRegistry.shared.release(vmName: vmName) }
            }

            // Step 2: resolve endpoint on MainActor; surface a Sendable
            // VNCEndpoint via a promise so the rest of the work stays on the
            // event loop. (Prior implementation mutated the pipeline from
            // MainActor context, violating NIO's loop-affinity invariant.)
            let endpointPromise = eventLoop.makePromise(of: VNCEndpoint.self)
            Task { @MainActor in
                do {
                    let ep = try resolveVNCEndpoint(forVM: vmName)
                    endpointPromise.succeed(ep)
                } catch {
                    endpointPromise.fail(error)
                }
            }

            endpointPromise.futureResult.hop(to: eventLoop).whenComplete { resolveResult in
                switch resolveResult {
                case .success(let endpoint):
                    Logger.info("VNC bridge: VM resolved",
                        metadata: ["vm": vmName, "host": endpoint.host, "port": "\(endpoint.port)"])

                    // Step 3: open the TCP socket. Both sides land on the
                    // same event loop, so per-frame forwarding is a single-
                    // threaded handoff with no cross-loop dispatch.
                    let bootstrap = ClientBootstrap(group: eventLoop)
                        .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)

                    bootstrap.connect(host: endpoint.host, port: endpoint.port)
                        .whenComplete { connectResult in
                            switch connectResult {
                            case .success(let tcpChannel):
                                // Step 4: install handlers + close-cascade.
                                wireBridge(ws: wsChannel, tcp: tcpChannel, vmName: vmName)
                                    .whenComplete { wireResult in
                                        switch wireResult {
                                        case .success:
                                            Logger.info("VNC bridge ready",
                                                metadata: ["vm": vmName])
                                            promise.succeed(())
                                        case .failure(let err):
                                            Logger.error("VNC bridge: handler install failed",
                                                metadata: ["vm": vmName, "error": err.localizedDescription])
                                            tcpChannel.close(promise: nil)
                                            sendCloseAndDrop(wsChannel: wsChannel, code: .unexpectedServerError)
                                            promise.fail(err)
                                        }
                                    }
                            case .failure(let err):
                                Logger.error("VNC bridge: TCP connect failed",
                                    metadata: ["vm": vmName, "error": err.localizedDescription])
                                sendCloseAndDrop(wsChannel: wsChannel, code: .unexpectedServerError)
                                promise.fail(err)
                            }
                        }

                case .failure(let err):
                    // Race: VM was running at shouldUpgrade-time but has since
                    // stopped, or some other transient failure. shouldUpgrade
                    // already gates the common case; this is the fallback.
                    Logger.error("VNC bridge: VM resolution failed post-upgrade",
                        metadata: ["vm": vmName, "error": err.localizedDescription])
                    sendCloseAndDrop(wsChannel: wsChannel, code: .unexpectedServerError)
                    promise.fail(err)
                }
            }
        }

        return promise.futureResult
    }

    /// Sends a WebSocket close frame with the given status code, then closes
    /// the channel. Runs on the channel's event loop.
    private static func sendCloseAndDrop(wsChannel: any Channel, code: WebSocketErrorCode) {
        var buf = wsChannel.allocator.buffer(capacity: 2)
        buf.write(webSocketErrorCode: code)
        let close = WebSocketFrame(fin: true, opcode: .connectionClose, data: buf)
        wsChannel.writeAndFlush(close).whenComplete { _ in
            wsChannel.close(promise: nil)
        }
    }
}

enum BridgeError: Error {
    case tooManyConnections
}
