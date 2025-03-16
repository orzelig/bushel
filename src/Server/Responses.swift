import Foundation

struct APIError: Codable {
    let message: String
}

extension HTTPResponse {
    static func json<T: Encodable>(_ value: T) throws -> HTTPResponse {
        let data = try JSONEncoder().encode(value)
        return HTTPResponse(
            statusCode: .ok,
            headers: ["Content-Type": "application/json"],
            body: data
        )
    }
    
    static func badRequest(message: String) -> HTTPResponse {
        let error = APIError(message: message)
        return try! HTTPResponse(
            statusCode: .badRequest,
            headers: ["Content-Type": "application/json"],
            body: JSONEncoder().encode(error)
        )
    }
}