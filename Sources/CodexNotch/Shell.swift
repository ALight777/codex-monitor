import Foundation
import Darwin

enum ShellError: Error, LocalizedError {
    case launchFailed(String)
    case timedOut(String, TimeInterval, String)
    case nonZeroExit(String, Int32, String)
    case decodeFailed(String)

    var errorDescription: String? {
        switch self {
        case .launchFailed(let executable):
            "无法启动 \(executable)。"
        case .timedOut(let executable, let timeout, let output):
            output.isEmpty
                ? "\(executable) timed out after \(Int(timeout.rounded()))s"
                : "\(executable) timed out after \(Int(timeout.rounded()))s: \(output)"
        case .nonZeroExit(let executable, let status, let output):
            "\(executable) exited with status \(status): \(output)"
        case .decodeFailed(let detail):
            "无法解析命令输出：\(detail)"
        }
    }
}

enum Shell {
    static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval? = nil) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        do {
            try process.run()
        } catch {
            throw ShellError.launchFailed(executable)
        }

        if let timeout {
            let completed = DispatchSemaphore(value: 0)
            DispatchQueue.global(qos: .utility).async {
                process.waitUntilExit()
                completed.signal()
            }

            let milliseconds = max(1, Int((timeout * 1_000).rounded()))
            if completed.wait(timeout: .now() + .milliseconds(milliseconds)) == .timedOut {
                terminateProcessTree(rootPID: process.processIdentifier, signal: SIGTERM)
                if completed.wait(timeout: .now() + .milliseconds(200)) == .timedOut {
                    terminateProcessTree(rootPID: process.processIdentifier, signal: SIGKILL)
                    _ = completed.wait(timeout: .now() + .milliseconds(300))
                }

                try? outputPipe.fileHandleForReading.close()
                throw ShellError.timedOut(executable, timeout, "")
            }

            let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(decoding: outputData, as: UTF8.self)

            guard process.terminationStatus == 0 else {
                throw ShellError.nonZeroExit(executable, process.terminationStatus, output)
            }

            return output
        }

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(decoding: outputData, as: UTF8.self)
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw ShellError.nonZeroExit(executable, process.terminationStatus, output)
        }

        return output
    }

    static func sqliteJSON<T: Decodable>(
        database: String,
        query: String,
        as type: T.Type,
        readOnly: Bool = false
    ) throws -> T {
        var arguments = ["-json"]
        if readOnly {
            arguments.append("-readonly")
        }
        arguments.append(contentsOf: [database, query])

        let output = try run("/usr/bin/sqlite3", arguments)
        let trimmedOutput = output.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = sqliteJSONPayload(from: trimmedOutput)
        let data = Data(candidate.utf8)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            if trimmedOutput.isEmpty,
               let decoded = try? JSONDecoder().decode(T.self, from: Data("[]".utf8)) {
                return decoded
            }
            throw ShellError.decodeFailed(error.localizedDescription)
        }
    }

    private static func sqliteJSONPayload(from output: String) -> String {
        guard let start = output.firstIndex(where: { $0 == "[" || $0 == "{" }) else {
            return output
        }

        let close: Character = output[start] == "[" ? "]" : "}"
        guard let end = output.lastIndex(of: close), end >= start else {
            return String(output[start...])
        }

        return String(output[start...end])
    }

    static func terminateProcessTree(rootPID: pid_t, signal: Int32) {
        for pid in descendantProcessIDs(of: rootPID).reversed() {
            kill(pid, signal)
        }
        kill(rootPID, signal)
    }

    private static func descendantProcessIDs(of rootPID: pid_t) -> [pid_t] {
        let relationships = processRelationships()
        var descendants: [pid_t] = []
        var stack = relationships[rootPID] ?? []

        while let pid = stack.popLast() {
            descendants.append(pid)
            stack.append(contentsOf: relationships[pid] ?? [])
        }

        return descendants
    }

    private static func processRelationships() -> [pid_t: [pid_t]] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,ppid="]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return [:]
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let output = String(decoding: data, as: UTF8.self)
        var relationships: [pid_t: [pid_t]] = [:]

        for line in output.split(separator: "\n") {
            let parts = line.split(whereSeparator: \.isWhitespace)
            guard parts.count >= 2,
                  let pid = pid_t(parts[0]),
                  let ppid = pid_t(parts[1]) else {
                continue
            }
            relationships[ppid, default: []].append(pid)
        }

        return relationships
    }
}
