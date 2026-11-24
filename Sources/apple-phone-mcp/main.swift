import Foundation
import PhoneMCPCore

// Launcher only. Everything testable lives in PhoneMCPCore, which the test target
// imports; an executable target cannot be imported.
await PhoneMCPServer.run()
