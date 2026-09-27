import Foundation
import Darwin

/// Replaces an extension folder without removing the installed copy first.
enum ExtensionFiles {
    /// On success, an existing target is atomically swapped onto `staged`;
    /// callers own cleaning up that old folder after releasing its consumers.
    static func replace(_ staged: URL, at target: URL) throws {
        if let error = renameError(staged, target, flags: RENAME_EXCL) {
            guard error == EEXIST else { throw replacementError(error, staged: staged, target: target) }
            if let error = renameError(staged, target, flags: RENAME_SWAP) {
                throw replacementError(error, staged: staged, target: target)
            }
        }
    }

    /// A nil result means the rename worked. On failure, errno is read before
    /// doing anything else so the error describes the syscall that failed.
    private static func renameError(_ staged: URL, _ target: URL, flags: Int32) -> Int32? {
        staged.withUnsafeFileSystemRepresentation { source in
            target.withUnsafeFileSystemRepresentation { destination in
                guard let source, let destination else { return EINVAL }
                guard renamex_np(source, destination, UInt32(flags)) != 0 else { return nil }
                let error = errno
                return error
            }
        }
    }

    private static func replacementError(_ code: Int32, staged: URL, target: URL) -> NSError {
        let posix = NSError(domain: NSPOSIXErrorDomain, code: Int(code))
        return NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(code),
            userInfo: [
                NSLocalizedDescriptionKey: "Couldn't replace extension at \(target.path): \(posix.localizedDescription)",
                NSFilePathErrorKey: target.path,
                "ExtensionStagedPath": staged.path,
            ]
        )
    }
}
