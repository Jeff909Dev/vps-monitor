import Foundation

public struct CommandOutput: Sendable, Equatable {
    public var status: Int32
    public var stdout: Data
    public var stderr: Data

    public init(status: Int32, stdout: Data, stderr: Data) {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
    }
}

public enum CommandError: Error, Equatable {
    case timedOut
}

public protocol CommandRunning: Sendable {
    /// Runs to completion with `stdin` as its standard input (nothing when nil) and captures both streams. Past the
    /// timeout, or when the calling task is cancelled, the process is terminated and the call throws.
    func run(_ executable: URL, _ arguments: [String], stdin: Data?, timeout: TimeInterval) async throws
        -> CommandOutput
}

public struct ProcessCommandRunner: CommandRunning {
    public init() {}

    /// Owns the child. A cancel that arrives before launch is remembered, so the process is never started.
    private final class Box: @unchecked Sendable {
        let process = Process()
        private let lock = NSLock()
        private var cancelled = false

        func launch() throws {
            lock.lock()
            defer { lock.unlock() }
            if cancelled { throw CancellationError() }
            try process.run()
        }

        /// SIGTERM now; SIGKILL after a grace period for a child that ignores it.
        func terminate() {
            lock.lock()
            cancelled = true
            let pid: pid_t? = process.isRunning ? process.processIdentifier : nil
            lock.unlock()
            guard let pid else { return }
            kill(pid, SIGTERM)
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) { [self] in
                if process.isRunning { kill(pid, SIGKILL) }
            }
        }
    }

    /// Collects a stream off the cooperative pool; both pipes are drained while the child runs, so a large status
    /// never blocks it on a full pipe.
    private final class Sink: @unchecked Sendable {
        var data = Data()
    }

    public func run(_ executable: URL, _ arguments: [String], stdin: Data?, timeout: TimeInterval) async throws
        -> CommandOutput {
        let box = Box()
        box.process.executableURL = executable
        box.process.arguments = arguments
        let input = stdin.map { _ in Pipe() }
        box.process.standardInput = input ?? FileHandle.nullDevice
        let out = Pipe(), err = Pipe()
        box.process.standardOutput = out
        box.process.standardError = err

        return try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: CommandOutput.self) { group in
                group.addTask {
                    try await withCheckedThrowingContinuation { continuation in
                        let done = DispatchGroup()
                        let stdout = Sink(), stderr = Sink()
                        done.enter()
                        box.process.terminationHandler = { _ in done.leave() }
                        do { try box.launch() } catch {
                            continuation.resume(throwing: error)
                            return
                        }
                        if let input, let stdin {
                            // Written off the cooperative pool, and closed, so the child sees the end of its input.
                            // A child that exits before reading it all makes the write fail with EPIPE instead of
                            // killing the app with SIGPIPE.
                            _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
                            DispatchQueue.global().async {
                                try? input.fileHandleForWriting.write(contentsOf: stdin)
                                try? input.fileHandleForWriting.close()
                            }
                        }
                        for (pipe, sink) in [(out, stdout), (err, stderr)] {
                            done.enter()
                            DispatchQueue.global().async {
                                sink.data = pipe.fileHandleForReading.readDataToEndOfFile()
                                done.leave()
                            }
                        }
                        done.notify(queue: .global()) {
                            continuation.resume(returning: CommandOutput(status: box.process.terminationStatus,
                                                                         stdout: stdout.data, stderr: stderr.data))
                        }
                    }
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(timeout))
                    throw CommandError.timedOut
                }
                defer {
                    group.cancelAll()
                    box.terminate()
                }
                guard let output = try await group.next() else { throw CommandError.timedOut }
                try Task.checkCancellation()
                return output
            }
        } onCancel: {
            box.terminate()
        }
    }
}
