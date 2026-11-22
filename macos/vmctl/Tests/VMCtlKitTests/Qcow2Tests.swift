import Compression
import Foundation
import Testing

@testable import VMCtlKit

/// Builds a minimal but valid qcow2 v3 in memory: 64 KiB clusters, one L1
/// entry, an L2 table, and whatever clusters the test asks for. qemu-img is
/// exactly the dependency the converter exists to avoid, so the fixture is
/// hand-assembled from the spec.
private struct Qcow2Builder {
    static let clusterBits: UInt32 = 16
    static let clusterSize = 1 << 16

    var virtualClusters: Int
    /// guest cluster index → raw content (nil entries stay unallocated)
    var clusters: [Int: [UInt8]] = [:]
    var zeroClusters: Set<Int> = []
    var compressedClusters: Set<Int> = []
    var backingFileOffset: UInt64 = 0
    var incompatibleFeatures: UInt64 = 0

    func build() -> Data {
        let clusterSize = Qcow2Builder.clusterSize
        let clusterBits = Qcow2Builder.clusterBits
        var file = Data(count: clusterSize) // cluster 0: header
        // cluster 1: L1, cluster 2: L2, data clusters from 3.
        var l1 = Data(count: clusterSize)
        var l2 = Data(count: clusterSize)
        var dataArea = Data()
        var nextHost = UInt64(3 * clusterSize)

        func putBE64(_ value: UInt64, into data: inout Data, at offset: Int) {
            for i in 0..<8 {
                data[offset + i] = UInt8((value >> (8 * (7 - i))) & 0xFF)
            }
        }

        for index in 0..<virtualClusters {
            if zeroClusters.contains(index) {
                putBE64(1, into: &l2, at: index * 8) // all-zero flag
                continue
            }
            guard let content = clusters[index] else { continue }
            if compressedClusters.contains(index) {
                var compressed = [UInt8](repeating: 0, count: clusterSize * 2)
                let count = content.withUnsafeBufferPointer { src in
                    compression_encode_buffer(
                        &compressed, compressed.count,
                        src.baseAddress!, content.count, nil, COMPRESSION_ZLIB)
                }
                precondition(count > 0)
                let payload = Data(compressed.prefix(count))
                let hostOffset = nextHost
                let x = 62 - (Int(clusterBits) - 8)
                let lastByte = hostOffset + UInt64(count) - 1
                let additional = (lastByte / 512) - (hostOffset / 512)
                var entry = hostOffset | (additional << UInt64(x))
                entry |= (1 << 62)
                putBE64(entry, into: &l2, at: index * 8)
                dataArea.append(payload)
                // keep host offsets sector-aligned for the next cluster
                let pad = (512 - (dataArea.count % 512)) % 512
                dataArea.append(Data(count: pad))
                nextHost += UInt64(count + pad)
            } else {
                putBE64(nextHost, into: &l2, at: index * 8)
                dataArea.append(Data(content))
                dataArea.append(Data(count: clusterSize - content.count))
                nextHost += UInt64(clusterSize)
            }
        }
        putBE64(UInt64(2 * clusterSize), into: &l1, at: 0)

        // Header
        var header = Data(count: 112)
        header.replaceSubrange(0..<4, with: Qcow2.magic)
        func hdrBE32(_ value: UInt32, _ offset: Int) {
            for i in 0..<4 { header[offset + i] = UInt8((value >> (8 * (3 - i))) & 0xFF) }
        }
        func hdrBE64(_ value: UInt64, _ offset: Int) {
            for i in 0..<8 { header[offset + i] = UInt8((value >> (8 * (7 - i))) & 0xFF) }
        }
        hdrBE32(3, 4) // version
        hdrBE64(backingFileOffset, 8)
        hdrBE32(clusterBits, 20)
        hdrBE64(UInt64(virtualClusters * clusterSize), 24)
        hdrBE32(1, 36) // l1_size
        hdrBE64(UInt64(clusterSize), 40) // l1_table_offset
        hdrBE64(incompatibleFeatures, 72)
        hdrBE32(104, 100) // header_length
        file.replaceSubrange(0..<header.count, with: header)

        return file + l1 + l2 + dataArea
    }
}

@Suite("Qcow2 conversion")
struct Qcow2Tests {
    func tempPath(_ name: String) -> String {
        NSTemporaryDirectory() + "qcow2-test-\(UUID().uuidString)-\(name)"
    }

    @Test("normal, compressed and zero clusters convert to a sparse raw")
    func convertsAllClusterKinds() throws {
        let cs = Qcow2Builder.clusterSize
        var builder = Qcow2Builder(virtualClusters: 4)
        builder.clusters[0] = [UInt8](repeating: 0xAB, count: cs)
        builder.zeroClusters.insert(1)
        builder.clusters[2] = Array((0..<cs).map { UInt8($0 % 251) })
        builder.compressedClusters.insert(2)
        // cluster 3 left unallocated

        let src = tempPath("src.qcow2")
        let dst = tempPath("dst.raw")
        try builder.build().write(to: URL(fileURLWithPath: src))
        defer { try? FileManager.default.removeItem(atPath: src) }
        defer { try? FileManager.default.removeItem(atPath: dst) }

        try Qcow2.convert(from: src, to: dst)

        let raw = try Data(contentsOf: URL(fileURLWithPath: dst))
        #expect(raw.count == 4 * cs)
        #expect(raw[0..<cs].allSatisfy { $0 == 0xAB })
        #expect(raw[cs..<(2 * cs)].allSatisfy { $0 == 0 })
        #expect(Array(raw[(2 * cs)..<(3 * cs)]) == builder.clusters[2]!)
        #expect(raw[(3 * cs)...].allSatisfy { $0 == 0 })
    }

    @Test("magic detection tells qcow2 from raw")
    func detectsMagic() throws {
        let qcow = tempPath("probe.qcow2")
        let raw = tempPath("probe.raw")
        try Qcow2Builder(virtualClusters: 1).build()
            .write(to: URL(fileURLWithPath: qcow))
        try Data(repeating: 0x51, count: 1024).write(to: URL(fileURLWithPath: raw))
        defer { try? FileManager.default.removeItem(atPath: qcow) }
        defer { try? FileManager.default.removeItem(atPath: raw) }

        #expect(Qcow2.isQcow2(qcow))
        #expect(!Qcow2.isQcow2(raw))
        #expect(!Qcow2.isQcow2(qcow + "-missing"))
    }

    @Test("backing files and unknown feature bits are refused")
    func rejectsUnsupported() throws {
        var withBacking = Qcow2Builder(virtualClusters: 1)
        withBacking.backingFileOffset = 512
        var withFeatures = Qcow2Builder(virtualClusters: 1)
        withFeatures.incompatibleFeatures = 1 << 4

        for (name, builder) in [("backing", withBacking), ("features", withFeatures)] {
            let src = tempPath("\(name).qcow2")
            let dst = tempPath("\(name).raw")
            try builder.build().write(to: URL(fileURLWithPath: src))
            defer { try? FileManager.default.removeItem(atPath: src) }
            #expect(throws: VmctlError.self) {
                try Qcow2.convert(from: src, to: dst)
            }
        }
    }
}
