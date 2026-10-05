import Darwin
import FortiBarCore
import Foundation

// Usage: FortiBarHelper --uid <console-user-uid>
// Runs as root (LaunchDaemon). Only the given user may talk to it.

var allowedUID: uid_t?
var arguments = CommandLine.arguments.dropFirst().makeIterator()
while let argument = arguments.next() {
    switch argument {
    case "--uid":
        if let value = arguments.next(), let uid = uid_t(value) { allowedUID = uid }
    case "--version":
        print(HelperProtocol.version)
        exit(0)
    default:
        break
    }
}

guard geteuid() == 0 else {
    FileHandle.standardError.write(Data("FortiBarHelper must run as root.\n".utf8))
    exit(1)
}
guard let allowedUID else {
    FileHandle.standardError.write(Data("usage: FortiBarHelper --uid <uid>\n".utf8))
    exit(2)
}

let helper = Helper(allowedUID: allowedUID)
helper.run()
