import Darwin
import Foundation

enum CompanionAppLocator {
    static var currentExecutableURL: URL? {
        var bufferSize: UInt32 = 0
        guard _NSGetExecutablePath(nil, &bufferSize) == -1, bufferSize > 0 else {
            return nil
        }

        var buffer = [CChar](repeating: 0, count: Int(bufferSize))
        let result = buffer.withUnsafeMutableBufferPointer { pointer in
            _NSGetExecutablePath(pointer.baseAddress, &bufferSize)
        }
        guard result == 0 else {
            return nil
        }

        return buffer.withUnsafeBufferPointer { pointer in
            guard let baseAddress = pointer.baseAddress else {
                return nil
            }
            return URL(
                fileURLWithFileSystemRepresentation: baseAddress,
                isDirectory: false,
                relativeTo: nil
            )
            .standardizedFileURL
            .resolvingSymlinksInPath()
        }
    }

    static func containingAppURL(forExecutableURL executableURL: URL) -> URL? {
        let macOSURL = executableURL.deletingLastPathComponent()
        guard macOSURL.lastPathComponent == "MacOS" else {
            return nil
        }

        let contentsURL = macOSURL.deletingLastPathComponent()
        guard contentsURL.lastPathComponent == "Contents" else {
            return nil
        }

        let appURL = contentsURL.deletingLastPathComponent()
        guard appURL.pathExtension == "app" else {
            return nil
        }
        return appURL
    }
}
