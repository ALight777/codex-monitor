import Foundation
import CZstd

/// Decoder-only zstd is linked into the app; reading Codex archives never needs Homebrew
/// or an unpacked copy of the user's conversation on disk.
enum CodexZstdReader {
    enum ReadError: Error { case allocationFailed, invalidStream, truncatedStream }

    static func read(
        path: String,
        isCancelled: @Sendable () -> Bool,
        consume: (UnsafeRawBufferPointer) throws -> Void
    ) throws {
        guard let stream = ZSTD_createDStream() else { throw ReadError.allocationFailed }
        defer { ZSTD_freeDStream(stream) }
        guard ZSTD_isError(ZSTD_initDStream(stream)) == 0 else { throw ReadError.invalidStream }
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        let capacity = ZSTD_DStreamOutSize()
        let output = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: 8)
        defer { output.deallocate() }
        var remaining = 1
        var sawInput = false
        while true {
            // FileHandle can return autoreleased NSData. Drain each input block so
            // a background scan does not retain the whole compressed history.
            let readMore = try autoreleasepool {
                guard let chunk = try handle.read(upToCount: ZSTD_DStreamInSize()), !chunk.isEmpty else {
                    return false
                }
                sawInput = true
                try chunk.withUnsafeBytes { bytes in
                    var input = ZSTD_inBuffer(src: bytes.baseAddress, size: bytes.count, pos: 0)
                    var outputWasFull = false
                    repeat {
                        guard !isCancelled() else { throw CancellationError() }
                        var decoded = ZSTD_outBuffer(dst: output, size: capacity, pos: 0)
                        remaining = ZSTD_decompressStream(stream, &decoded, &input)
                        guard ZSTD_isError(remaining) == 0 else { throw ReadError.invalidStream }
                        if decoded.pos > 0 {
                            try consume(UnsafeRawBufferPointer(start: output, count: decoded.pos))
                        }
                        outputWasFull = decoded.pos == capacity
                    } while input.pos < input.size || (outputWasFull && remaining != 0)
                }
                return true
            }
            if !readMore { break }
        }
        // A truncated stream can have already yielded valid token events. Reject the
        // whole file instead of publishing a deceptively complete partial total.
        guard sawInput, remaining == 0 else { throw ReadError.truncatedStream }
    }
}
