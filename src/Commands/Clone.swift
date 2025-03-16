import ArgumentParser
import Foundation

struct Clone: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Clone an existing virtual machine"
    )
    
    @Argument(help: "Name of the source virtual machine", completion: .custom(completeVMName))
    var name: String
    
    @Argument(help: "Name for the cloned virtual machine")
    var newName: String
    
    init() {}
    
    @MainActor
    func run() async throws {
        let vmController = LumeController()
        try vmController.clone(name: name, newName: newName)
    }
}