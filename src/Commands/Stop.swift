import ArgumentParser
import Foundation

struct Stop: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Stop a virtual machine"
    )

    @Argument(help: "Name of the virtual machine", completion: .custom(completeVMName))
    var name: String
    
    init() {
    }

    @MainActor
    func run() async throws {
        let vmController = LumeController()
        try await vmController.stopVM(name: name)
    }
}