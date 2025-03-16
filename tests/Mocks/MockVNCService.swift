import Foundation
@testable import lume

@MainActor
final class MockVNCService: VNCService {
    private(set) var url: String?
    private(set) var isRunning = false
    private(set) var clientOpenCount = 0
    private var _attachedVM: Any?
    private let vmDirectory: VMDirectory
    
    init(vmDirectory: VMDirectory) {
        self.vmDirectory = vmDirectory
    }
    
    nonisolated var attachedVM: String? {
        get async {
            await Task { @MainActor in
                _attachedVM as? String
            }.value
        }
    }
    
    func start(port: Int, virtualMachine: Any?) async throws {
        isRunning = true
        url = "vnc://localhost:\(port)"
        _attachedVM = virtualMachine
    }
    
    func stop() {
        isRunning = false
        url = nil
        _attachedVM = nil
    }
    
    func openClient(url: String) async throws {
        guard isRunning else {
            throw VMError.vncNotConfigured
        }
        clientOpenCount += 1
    }
} 