import ArgumentParser
import Foundation

struct List: AsyncParsableCommand {
    static let configuration: CommandConfiguration = CommandConfiguration(
        commandName: "ls",
        abstract: "List virtual machines"
    )
    
    @Option(name: [.long, .customShort("f")], help: "Output format (json|text)")
    var format: FormatOption = .text
    
    init() {
    }
    
    @MainActor
    func run() async throws {
        let manager = LumeController()
        let vms = try manager.list()
        if vms.isEmpty && self.format == .text {
            print("No virtual machines found")
        } else {
            try VMDetailsPrinter.printStatus(vms, format: self.format)
        }
    }
}
