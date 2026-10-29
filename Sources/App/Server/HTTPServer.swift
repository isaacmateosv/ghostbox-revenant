// Minimal HTTP/1.1 server on 127.0.0.1 for the panel: request parsing, keep-alive, responses. Routing lives in
// APIRouter; this file knows nothing about the Mbox.

import Foundation
import Network

struct HTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]  // lower-cased names
    let body: Data
    let keepAlive: Bool
    let consumed: Int               // bytes of the buffer this request used (pipelining)

    func header(_ name: String) -> String? { headers[name.lowercased()] }

    /// Parses one request from the front of `data`, or nil while it is incomplete.
    init?(_ data: Data) {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: data[..<headerEnd.lowerBound], as: UTF8.self)
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ") ?? []
        guard parts.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()] =
                line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "") ?? 0
        let bodyStart = headerEnd.upperBound
        guard length >= 0, data.count - bodyStart >= length else { return nil }
        let http10 = parts.count >= 3 && parts[2] == "HTTP/1.0"
        let connection = headers["connection"]?.lowercased() ?? ""
        method = String(parts[0])
        path = String(parts[1]).components(separatedBy: "?")[0]
        self.headers = headers
        body = data.subdata(in: bodyStart..<(bodyStart + length))
        keepAlive = http10 ? connection.contains("keep-alive") : !connection.contains("close")
        consumed = bodyStart + length
    }
}

struct HTTPResponse {
    var status = 200
    var contentType = "application/json"
    var body = Data()

    static func json(_ obj: Any, status: Int = 200) -> HTTPResponse {
        HTTPResponse(status: status, contentType: "application/json", body: StateTree.json(obj))
    }

    static func jsonData(_ data: Data) -> HTTPResponse { HTTPResponse(body: data) }

    static func error(_ status: Int, _ message: String) -> HTTPResponse { json(["ok": false, "error": message], status: status) }

    static let reasons = [200: "OK", 400: "Bad Request", 403: "Forbidden", 404: "Not Found", 405: "Method Not Allowed",
                          409: "Conflict", 413: "Payload Too Large", 415: "Unsupported Media Type", 500: "Internal Server Error"]

    func serialized(keepAlive: Bool) -> Data {
        var head = "HTTP/1.1 \(status) \(HTTPResponse.reasons[status] ?? "OK")\r\nContent-Type: \(contentType)\r\n"
        head += "Content-Length: \(body.count)\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\n"
        head += "Connection: \(keepAlive ? "keep-alive" : "close")\r\n\r\n"
        return Data(head.utf8) + body
    }
}

final class HTTPServer {
    private let handler: (HTTPRequest) -> HTTPResponse
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "ghostbox.http", attributes: .concurrent)
    private(set) var port: UInt16 = 0
    static let maxRequestBytes = 4 << 20

    init(handler: @escaping (HTTPRequest) -> HTTPResponse) {
        self.handler = handler
    }

    /// Starts on the preferred port, or any free port if that one is taken. Calls back (main queue) with the port.
    func start(preferredPort: UInt16, ready: @escaping (UInt16) -> Void) {
        func attempt(_ p: UInt16) {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: p) ?? .any)
            guard let l = try? NWListener(using: params) else { if p != 0 { attempt(0) }; return }
            l.newConnectionHandler = { [weak self] c in self?.serve(c) }
            l.stateUpdateHandler = { [weak self] st in
                switch st {
                case .ready:
                    let bound = l.port?.rawValue ?? p
                    self?.port = bound
                    DispatchQueue.main.async { ready(bound) }
                case .failed:
                    l.cancel()
                    if p != 0 { attempt(0) }
                default: break
                }
            }
            listener = l
            l.start(queue: queue)
        }
        attempt(preferredPort)
    }

    private func serve(_ c: NWConnection) {
        c.start(queue: queue)
        receive(c, buffer: Data())
    }

    private func receive(_ c: NWConnection, buffer: Data) {
        // Keep-alive: the panel polls the meters ~16 times a second over one connection
        if let req = HTTPRequest(buffer) {
            respond(c, req, rest: buffer.count > req.consumed ? buffer.subdata(in: req.consumed..<buffer.count) : Data())
            return
        }
        c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, err in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }
            if HTTPRequest(buf) != nil {
                self.receive(c, buffer: buf)
            } else if done || err != nil || buf.count > HTTPServer.maxRequestBytes {
                c.cancel()
            } else {
                self.receive(c, buffer: buf)
            }
        }
    }

    private func respond(_ c: NWConnection, _ req: HTTPRequest, rest: Data) {
        let resp = handler(req)
        c.send(content: resp.serialized(keepAlive: req.keepAlive), completion: .contentProcessed { [weak self] e in
            if req.keepAlive && e == nil { self?.receive(c, buffer: rest) } else { c.cancel() }
        })
    }
}
