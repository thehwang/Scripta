import Foundation

private let logFile: FileHandle? = {
    let dir = NSHomeDirectory() + "/Documents/MeetingPilotScripts"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let path = dir + "/debug.log"
    FileManager.default.createFile(atPath: path, contents: nil)
    return FileHandle(forWritingAtPath: path)
}()

public func mplog(_ msg: String) {
    let ts = ISO8601DateFormatter().string(from: Date())
    let line = "[\(ts)] \(msg)\n"
    if let data = line.data(using: .utf8) {
        logFile?.seekToEndOfFile()
        logFile?.write(data)
    }
}
