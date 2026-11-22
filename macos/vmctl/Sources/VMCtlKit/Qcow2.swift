import Compression
import Foundation

/// Read-only qcow2 → raw converter.
///
/// Virtualization.framework only boots raw disk images, but almost every
/// distribution publishes its arm64 cloud images as qcow2 (only Debian
/// offers raw). Rather than asking users to install qemu-img, `create
/// --image` detects the qcow2 magic and converts while seeding the VM disk.
///
/// Scope: exactly what cloud images need — qcow2 v2/v3, zlib (raw deflate)
/// compressed clusters, zero clusters, sparse output. Anything outside that
/// (backing files, encryption, zstd compression, external data files) is
/// rejected with a clear error instead of producing a silently broken disk.
public enum Qcow2 {
    public static let magic: [UInt8] = [0x51, 0x46, 0x49, 0xFB] // "QFI\xfb"

    /// Whether the file starts with the qcow2 magic.
    public static func isQcow2(_ path: String) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }
        let head = try? handle.read(upToCount: 4)
        return head.map { Array($0) == magic } ?? false
    }

    struct Header {
        var version: UInt32
        var backingFileOffset: UInt64
        var clusterBits: UInt32
        var virtualSize: UInt64
        var cryptMethod: UInt32
        var l1Size: UInt32
        var l1TableOffset: UInt64
        var incompatibleFeatures: UInt64
        var compressionType: UInt8

        var clusterSize: Int { 1 << Int(clusterBits) }
    }

    static func readHeader(_ handle: FileHandle) throws -> Header {
        try handle.seek(toOffset: 0)
        guard let raw = try handle.read(upToCount: 112), raw.count >= 72 else {
            throw VmctlError("qcow2: file too short for a header")
        }
        func be32(_ offset: Int) -> UInt32 {
            (0..<4).reduce(UInt32(0)) { ($0 << 8) | UInt32(raw[offset + $1]) }
        }
        func be64(_ offset: Int) -> UInt64 {
            (0..<8).reduce(UInt64(0)) { ($0 << 8) | UInt64(raw[offset + $1]) }
        }
        guard Array(raw.prefix(4)) == magic else {
            throw VmctlError("qcow2: bad magic")
        }
        let version = be32(4)
        guard version == 2 || version == 3 else {
            throw VmctlError("qcow2: unsupported version \(version)")
        }
        var header = Header(
            version: version,
            backingFileOffset: be64(8),
            clusterBits: be32(20),
            virtualSize: be64(24),
            cryptMethod: be32(32),
            l1Size: be32(36),
            l1TableOffset: be64(40),
            incompatibleFeatures: 0,
            compressionType: 0
        )
        if version >= 3, raw.count >= 104 {
            header.incompatibleFeatures = be64(72)
            let headerLength = be32(100)
            if headerLength > 104, raw.count >= 105 {
                header.compressionType = raw[104]
            }
        }
        guard header.backingFileOffset == 0 else {
            throw VmctlError("qcow2: backing files are not supported")
        }
        guard header.cryptMethod == 0 else {
            throw VmctlError("qcow2: encrypted images are not supported")
        }
        guard header.compressionType == 0 else {
            throw VmctlError("qcow2: only zlib compression is supported")
        }
        // Bit 3 is "compression type present", fine on its own; the dirty
        // (0) and corrupt (1) bits mean the metadata cannot be trusted, and
        // anything higher is a format extension this reader predates.
        let blocking = header.incompatibleFeatures & ~UInt64(1 << 3)
        guard blocking == 0 else {
            throw VmctlError(
                "qcow2: image has unsupported feature bits (0x\(String(blocking, radix: 16)))")
        }
        guard header.clusterBits >= 9 && header.clusterBits <= 21 else {
            throw VmctlError("qcow2: implausible cluster size")
        }
        return header
    }

    /// Convert [from] into a sparse raw image at [to] (created/truncated).
    public static func convert(from: String, to path: String) throws {
        guard let input = FileHandle(forReadingAtPath: from) else {
            throw VmctlError("qcow2: cannot open \(from)")
        }
        defer { try? input.close() }
        let header = try readHeader(input)

        FileManager.default.createFile(atPath: path, contents: nil)
        guard let output = FileHandle(forWritingAtPath: path) else {
            throw VmctlError("qcow2: cannot create \(path)")
        }
        defer { try? output.close() }
        try output.truncate(atOffset: header.virtualSize)

        let clusterSize = header.clusterSize
        let l2Entries = clusterSize / 8

        try input.seek(toOffset: header.l1TableOffset)
        guard let l1Raw = try input.read(upToCount: Int(header.l1Size) * 8),
              l1Raw.count == Int(header.l1Size) * 8 else {
            throw VmctlError("qcow2: truncated L1 table")
        }

        func be64(_ data: Data, _ index: Int) -> UInt64 {
            (0..<8).reduce(UInt64(0)) {
                ($0 << 8) | UInt64(data[data.startIndex + index * 8 + $1])
            }
        }

        for l1Index in 0..<Int(header.l1Size) {
            let l1Entry = be64(l1Raw, l1Index)
            let l2Offset = l1Entry & 0x00FF_FFFF_FFFF_FE00
            if l2Offset == 0 { continue } // whole L2 range unallocated
            try input.seek(toOffset: l2Offset)
            guard let l2Raw = try input.read(upToCount: clusterSize),
                  l2Raw.count == clusterSize else {
                throw VmctlError("qcow2: truncated L2 table")
            }
            for l2Index in 0..<l2Entries {
                let entry = be64(l2Raw, l2Index)
                if entry == 0 { continue } // unallocated → stays sparse
                let guestOffset =
                    UInt64(l1Index * l2Entries + l2Index) * UInt64(clusterSize)
                if guestOffset >= header.virtualSize { break }

                let data: Data
                if entry & (1 << 62) != 0 {
                    data = try readCompressedCluster(
                        input, entry: entry, header: header)
                } else if entry & 1 != 0 {
                    continue // explicit all-zero cluster → stays sparse
                } else {
                    let hostOffset = entry & 0x00FF_FFFF_FFFF_FE00
                    try input.seek(toOffset: hostOffset)
                    guard let cluster = try input.read(upToCount: clusterSize),
                          cluster.count == clusterSize else {
                        throw VmctlError("qcow2: truncated data cluster")
                    }
                    data = cluster
                }
                if data.allSatisfy({ $0 == 0 }) { continue }
                try output.seek(toOffset: guestOffset)
                try output.write(contentsOf: data)
            }
        }
    }

    /// A compressed cluster: bits 0..x-1 are the byte offset, bits x..61 the
    /// count of additional 512-byte sectors; the payload is raw deflate.
    static func readCompressedCluster(
        _ input: FileHandle, entry: UInt64, header: Header
    ) throws -> Data {
        let x = 62 - (Int(header.clusterBits) - 8)
        let hostOffset = entry & ((UInt64(1) << x) - 1)
        let additionalSectors = (entry >> UInt64(x)) & ((UInt64(1) << (62 - x)) - 1)
        let byteSpan = Int((additionalSectors + 1) * 512 - (hostOffset % 512))

        try input.seek(toOffset: hostOffset)
        guard let compressed = try input.read(upToCount: byteSpan),
              !compressed.isEmpty else {
            throw VmctlError("qcow2: truncated compressed cluster")
        }

        let clusterSize = header.clusterSize
        var out = Data(count: clusterSize)
        let written = out.withUnsafeMutableBytes { dst in
            compressed.withUnsafeBytes { src in
                compression_decode_buffer(
                    dst.bindMemory(to: UInt8.self).baseAddress!, clusterSize,
                    src.bindMemory(to: UInt8.self).baseAddress!, compressed.count,
                    nil, COMPRESSION_ZLIB)
            }
        }
        guard written == clusterSize else {
            throw VmctlError("qcow2: compressed cluster did not inflate cleanly")
        }
        return out
    }
}
