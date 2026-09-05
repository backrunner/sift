import Foundation
import Darwin

/// Signed INT4 rows with per-block FP32/FP16 scales. The immutable installed
/// file is mapped read-only; only requested rows are expanded into the input
/// tensor. Installation must replace files by rename, never truncate in place.
public final class MappedTokenEmbedding: @unchecked Sendable {
    public static let modelABI = "sift-signal-mapped-embedding-v1"
    public static let relativePath = "Data/com.apple.CoreML/weights/token-embedding.siftemb"
    public static let inputName = "input_embeddings"
    public static let minimumAppBuild = 22

    public enum ReadError: Error {
        case invalidFile, mappingFailed, invalidTokenID, invalidOutputBuffer, nonFiniteScale
    }

    public let vocabularySize: Int
    public let width: Int
    private let blockSize: Int
    private let scaleBytes: Int
    private let rowStride: Int
    private let mapping: UnsafeMutableRawPointer
    private let byteCount: Int

    public static func url(modelURL: URL, modelABI: String) -> URL? {
        modelABI == Self.modelABI ? modelURL.appendingPathComponent(relativePath) : nil
    }

    public init(url: URL) throws {
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { throw ReadError.invalidFile }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size >= 64, info.st_size <= 2_147_483_647 else {
            throw ReadError.invalidFile
        }
        let count = Int(info.st_size)
        guard let address = mmap(nil, count, PROT_READ, MAP_PRIVATE, descriptor, 0),
              address != MAP_FAILED else { throw ReadError.mappingFailed }
        do {
            let bytes = UnsafeRawBufferPointer(start: address, count: count)
            func word(_ offset: Int) -> Int {
                Int(UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self)))
            }
            let rows = word(12), width = word(16), block = word(20)
            let scaleBytes = word(24), stride = word(28)
            guard bytes.prefix(8).elementsEqual(Array("SIFTEMB1".utf8)), word(8) == 1,
                  bytes[32..<64].allSatisfy({ $0 == 0 }),
                  (1...1_000_000).contains(rows), (2...4096).contains(width),
                  width % 2 == 0, block > 0, width % block == 0,
                  scaleBytes == 2 || scaleBytes == 4,
                  stride == width / 2 + width / block * scaleBytes,
                  count == 64 + rows * stride else { throw ReadError.invalidFile }
            self.mapping = address
            self.byteCount = count
            self.vocabularySize = rows
            self.width = width
            self.blockSize = block
            self.scaleBytes = scaleBytes
            self.rowStride = stride
        } catch {
            munmap(address, count)
            throw error
        }
    }

    deinit { munmap(mapping, byteCount) }

    /// Decodes directly into the caller's contiguous FP32 tensor without
    /// materializing a vocabulary-sized Swift array or a second tensor copy.
    public func decode(tokenIDs: [Int32], into output: UnsafeMutableBufferPointer<Float>) throws {
        guard tokenIDs.count <= Int.max / width, output.count == tokenIDs.count * width else {
            throw ReadError.invalidOutputBuffer
        }
        guard tokenIDs.allSatisfy({ $0 >= 0 && Int($0) < vocabularySize }) else {
            throw ReadError.invalidTokenID
        }
        let bytes = UnsafeRawBufferPointer(start: mapping, count: byteCount)
        for (position, token) in tokenIDs.enumerated() {
            let start = 64 + Int(token) * rowStride
            for block in 0..<(width / blockSize) {
                let offset = start + width / 2 + block * scaleBytes
                let scale: Float
                if scaleBytes == 4 {
                    scale = Float(bitPattern: UInt32(littleEndian:
                        bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self)))
                } else {
                    scale = Float(Float16(bitPattern: UInt16(littleEndian:
                        bytes.loadUnaligned(fromByteOffset: offset, as: UInt16.self))))
                }
                guard scale.isFinite else { throw ReadError.nonFiniteScale }
                for column in (block * blockSize)..<((block + 1) * blockSize) {
                    let packed = bytes[start + column / 2]
                    let nibble = Int((column % 2 == 0 ? packed : packed >> 4) & 15)
                    output[position * width + column] = Float(nibble >= 8 ? nibble - 16 : nibble) * scale
                }
            }
        }
    }
}
