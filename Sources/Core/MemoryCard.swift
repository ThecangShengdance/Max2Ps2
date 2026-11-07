// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 ThecangShengdance
//
//  MemoryCard.swift
//  Max2Ps2
//
//  PS2 8MB 记忆卡（.ps2 镜像）的读写：
//   - 解析 / 格式化超级块（superblock）
//   - FAT 链的读写与簇分配
//   - 目录项（dirent）的读写
//   - 列出已有存档、导入存档（含重名覆盖）、删除存档
//   - 写页时自动重算 ECC
//
//  格式说明参考 mymc（ps2mc.py）。标准 8MB 卡：页 512B + spare 16B = 528B，
//  每簇 2 页（1024B），共 16384 页、8192 簇；FAT 从逻辑簇 41 开始可分配。
//

import Foundation

// MARK: - 几何参数

struct CardGeometry {
    var pageSize = 512
    var pagesPerCluster = 2
    var pagesPerEraseBlock = 16
    var clustersPerCard = 8192
    var allocatableOffset = 41
    var allocatableEnd = 8135
    var rootCluster = 0
    var goodBlock1 = 1023
    var goodBlock2 = 1022
    var ifcList: [UInt32] = [8]
    var cardType: UInt8 = 2
    var cardFlags: UInt8 = 0x2B
    var version: String = "1.2.0.0"

    static let standard = CardGeometry()

    var clusterSize: Int { pageSize * pagesPerCluster }
    var entriesPerCluster: Int { clusterSize / 4 }
    var direntsPerCluster: Int { clusterSize / 512 }
    var spareSize: Int { 16 }
    var rawPageSize: Int { pageSize + spareSize }
    var pagesPerCard: Int { clustersPerCard * pagesPerCluster }
    var fatClusterCount: Int { (clustersPerCard + entriesPerCluster - 1) / entriesPerCluster }
}

// MARK: - 目录项

struct Dirent {
    var mode: UInt16 = 0
    var unknown: UInt16 = 0
    var length: UInt32 = 0
    var created: [UInt8] = [UInt8](repeating: 0, count: 8)
    var cluster: UInt32 = 0
    var parentEntry: UInt32 = 0
    var modified: [UInt8] = [UInt8](repeating: 0, count: 8)
    var attr: UInt32 = 0
    var name: String = ""

    static let dirMode: UInt16 = 0x8427      // DF_RWX | DF_0400 | DF_DIR | DF_EXISTS
    static let fileMode: UInt16 = 0x8417     // DF_RWX | DF_0400 | DF_FILE | DF_EXISTS
    static let dotdotMode: UInt16 = 0xA426   // 与 mymc 一致：写 ".." 时带 DF_HIDDEN

    var exists: Bool { mode & 0x8000 != 0 }
    var isDirectory: Bool { mode & 0x0020 != 0 }
    var isFile: Bool { mode & 0x0010 != 0 }

    init() {}

    init(bytes: [UInt8]) {
        mode = bytes.u16(0)
        unknown = bytes.u16(2)
        length = bytes.u32(4)
        created = Array(bytes[8..<16])
        cluster = bytes.u32(16)
        parentEntry = bytes.u32(20)
        modified = Array(bytes[24..<32])
        attr = bytes.u32(32)
        name = EntryName.cString(bytes[64..<512])
    }

    func packed() -> [UInt8] {
        var out = [UInt8](repeating: 0, count: 512)
        out.putU16(0, mode)
        out.putU16(2, unknown)
        out.putU32(4, length)
        for i in 0..<8 { out[8 + i] = created[i] }
        out.putU32(16, cluster)
        out.putU32(20, parentEntry)
        for i in 0..<8 { out[24 + i] = modified[i] }
        out.putU32(32, attr)
        let nameBytes = Array(name.utf8.prefix(447))
        for (i, b) in nameBytes.enumerated() { out[64 + i] = b }
        return out
    }
}

// MARK: - 存档摘要

struct CardSave: Identifiable {
    struct FileInfo: Identifiable {
        var id: String { name }
        var name: String
        var bytes: Int
    }

    var id: String { name }
    var name: String
    var files: [FileInfo]
    var bytes: Int
    var modified: Date?
}

struct ImportReport {
    var dirName: String
    var fileCount: Int
    var totalBytes: Int
    var replacedExisting: Bool
    var freeClustersBefore: Int
    var freeClustersAfter: Int
}

// MARK: - 记忆卡

final class MemoryCard {
    static let standardFileSize = 16_384 * 528   // 8,650,752
    static let magic: [UInt8] = Array("Sony PS2 Memory Card Format ".utf8)

    static let fatFree: UInt32 = 0x7FFF_FFFF
    static let fatChainEnd: UInt32 = 0xFFFF_FFFF
    static let fatAllocatedBit: UInt32 = 0x8000_0000

    private(set) var raw: [UInt8]
    private(set) var geometry: CardGeometry
    private(set) var isFormatted: Bool
    private var fat: [UInt32]
    private var fatPhysicalClusters: [Int]
    private var fatCursor = 1

    let url: URL

    // MARK: 打开

    init(url: URL) throws {
        let data = try Data(contentsOf: url)
        self.url = url
        self.raw = [UInt8](data)
        self.geometry = .standard
        self.fat = []
        self.fatPhysicalClusters = []
        self.isFormatted = false

        guard raw.count == Self.standardFileSize else {
            throw ToolError("记忆卡文件大小应为 8,650,752 字节（标准 8MB 卡），当前为 \(raw.count) 字节。\n请选择 PCSX2 的 Mcd001.ps2 这类标准 8MB 记忆卡。")
        }
        if raw.starts(with: Self.magic) {
            try loadSuperblock()
            try loadFAT()
            isFormatted = true
            fatCursor = 1
        }
    }

    private init(url: URL, raw: [UInt8]) {
        self.url = url
        self.raw = raw
        self.geometry = .standard
        self.fat = []
        self.fatPhysicalClusters = []
        self.isFormatted = false
    }

    /// 新建并格式化一张 8MB 记忆卡。
    static func createFormatted(at url: URL, timestamp: Date = Date()) throws -> MemoryCard {
        let card = MemoryCard(url: url, raw: [UInt8](repeating: 0, count: standardFileSize))
        card.format(timestamp: timestamp)
        try card.save(to: url, backup: false)
        return card
    }

    func loadSuperblock() throws {
        let sb = raw
        let versionBytes = Array(sb[0x1C..<0x28])
        let version = EntryName.cString(versionBytes[...]).trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
        let pageSize = Int(sb.u16(0x28))
        let pagesPerCluster = Int(sb.u16(0x2A))
        let pagesPerEraseBlock = Int(sb.u16(0x2C))
        let clustersPerCard = Int(sb.u32(0x30))
        let allocOffset = Int(sb.u32(0x34))
        let allocEnd = Int(sb.u32(0x38))
        let rootCluster = Int(sb.u32(0x3C))
        let good1 = Int(sb.u32(0x40))
        let good2 = Int(sb.u32(0x44))

        guard pageSize == 512, pagesPerCluster == 2, pagesPerEraseBlock > 0 else {
            throw ToolError("这张记忆卡的规格不受支持（页 \(pageSize) 字节 / 簇 \(pagesPerCluster) 页）。本工具只支持标准 8MB 卡。")
        }
        let pagesPerCard = raw.count / 528
        guard clustersPerCard > 0, clustersPerCard * pagesPerCluster == pagesPerCard,
              allocOffset > 0, allocEnd > allocOffset, allocEnd <= clustersPerCard,
              rootCluster < clustersPerCard else {
            throw ToolError("记忆卡超级块数据异常，无法安全读写。")
        }

        var ifc: [UInt32] = []
        for i in 0..<32 { ifc.append(sb.u32(0x50 + i * 4)) }

        geometry = CardGeometry(pageSize: pageSize,
                                pagesPerCluster: pagesPerCluster,
                                pagesPerEraseBlock: pagesPerEraseBlock,
                                clustersPerCard: clustersPerCard,
                                allocatableOffset: allocOffset,
                                allocatableEnd: allocEnd,
                                rootCluster: rootCluster,
                                goodBlock1: good1,
                                goodBlock2: good2,
                                ifcList: ifc,
                                cardType: sb[0x150],
                                cardFlags: sb[0x151],
                                version: version.isEmpty ? "1.2.0.0" : version)
    }

    // MARK: 页 / 簇 IO

    private func readPage(_ page: Int) -> [UInt8] {
        let start = page * geometry.rawPageSize
        guard start >= 0, start + geometry.pageSize <= raw.count else {
            return [UInt8](repeating: 0, count: geometry.pageSize)
        }
        return Array(raw[start..<(start + geometry.pageSize)])
    }

    private func writePage(_ page: Int, _ data: [UInt8]) {
        guard data.count == geometry.pageSize else { return }
        let start = page * geometry.rawPageSize
        guard start >= 0, start + geometry.rawPageSize <= raw.count else { return }
        for i in 0..<geometry.pageSize { raw[start + i] = data[i] }
        let ecc = PS2ECC.page(data)
        for i in 0..<12 { raw[start + geometry.pageSize + i] = ecc[i] }
        for i in 12..<geometry.spareSize { raw[start + geometry.pageSize + i] = 0 }
    }

    private func readPhysicalCluster(_ cluster: Int) -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(geometry.clusterSize)
        let firstPage = cluster * geometry.pagesPerCluster
        for p in 0..<geometry.pagesPerCluster {
            out.append(contentsOf: readPage(firstPage + p))
        }
        return out
    }

    private func writePhysicalCluster(_ cluster: Int, _ data: [UInt8]) {
        let firstPage = cluster * geometry.pagesPerCluster
        for p in 0..<geometry.pagesPerCluster {
            let start = p * geometry.pageSize
            let end = start + geometry.pageSize
            if end <= data.count {
                writePage(firstPage + p, Array(data[start..<end]))
            } else {
                writePage(firstPage + p, [UInt8](repeating: 0, count: geometry.pageSize))
            }
        }
    }

    private func readCluster(_ cluster: Int) -> [UInt8] {
        readPhysicalCluster(cluster + geometry.allocatableOffset)
    }

    private func writeCluster(_ cluster: Int, _ data: [UInt8]) {
        writePhysicalCluster(cluster + geometry.allocatableOffset, data)
    }

    // MARK: FAT

    private func loadFAT() throws {
        let epc = geometry.entriesPerCluster
        guard let indirect = geometry.ifcList.first, indirect != 0,
              Int(indirect) < geometry.clustersPerCard else {
            throw ToolError("记忆卡的 FAT 索引异常。")
        }
        let indirectData = readPhysicalCluster(Int(indirect))
        var physical: [Int] = []
        physical.reserveCapacity(geometry.fatClusterCount)
        for n in 0..<geometry.fatClusterCount {
            let slot = n % epc
            let value = indirectData.u32(slot * 4)
            guard value != 0xFFFF_FFFF, Int(value) < geometry.clustersPerCard else {
                throw ToolError("记忆卡的 FAT 链损坏（第 \(n) 个 FAT 簇无效）。")
            }
            physical.append(Int(value))
        }
        var entries: [UInt32] = []
        entries.reserveCapacity(geometry.fatClusterCount * epc)
        for cluster in physical {
            let data = readPhysicalCluster(cluster)
            for i in 0..<epc { entries.append(data.u32(i * 4)) }
        }
        fatPhysicalClusters = physical
        fat = entries
    }

    /// 把内存里的 FAT 写回镜像（尚未落盘）。
    func flushFAT() {
        let epc = geometry.entriesPerCluster
        for (n, cluster) in fatPhysicalClusters.enumerated() {
            var data = [UInt8](repeating: 0, count: geometry.clusterSize)
            let base = n * epc
            for i in 0..<epc {
                let value = (base + i) < fat.count ? fat[base + i] : Self.fatChainEnd
                data.putU32(i * 4, value)
            }
            writePhysicalCluster(cluster, data)
        }
    }

    func fatValue(_ index: Int) -> UInt32 {
        guard index >= 0, index < fat.count else { return Self.fatChainEnd }
        return fat[index]
    }

    private func setFat(_ index: Int, _ value: UInt32) {
        guard index >= 0, index < fat.count else { return }
        fat[index] = value
    }

    func freeClusterCount() -> Int {
        guard isFormatted, !fat.isEmpty else { return 0 }
        var count = 0
        for i in 1..<geometry.allocatableEnd where fat[i] & Self.fatAllocatedBit == 0 {
            count += 1
        }
        return count
    }

    var freeBytes: Int { freeClusterCount() * geometry.clusterSize }

    var capacityBytes: Int { (geometry.allocatableEnd - 1) * geometry.clusterSize }

    /// 返回一簇的链（逻辑簇号）。
    func clusterChain(_ first: Int) -> [Int] {
        guard first >= 0, first < geometry.clustersPerCard else { return [] }
        var chain: [Int] = []
        var current = first
        var seen = Set<Int>()
        while current < geometry.clustersPerCard {
            if seen.contains(current) { break }
            seen.insert(current)
            chain.append(current)
            let value = fatValue(current)
            if value == Self.fatChainEnd { break }
            if value & Self.fatAllocatedBit != 0 {
                current = Int(value & 0x7FFF_FFFF)
            } else {
                break
            }
            if chain.count > geometry.clustersPerCard { break }
        }
        return chain
    }

    private func findFreeCluster(from start: Int) -> Int? {
        let begin = max(start, 1)
        if begin < geometry.allocatableEnd {
            for i in begin..<geometry.allocatableEnd where fat[i] & Self.fatAllocatedBit == 0 {
                return i
            }
        }
        for i in 1..<min(begin, geometry.allocatableEnd) where fat[i] & Self.fatAllocatedBit == 0 {
            return i
        }
        return nil
    }

    /// 分配一串连续链接好的簇。
    private func allocateChain(count: Int) throws -> [Int] {
        guard count > 0 else { return [] }
        let free = freeClusterCount()
        guard free >= count else {
            throw ToolError("记忆卡空间不足：需要 \(count) 个簇（\(Format.bytes(count * geometry.clusterSize))），当前仅剩 \(free) 个（\(Format.bytes(free * geometry.clusterSize))）。")
        }
        var clusters: [Int] = []
        var search = max(fatCursor, 1)
        while clusters.count < count {
            guard let next = findFreeCluster(from: search) else {
                throw ToolError("记忆卡空间不足（无法找到空闲簇）。")
            }
            setFat(next, Self.fatChainEnd)
            clusters.append(next)
            search = next + 1
            fatCursor = search
        }
        if clusters.count > 1 {
            for i in 0..<(clusters.count - 1) {
                setFat(clusters[i], UInt32(clusters[i + 1]) | Self.fatAllocatedBit)
            }
        }
        return clusters
    }

    private func freeChain(_ first: Int) {
        for cluster in clusterChain(first) {
            setFat(cluster, Self.fatFree)
        }
    }

    // MARK: 目录项

    private func dirents(firstCluster: Int, count: Int) throws -> [Dirent] {
        guard count > 0 else { return [] }
        let chain = clusterChain(firstCluster)
        guard !chain.isEmpty else { return [] }
        var buffers = chain.map { readCluster($0) }
        let capacity = buffers.count * geometry.direntsPerCluster
        if count > capacity {
            // 长度字段比实际链更长：只读链内条目
            buffers = Array(buffers.prefix(capacity))
        }
        var result: [Dirent] = []
        result.reserveCapacity(min(count, capacity))
        for i in 0..<min(count, capacity) {
            let bufferIndex = i / geometry.direntsPerCluster
            let offset = (i % geometry.direntsPerCluster) * 512
            let slice = Array(buffers[bufferIndex][offset..<(offset + 512)])
            result.append(Dirent(bytes: slice))
        }
        return result
    }

    private func writeDirent(firstCluster: Int, index: Int, dirent: Dirent) throws {
        let chain = clusterChain(firstCluster)
        let bufferIndex = index / geometry.direntsPerCluster
        guard bufferIndex < chain.count else {
            throw ToolError("目录空间不足（内部错误）。")
        }
        let offset = (index % geometry.direntsPerCluster) * 512
        var buffer = readCluster(chain[bufferIndex])
        let packed = dirent.packed()
        for i in 0..<512 { buffer[offset + i] = packed[i] }
        writeCluster(chain[bufferIndex], buffer)
    }

    private func ensureDirectoryCapacity(firstCluster: Int, neededEntries: Int) throws {
        var chain = clusterChain(firstCluster)
        while chain.count * geometry.direntsPerCluster < neededEntries {
            let newCluster = try allocateChain(count: 1)[0]
            writeCluster(newCluster, [UInt8](repeating: 0, count: geometry.clusterSize))
            if let last = chain.last {
                setFat(last, UInt32(newCluster) | Self.fatAllocatedBit)
            }
            setFat(newCluster, Self.fatChainEnd)
            chain.append(newCluster)
        }
    }

    private func rootDirents() throws -> [Dirent] {
        guard isFormatted else { throw ToolError("记忆卡尚未格式化。") }
        let dot = try dirents(firstCluster: geometry.rootCluster, count: 1)
        let count = max(Int(dot.first?.length ?? 2), 2)
        return try dirents(firstCluster: geometry.rootCluster, count: count)
    }

    // MARK: 存储卡内容

    func listSaves() throws -> [CardSave] {
        let root = try rootDirents()
        var saves: [CardSave] = []
        guard root.count > 2 else { return [] }
        for i in 2..<root.count {
            let entry = root[i]
            guard entry.exists, entry.isDirectory else { continue }
            let inner = try dirents(firstCluster: Int(entry.cluster), count: Int(entry.length))
            var files: [CardSave.FileInfo] = []
            var bytes = 0
            if inner.count > 2 {
                for j in 2..<inner.count {
                    let file = inner[j]
                    guard file.exists, !file.isDirectory else { continue }
                    files.append(CardSave.FileInfo(name: file.name, bytes: Int(file.length)))
                    bytes += Int(file.length)
                }
            }
            saves.append(CardSave(name: entry.name,
                                  files: files,
                                  bytes: bytes,
                                  modified: ToD.date(from: entry.modified[...])))
        }
        return saves
    }

    func containsSave(named name: String) throws -> Bool {
        let root = try rootDirents()
        for i in 2..<root.count where root[i].exists && root[i].name == name {
            return true
        }
        return false
    }

    @discardableResult
    func deleteSave(named name: String) throws -> Bool {
        let root = try rootDirents()
        guard let index = (2..<root.count).first(where: { root[$0].exists && root[$0].name == name }) else {
            return false
        }
        let entry = root[index]
        if entry.isDirectory {
            let inner = try dirents(firstCluster: Int(entry.cluster), count: Int(entry.length))
            if inner.count > 2 {
                for j in 2..<inner.count {
                    let child = inner[j]
                    guard child.exists, !child.isDirectory else { continue }
                    freeChain(Int(child.cluster))
                }
            }
            freeChain(Int(entry.cluster))
        } else {
            freeChain(Int(entry.cluster))
        }
        var cleared = entry
        cleared.mode = 0
        cleared.length = 0
        cleared.cluster = Self.fatChainEnd
        cleared.modified = ToD.now()
        try writeDirent(firstCluster: geometry.rootCluster, index: index, dirent: cleared)
        return true
    }

    // MARK: 导入

    func importSave(_ files: [MaxSaveFile],
                    as rawName: String,
                    overwrite: Bool,
                    timestamp: Date = Date()) throws -> ImportReport {
        guard isFormatted else { throw ToolError("记忆卡尚未格式化，无法导入。") }
        let name = EntryName.sanitizeEntryName(rawName)
        guard !name.isEmpty else { throw ToolError("存档目录名不能为空。") }
        guard name.utf8.count <= 32 else {
            throw ToolError("存档目录名最长 32 个字节（当前 \(name.utf8.count)）。")
        }
        guard !files.isEmpty else { throw ToolError("这个存档里没有可导入的文件。") }
        for file in files where file.name.utf8.count > 447 {
            throw ToolError("文件名过长：\(file.name)")
        }
        let entryNames = files.map { EntryName.sanitizeEntryName($0.name) }
        guard Set(entryNames).count == entryNames.count else {
            throw ToolError("存档内有重名文件，无法导入。")
        }

        let freeBefore = freeClusterCount()
        var root = try rootDirents()
        var replaced = false

        if let existing = (2..<root.count).first(where: { root[$0].exists && root[$0].name == name }) {
            guard overwrite else {
                throw ToolError("记忆卡上已存在同名存档「\(name)」。")
            }
            let entry = root[existing]
            if entry.isDirectory {
                let inner = try dirents(firstCluster: Int(entry.cluster), count: Int(entry.length))
                if inner.count > 2 {
                    for j in 2..<inner.count where inner[j].exists && !inner[j].isDirectory {
                        freeChain(Int(inner[j].cluster))
                    }
                }
                freeChain(Int(entry.cluster))
            }
            var cleared = entry
            cleared.mode = 0
            cleared.length = 0
            cleared.cluster = Self.fatChainEnd
            cleared.modified = ToD.now()
            try writeDirent(firstCluster: geometry.rootCluster, index: existing, dirent: cleared)
            root = try rootDirents()
            replaced = true
        }

        var slot: Int? = nil
        if root.count > 2 {
            for i in 2..<root.count where !root[i].exists {
                slot = i
                break
            }
        }
        let slotIndex = slot ?? max(root.count, 2)
        try ensureDirectoryCapacity(firstCluster: geometry.rootCluster, neededEntries: slotIndex + 1)

        let now = ToD.bytes(from: timestamp)
        let dirCluster = try allocateChain(count: 1)[0]
        writeCluster(dirCluster, [UInt8](repeating: 0, count: geometry.clusterSize))

        var dirEntry = Dirent()
        dirEntry.mode = Dirent.dirMode
        dirEntry.length = UInt32(2 + files.count)
        dirEntry.created = now
        dirEntry.cluster = UInt32(dirCluster)
        dirEntry.parentEntry = 0
        dirEntry.modified = now
        dirEntry.name = name
        try writeDirent(firstCluster: geometry.rootCluster, index: slotIndex, dirent: dirEntry)

        // 根目录的条目总数记录在根目录 "." 项的 length 字段里。
        let newRootCount = max(root.count, slotIndex + 1)
        if newRootCount != root.count, var dot = root.first {
            dot.length = UInt32(newRootCount)
            try writeDirent(firstCluster: geometry.rootCluster, index: 0, dirent: dot)
        }

        try ensureDirectoryCapacity(firstCluster: dirCluster, neededEntries: 2 + files.count)

        var dot = Dirent()
        dot.mode = Dirent.dirMode
        dot.length = 0
        dot.created = now
        dot.cluster = UInt32(geometry.rootCluster)
        dot.parentEntry = UInt32(slotIndex)
        dot.modified = now
        dot.name = "."
        try writeDirent(firstCluster: dirCluster, index: 0, dirent: dot)

        var dotdot = Dirent()
        dotdot.mode = Dirent.dotdotMode
        dotdot.length = 0
        dotdot.created = now
        dotdot.cluster = 0
        dotdot.parentEntry = 0
        dotdot.modified = now
        dotdot.name = ".."
        try writeDirent(firstCluster: dirCluster, index: 1, dirent: dotdot)

        var totalBytes = 0
        for (offset, file) in files.enumerated() {
            let fileName = EntryName.sanitizeEntryName(file.name)
            let clustersNeeded = (file.data.count + geometry.clusterSize - 1) / geometry.clusterSize
            var firstCluster = Self.fatChainEnd
            if clustersNeeded > 0 {
                let chain = try allocateChain(count: clustersNeeded)
                firstCluster = UInt32(chain[0])
                writeFileData(file.data, clusters: chain)
            }
            totalBytes += file.data.count

            var entry = Dirent()
            entry.mode = Dirent.fileMode
            entry.length = UInt32(file.data.count)
            entry.created = now
            entry.cluster = firstCluster
            entry.parentEntry = 0
            entry.modified = now
            entry.name = fileName
            try writeDirent(firstCluster: dirCluster, index: 2 + offset, dirent: entry)
        }

        flushFAT()

        return ImportReport(dirName: name,
                            fileCount: files.count,
                            totalBytes: totalBytes,
                            replacedExisting: replaced,
                            freeClustersBefore: freeBefore,
                            freeClustersAfter: freeClusterCount())
    }

    private func writeFileData(_ data: [UInt8], clusters: [Int]) {
        let clusterSize = geometry.clusterSize
        for (index, cluster) in clusters.enumerated() {
            let start = index * clusterSize
            var buffer = [UInt8](repeating: 0, count: clusterSize)
            let end = min(start + clusterSize, data.count)
            if start < end {
                for i in start..<end { buffer[i - start] = data[i] }
            }
            writeCluster(cluster, buffer)
        }
    }

    // MARK: 格式化

    /// 按 mymc 的方式就地格式化（整张卡重建）。会清空所有内容。
    func format(timestamp: Date = Date()) {
        geometry = .standard
        fatPhysicalClusters = (0..<geometry.fatClusterCount).map {
            geometry.allocatableOffset - geometry.fatClusterCount + $0
        }

        var newRaw = [UInt8](repeating: 0, count: Self.standardFileSize)
        let zeroECC = PS2ECC.page([UInt8](repeating: 0, count: 512))
        for page in 0..<geometry.pagesPerCard {
            let base = page * geometry.rawPageSize + geometry.pageSize
            for i in 0..<12 { newRaw[base + i] = zeroECC[i] }
        }
        raw = newRaw

        var newFat = [UInt32](repeating: Self.fatChainEnd, count: geometry.clustersPerCard)
        for i in 1..<geometry.allocatableEnd { newFat[i] = Self.fatFree }
        newFat[0] = Self.fatChainEnd
        fat = newFat
        isFormatted = true
        fatCursor = 1

        // 间接 FAT 簇：记录各 FAT 簇的物理簇号
        var indirect = [UInt32](repeating: 0xFFFF_FFFF, count: geometry.entriesPerCluster)
        for (i, cluster) in fatPhysicalClusters.enumerated() { indirect[i] = UInt32(cluster) }
        // 间接 FAT 簇的物理位置由超级块 ifc_list[0] 指定（标准 8MB 卡为物理簇 8），
        // 其后紧跟 32 个 FAT 簇（物理 9..40），再往后的逻辑簇 41 起才可分配。
        writePhysicalCluster(Int(geometry.ifcList[0]), packU32(indirect))
        flushFAT()

        let now = ToD.bytes(from: timestamp)
        var rootData = [UInt8](repeating: 0, count: geometry.clusterSize)
        var rootDot = Dirent()
        rootDot.mode = Dirent.dirMode
        rootDot.length = 2
        rootDot.created = now
        rootDot.cluster = 0
        rootDot.parentEntry = 0
        rootDot.modified = now
        rootDot.name = "."
        var rootDotDot = Dirent()
        rootDotDot.mode = Dirent.dotdotMode
        rootDotDot.length = 0
        rootDotDot.created = now
        rootDotDot.cluster = 0
        rootDotDot.parentEntry = 0
        rootDotDot.modified = now
        rootDotDot.name = ".."
        let packedDot = rootDot.packed()
        let packedDotDot = rootDotDot.packed()
        for i in 0..<512 {
            rootData[i] = packedDot[i]
            rootData[512 + i] = packedDotDot[i]
        }
        writeCluster(0, rootData)

        // 被保留的倒数第二个擦除块（good_block2）写成 0xFF，与真实卡一致
        let startPage = geometry.goodBlock2 * geometry.pagesPerEraseBlock
        for page in startPage..<(startPage + geometry.pagesPerEraseBlock) {
            let base = page * geometry.rawPageSize
            guard base + geometry.rawPageSize <= raw.count else { break }
            for i in 0..<geometry.rawPageSize { raw[base + i] = 0xFF }
        }

        writePage(0, superblockBytes())
    }

    private func superblockBytes() -> [UInt8] {
        var sb = [UInt8](repeating: 0, count: geometry.pageSize)
        for (i, b) in Self.magic.enumerated() { sb[i] = b }
        let version = Array("1.2.0.0".utf8)
        for (i, b) in version.enumerated() { sb[0x1C + i] = b }
        sb.putU16(0x28, UInt16(geometry.pageSize))
        sb.putU16(0x2A, UInt16(geometry.pagesPerCluster))
        sb.putU16(0x2C, UInt16(geometry.pagesPerEraseBlock))
        sb.putU16(0x2E, 0xFF00)
        sb.putU32(0x30, UInt32(geometry.clustersPerCard))
        sb.putU32(0x34, UInt32(geometry.allocatableOffset))
        sb.putU32(0x38, UInt32(geometry.allocatableEnd))
        sb.putU32(0x3C, UInt32(geometry.rootCluster))
        sb.putU32(0x40, UInt32(geometry.goodBlock1))
        sb.putU32(0x44, UInt32(geometry.goodBlock2))
        for i in 0..<32 {
            let value: UInt32 = i < geometry.ifcList.count ? geometry.ifcList[i] : 0
            sb.putU32(0x50 + i * 4, value)
        }
        for i in 0..<32 { sb.putU32(0xD0 + i * 4, 0xFFFF_FFFF) }
        sb[0x150] = geometry.cardType
        sb[0x151] = geometry.cardFlags
        return sb
    }

    private func packU32(_ values: [UInt32]) -> [UInt8] {
        var data = [UInt8](repeating: 0, count: values.count * 4)
        for (i, v) in values.enumerated() { data.putU32(i * 4, v) }
        return data
    }

    /// 读出某个存档目录下的全部文件（供导出/校验使用）。
    func extractSave(named name: String) throws -> [(String, [UInt8])] {
        let root = try rootDirents()
        guard let index = (2..<root.count).first(where: { root[$0].exists && root[$0].name == name }) else {
            throw ToolError("记忆卡上找不到存档「\(name)」。")
        }
        let entry = root[index]
        guard entry.isDirectory else {
            throw ToolError("「\(name)」不是存档目录。")
        }
        let inner = try dirents(firstCluster: Int(entry.cluster), count: Int(entry.length))
        var result: [(String, [UInt8])] = []
        if inner.count > 2 {
            for j in 2..<inner.count {
                let file = inner[j]
                guard file.exists, file.isFile else { continue }
                var data: [UInt8] = []
                for cluster in clusterChain(Int(file.cluster)) {
                    let remaining = Int(file.length) - data.count
                    guard remaining > 0 else { break }
                    let buffer = readCluster(cluster)
                    data.append(contentsOf: buffer.prefix(min(remaining, buffer.count)))
                }
                result.append((file.name, data))
            }
        }
        return result
    }

    /// 校验整张卡的 ECC（只比对，不纠错）。
    func verifyECC() throws -> (badPages: Int, totalPages: Int) {
        guard isFormatted else { throw ToolError("记忆卡尚未格式化。") }
        var bad = 0
        for page in 0..<geometry.pagesPerCard {
            let data = readPage(page)
            let expected = PS2ECC.page(data)
            let base = page * geometry.rawPageSize
            // 擦除块（整页 0xFF）没有有效 ECC，跳过。
            let erasedSpare = (0..<geometry.spareSize).allSatisfy { raw[base + geometry.pageSize + $0] == 0xFF }
            if erasedSpare { continue }
            var matches = true
            for i in 0..<12 where raw[base + geometry.pageSize + i] != expected[i] {
                matches = false
                break
            }
            if !matches { bad += 1 }
        }
        return (bad, geometry.pagesPerCard)
    }

    // MARK: 落盘

    func save(to url: URL, backup: Bool) throws {
        // FAT 改动先落进 raw，避免删除/分配后的空闲簇丢失（否则卡上会留下 lost clusters）
        if isFormatted, !fat.isEmpty {
            flushFAT()
        }
        if backup, FileManager.default.fileExists(atPath: url.path) {
            let stamp = Self.backupStamp()
            let backupURL = url.deletingLastPathComponent()
                .appendingPathComponent("\(url.lastPathComponent).bak-\(stamp)")
            try? FileManager.default.removeItem(at: backupURL)
            try FileManager.default.copyItem(at: url, to: backupURL)
        }
        try Data(raw).write(to: url, options: .atomic)
    }

    static func backupStamp(_ date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }
}
