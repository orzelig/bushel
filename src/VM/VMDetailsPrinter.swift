import Foundation

/// Prints VM status information in a formatted table
enum VMDetailsPrinter {
    /// Represents a column in the VM status table
    private struct Column: Sendable {
        let header: String
        let width: Int
        let getValue: @Sendable (VMDetails) -> String
    }
    
    /// Configuration for all columns in the status table
    private static let columns: [Column] = [
        Column(header: "name", width: 34, getValue: { $0.name }),
        Column(header: "os", width: 8, getValue: { $0.os }),
        Column(header: "cpu", width: 8, getValue: { String($0.cpuCount) }),
        Column(header: "memory", width: 8, getValue: { 
            String(format: "%.2fG", Float($0.memorySize) / (1024 * 1024 * 1024))
        }),
        Column(header: "disk", width: 16, getValue: { 
            "\($0.diskSize.formattedAllocated)/\($0.diskSize.formattedTotal)"
        }),
        Column(header: "display", width: 12, getValue: { $0.display }),
        Column(header: "status", width: 16, getValue: { 
            $0.status
        }),
        Column(header: "ip", width: 16, getValue: {
            $0.ipAddress ?? "-"
        }),
        Column(header: "vnc", width: 50, getValue: {
            $0.vncUrl ?? "-"
        })
    ]
    
    /// Prints the status of all VMs in a formatted table
    /// - Parameter vms: Array of VM status objects to display
    static func printStatus(_ vms: [VMDetails], format: FormatOption, print: (String) -> () = { print($0) }) throws {
        if format == .json {
            let jsonEncoder = JSONEncoder()
            jsonEncoder.outputFormatting = .prettyPrinted
            let jsonData = try jsonEncoder.encode(vms)
            let jsonString = String(data: jsonData, encoding: .utf8)!
            print(jsonString)
        } else {
            printHeader(print: print)
            vms.forEach({ printVM($0, print: print)})
        }
    }
    
    private static func printHeader(print: (String) -> () = { print($0) }) {
        let paddedHeaders = columns.map { $0.header.paddedToWidth($0.width) }
        print(paddedHeaders.joined())
    }
    
    private static func printVM(_ vm: VMDetails, print: (String) -> Void = { print($0) }) {
        let paddedColumns = columns.map { column in
            column.getValue(vm).paddedToWidth(column.width)
        }
        print(paddedColumns.joined())
    }
}

private extension String {
    /// Pads the string to the specified width with spaces
    /// - Parameter width: Target width for padding
    /// - Returns: Padded string
    func paddedToWidth(_ width: Int) -> String {
        padding(toLength: width, withPad: " ", startingAt: 0)
    }
}
