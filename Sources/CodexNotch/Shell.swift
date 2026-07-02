import Foundation
import Darwin
import SQLite3

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

    static func sqliteJSON<T: Decodable>(database: String, query: String, as type: T.Type) throws -> T {
        let data = try SQLiteJSONReader.query(database: database, query: query)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            if data.isEmpty,
               let decoded = try? JSONDecoder().decode(T.self, from: Data("[]".utf8)) {
                return decoded
            }
            throw ShellError.decodeFailed(error.localizedDescription)
        }
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

private enum SQLiteJSONReader {
    static func query(database: String, query: String) throws -> Data {
        var connection: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(database, &connection, flags, nil) == SQLITE_OK,
              let connection else {
            let message = connection.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            if let connection {
                sqlite3_close(connection)
            }
            throw ShellError.nonZeroExit("sqlite3", 1, message)
        }
        defer {
            sqlite3_close(connection)
        }

        sqlite3_busy_timeout(connection, 1_000)

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection, query, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw ShellError.nonZeroExit("sqlite3", 1, String(cString: sqlite3_errmsg(connection)))
        }
        defer {
            sqlite3_finalize(statement)
        }

        let columnCount = sqlite3_column_count(statement)
        var rows: [[String: Any]] = []

        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE {
                break
            }
            guard status == SQLITE_ROW else {
                throw ShellError.nonZeroExit("sqlite3", 1, String(cString: sqlite3_errmsg(connection)))
            }

            var row: [String: Any] = [:]
            for index in 0..<columnCount {
                let name = sqlite3_column_name(statement, index).map(String.init(cString:)) ?? "column_\(index)"
                row[name] = value(statement: statement, column: index)
            }
            rows.append(row)
        }

        return try JSONSerialization.data(withJSONObject: rows, options: [])
    }

    private static func value(statement: OpaquePointer, column: Int32) -> Any {
        switch sqlite3_column_type(statement, column) {
        case SQLITE_INTEGER:
            return NSNumber(value: sqlite3_column_int64(statement, column))
        case SQLITE_FLOAT:
            return NSNumber(value: sqlite3_column_double(statement, column))
        case SQLITE_TEXT:
            guard let text = sqlite3_column_text(statement, column) else {
                return NSNull()
            }
            return String(cString: text)
        case SQLITE_BLOB:
            guard let bytes = sqlite3_column_blob(statement, column) else {
                return NSNull()
            }
            let count = Int(sqlite3_column_bytes(statement, column))
            return Data(bytes: bytes, count: count).base64EncodedString()
        default:
            return NSNull()
        }
    }
}
