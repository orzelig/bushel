import ArgumentParser
import Foundation
import MCP

/// MCP response envelope helpers.
///
/// Every MCP tool returns a `CallTool.Result` whose text content is a JSON object
/// shaped like:
///
///     // success
///     { "ok": true,  "operation": "<op>", "result": { ... }, "message": "..." }
///     // error
///     { "ok": false, "operation": "<op>", "error": { "code": "<code>", "message": "..." } }
///
/// The `ok` field lets agents branch without parsing prose. The `error.code` field is
/// drawn from a stable, narrow vocabulary so retry decisions don't depend on string
/// matching `localizedDescription` text. A free-form `message` is preserved alongside
/// for human readability and for additional context the LLM might use.
enum MCPResponse {
    static func success(
        operation: String,
        result: [String: Any] = [:],
        resultArray: [Any]? = nil,
        message: String? = nil
    ) -> CallTool.Result {
        var payload: [String: Any] = ["ok": true, "operation": operation]
        if let resultArray = resultArray {
            payload["result"] = resultArray
        } else if !result.isEmpty {
            payload["result"] = result
        }
        if let message = message { payload["message"] = message }
        return makeResult(payload, isError: false)
    }

    static func error(
        operation: String,
        code: String,
        message: String
    ) -> CallTool.Result {
        let payload: [String: Any] = [
            "ok": false,
            "operation": operation,
            "error": ["code": code, "message": message],
        ]
        return makeResult(payload, isError: true)
    }

    /// Maps a Swift error to a stable string code from a small, finite vocabulary.
    /// Unrecognized errors fall through to `internal_error`. The vocabulary is
    /// documented in MCP-RESPONSE-CODES.md for agent authors.
    static func errorCode(for error: Error) -> String {
        switch error {
        case let e as VMError:
            switch e {
            case .alreadyExists: return "vm_already_exists"
            case .notFound: return "vm_not_found"
            case .notInitialized: return "vm_not_initialized"
            case .notRunning: return "vm_not_running"
            case .alreadyRunning: return "vm_already_running"
            case .stopTimeout: return "vm_stop_timeout"
            case .stillProvisioning: return "vm_still_provisioning"
            case .resizeTooSmall: return "vm_resize_too_small"
            case .vncNotConfigured, .vncPortBindingFailed: return "vm_vnc_unavailable"
            case .unsupportedOS: return "vm_unsupported_os"
            case .invalidDisplayResolution: return "validation_error"
            case .installNotStarted: return "vm_install_not_started"
            case .internalError: return "internal_error"
            }
        case let e as HomeError:
            switch e {
            case .vmDirectoryNotFound: return "vm_not_found"
            case .storageLocationNotFound,
                .storageLocationNotADirectory,
                .storageLocationNotWritable,
                .invalidStorageLocation,
                .defaultStorageNotDefined:
                return "storage_unavailable"
            default: return "home_error"
            }
        case is ValidationError: return "validation_error"
        case is PullError: return "pull_failed"
        case is ResticError: return "snapshot_error"
        case is SSHError: return "ssh_error"
        case is VMConfigError: return "validation_error"
        case is VMDirectoryError: return "vm_directory_error"
        case is UnattendedError: return "unattended_setup_error"
        default: return "internal_error"
        }
    }

    /// Convenience: wrap any thrown error into an error response.
    static func error(operation: String, throwing error: Error) -> CallTool.Result {
        return self.error(
            operation: operation,
            code: errorCode(for: error),
            message: error.localizedDescription
        )
    }

    // MARK: - Internal

    private static func makeResult(_ payload: [String: Any], isError: Bool) -> CallTool.Result {
        let data = (try? JSONSerialization.data(
            withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])) ?? Data()
        let text = String(data: data, encoding: .utf8) ?? "{}"
        return CallTool.Result(content: [.text(text)], isError: isError)
    }
}
