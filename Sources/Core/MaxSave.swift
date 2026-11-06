//
//  MaxSave.swift
//  Max2Ps2
//
//  Datel MAX Drive（".max"，magic "Ps2PowerSave"）存档解析。
//
//  文件结构（92 字节头，小端）：
//    struct "<12sL32s32sLLL"
//      magic[12]      "Ps2PowerSave"
//      crc32          头部 + 压缩体的 CRC32（只用于校验，可忽略）
//      dirname[32]    记忆卡上的存档目录名（NUL 结尾）
//      iconsysname[32] 图标标题（很多工具留空）
//      clen           压缩体长度 + 4（压缩体从 0x5C 开始）
//      dirlen         文件个数
//      length         解压后长度
//  解压后按 dirlen 重复：u32 长度 + 32 字节文件名 + 数据，每项后补 0 对齐。
//

import Foundation

struct MaxSaveFile {
    var name: String
    var data: [UInt8]
}

struct MaxSave {
    var dirName: String
    var iconSysName: String
    var files: [MaxSaveFile]
    var compressedLength: Int
    var uncompressedLength: Int
    var sourceURL: URL?
    var title: String?

    var totalBytes: Int { files.reduce(0) { $0 + $1.data.count } }

    var iconSys: MaxSaveFile? {
        files.first { $0.name.lowercased() == "icon.sys" }
    }

    var dataFiles: [MaxSaveFile] {
        files.filter { $0.name.lowercased() != "icon.sys" }
    }

    /// 生成导入用的文件列表。真实的 PS2 存档里，数据文件通常与存档目录同名
    /// （例如 /BISLPS-25441/BISLPS-25441）。当 .max 里的数据文件与 .max 内目录名同名、
    /// 而用户把目录名改成了别的值时，可同步改名，避免游戏按目录名找数据文件时找不到。
    func filesForImport(newDirName: String, renameDataFile: Bool) -> [MaxSaveFile] {
        guard renameDataFile else { return files }
        let old = EntryName.sanitizeEntryName(dirName)
        guard !old.isEmpty, old != newDirName else { return files }
        let otherNames = Set(files.filter { $0.name != old }.map { $0.name })
        guard !otherNames.contains(newDirName) else { return files }
        return files.map { file in
            guard file.name == old else { return file }
            var renamed = file
            renamed.name = newDirName
            return renamed
        }
    }

    /// .max 内的目录名长于 12 位且前 12 位是标准游戏 ID（如 BISLPS-25441）时给出建议。
    /// 不少网络存档是被二次转换工具改写过目录名的，游戏本体仍按 12 位 ID 查找存档。
    /// 如果目录名是「12 位标准 ID + 后缀」的形式，返回前 12 位。
    /// 注意：只是备选方案，默认应当使用 .max 内的原始目录名——很多游戏
    /// （例如《奥特曼格斗进化 3》的 BISLPS-25441icoULTR3）本来就不用 12 位 ID。
    var standardSuggestion: String? {
        let name = dirName
        guard name.count > 12 else { return nil }
        let prefix = String(name.prefix(12))
        return Self.isStandardDirName(prefix) ? prefix : nil
    }

    var dirNameLooksStandard: Bool {
        Self.isStandardDirName(dirName)
    }

    static func isStandardDirName(_ name: String) -> Bool {
        let chars = Array(name)
        guard chars.count == 12 else { return false }
        guard chars[0] == "B" else { return false }
        for i in 1...5 where !(chars[i].isASCII && chars[i].isLetter) { return false }
        guard chars[6] == "-" else { return false }
        for i in 7...11 where !(chars[i].isASCII && chars[i].isNumber) { return false }
        return true
    }

    /// 读取 icon.sys 里的 SHIFT-JIS 标题。
    static func parseIconTitle(_ data: [UInt8]) -> String? {
        guard data.count >= 0x104 else { return nil }
        guard data[0] == 0x50, data[1] == 0x53, data[2] == 0x32, data[3] == 0x44 else { return nil }
        var titleBytes = Array(data[0xC0..<0x104])
        if let zero = titleBytes.firstIndex(of: 0) {
            titleBytes = Array(titleBytes[0..<zero])
        }
        let text = String(data: Data(titleBytes), encoding: .shiftJIS)
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty ?? true) ? nil : trimmed
    }

    /// 11 位形式（SLPS-25441）也接受，用于判断目录名是否可疑。
    static func gameIDPrefix(of name: String) -> String? {
        let chars = Array(name)
        guard chars.count >= 11 else { return nil }
        if chars.count >= 12, isStandardDirName(String(chars.prefix(12))) {
            return String(chars.prefix(12))
        }
        // SLPS-25441
        guard chars.count >= 11 else { return nil }
        for i in 0..<4 where !(chars[i].isASCII && chars[i].isLetter) { return nil }
        guard chars[4] == "-" else { return nil }
        for i in 5..<10 where !(chars[i].isASCII && chars[i].isNumber) { return nil }
        return String(chars.prefix(11))
    }

    var fileSummary: String {
        let icon = files.contains { $0.name.lowercased() == "icon.sys" } ? "含图标" : "无图标"
        return "\(files.count) 个文件 · \(Format.bytes(totalBytes)) · \(icon)"
    }
}

enum MaxSaveParser {
    static let magic: [UInt8] = Array("Ps2PowerSave".utf8)
    static let headerLength = 0x5C

    static func parse(url: URL) throws -> MaxSave {
        let data = try Data(contentsOf: url)
        var save = try parse(Array(data))
        save.sourceURL = url
        return save
    }

    static func parse(_ data: [UInt8]) throws -> MaxSave {
        guard data.count >= headerLength else {
            throw ToolError("文件太小，不是有效的 .max 存档")
        }
        guard Array(data[0..<12]) == magic else {
            throw ToolError("不是 Datel MAX Drive 存档（文件头不是 Ps2PowerSave）")
        }

        let dirNameRaw = EntryName.cString(data[0x10..<0x30])
        let iconSysNameRaw = EntryName.cString(data[0x30..<0x50])
        let clen = Int(data.u32(0x50))
        let dirlen = Int(data.u32(0x54))
        let length = Int(data.u32(0x58))

        guard dirlen > 0, dirlen <= 4096 else {
            throw ToolError("存档头中的文件数量异常（\(dirlen)）")
        }
        guard length > 0, length <= LZARI.maxOutputLength else {
            throw ToolError("存档头中的解压长度异常（\(length) 字节）")
        }

        var compressed: [UInt8]
        if clen == length {
            // 少数工具在这个字段里写的是未压缩长度，此时压缩体一直延续到文件尾。
            compressed = Array(data[headerLength...])
        } else {
            let compressedLength = max(clen - 4, 0)
            guard headerLength + compressedLength <= data.count else {
                throw ToolError("存档数据不完整：头部声明压缩体 \(compressedLength) 字节，实际不足")
            }
            compressed = Array(data[headerLength..<(headerLength + compressedLength)])
        }
        if compressed.isEmpty {
            throw ToolError("存档压缩体为空，文件可能已损坏")
        }

        let payload = try LZARI.decode(compressed, outputLength: length)

        var files: [MaxSaveFile] = []
        var offset = 0
        for _ in 0..<dirlen {
            guard offset + 36 <= payload.count else {
                throw ToolError("存档内容不完整（文件表被截断）")
            }
            let fileLength = Int(payload.u32(offset))
            let name = EntryName.cString(payload[(offset + 4)..<(offset + 36)])
            offset += 36
            guard fileLength >= 0, offset + fileLength <= payload.count else {
                throw ToolError("存档内容不完整（\(name) 的数据被截断）")
            }
            let fileData = Array(payload[offset..<(offset + fileLength)])
            offset += fileLength
            offset = roundUp16(offset + 8) - 8
            files.append(MaxSaveFile(name: name.isEmpty ? "file\(files.count)" : name,
                                     data: fileData))
        }

        let dirName = EntryName.sanitizeEntryName(dirNameRaw)
        var save = MaxSave(dirName: dirName,
                           iconSysName: iconSysNameRaw,
                           files: files,
                           compressedLength: compressed.count,
                           uncompressedLength: length,
                           sourceURL: nil,
                           title: nil)
        if let icon = files.first(where: { $0.name.lowercased() == "icon.sys" }) {
            save.title = MaxSave.parseIconTitle(icon.data)
        } else {
            save.title = iconSysNameRaw.isEmpty ? nil : iconSysNameRaw
        }
        return save
    }

    private static func roundUp16(_ value: Int) -> Int {
        return (value + 15) & ~15
    }
}
