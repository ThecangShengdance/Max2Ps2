// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 ThecangShengdance
//
//  Support.swift
//  Max2Ps2
//
//  通用工具：错误类型、字节读写、ASCII 名称、PS2 时间戳（ToD）。
//

import Foundation

/// 面向用户的错误。message 直接显示在界面上。
struct ToolError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

// MARK: - 小端字节读写

extension Array where Element == UInt8 {
    @inline(__always)
    func u16(_ offset: Int) -> UInt16 {
        guard offset >= 0, offset + 2 <= count else { return 0 }
        return UInt16(self[offset]) | (UInt16(self[offset + 1]) << 8)
    }

    @inline(__always)
    func u32(_ offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= count else { return 0 }
        return UInt32(self[offset])
            | (UInt32(self[offset + 1]) << 8)
            | (UInt32(self[offset + 2]) << 16)
            | (UInt32(self[offset + 3]) << 24)
    }

    @inline(__always)
    mutating func putU16(_ offset: Int, _ value: UInt16) {
        guard offset >= 0, offset + 2 <= count else { return }
        self[offset] = UInt8(truncatingIfNeeded: value)
        self[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
    }

    @inline(__always)
    mutating func putU32(_ offset: Int, _ value: UInt32) {
        guard offset >= 0, offset + 4 <= count else { return }
        self[offset] = UInt8(truncatingIfNeeded: value)
        self[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
        self[offset + 2] = UInt8(truncatingIfNeeded: value >> 16)
        self[offset + 3] = UInt8(truncatingIfNeeded: value >> 24)
    }
}

// MARK: - 字符串

enum EntryName {
    /// 读取以 NUL 结尾的 ASCII 名称。
    static func cString(_ bytes: ArraySlice<UInt8>) -> String {
        var end = bytes.startIndex
        while end < bytes.endIndex && bytes[end] != 0 { end += 1 }
        return latin1(bytes[bytes.startIndex..<end])
    }

    /// 宽松解码：优先 UTF-8，失败时按 Latin-1 逐字节映射。
    static func latin1<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
        let array = Array(bytes)
        let utf8 = String(decoding: array, as: UTF8.self)
        if !utf8.unicodeScalars.contains(where: { $0.value == 0xFFFD }) {
            return utf8
        }
        var scalars = String.UnicodeScalarView()
        for b in array {
            if let s = UnicodeScalar(UInt32(b)) { scalars.append(s) }
        }
        return String(scalars)
    }

    /// 将用户输入的名字规整为写入记忆卡的形式（ASCII 可打印、无路径分隔符）。
    static func sanitizeEntryName(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let scalars = trimmed.unicodeScalars.map { scalar -> UnicodeScalar in
            if scalar.value < 0x20 || scalar.value == 0x7F || scalar.value > 0x7E {
                return "?"
            }
            if scalar == "/" || scalar == "\\" { return "_" }
            return scalar
        }
        return String(String.UnicodeScalarView(scalars))
    }
}

// MARK: - PS2 ToD 时间戳

/// PS2 的 ToD 时间结构（8 字节）：0x00 填充、秒、分、时、日、月、年(u16)，按 JST 本地时间保存。
enum ToD {
    static let jst = TimeZone(secondsFromGMT: 9 * 3600) ?? TimeZone(identifier: "Asia/Tokyo")!

    static func now() -> [UInt8] { bytes(from: Date()) }

    static func bytes(from date: Date) -> [UInt8] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = jst
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        var out = [UInt8](repeating: 0, count: 8)
        out[1] = UInt8(clamping: c.second ?? 0)
        out[2] = UInt8(clamping: c.minute ?? 0)
        out[3] = UInt8(clamping: c.hour ?? 0)
        out[4] = UInt8(clamping: c.day ?? 1)
        out[5] = UInt8(clamping: c.month ?? 1)
        let year = min(max(c.year ?? 2000, 0), 65535)
        out[6] = UInt8(year & 0xFF)
        out[7] = UInt8((year >> 8) & 0xFF)
        return out
    }

    static func date(from bytes: ArraySlice<UInt8>) -> Date? {
        guard bytes.count >= 8 else { return nil }
        let b = Array(bytes)
        let second = Int(b[1]), minute = Int(b[2]), hour = Int(b[3])
        let day = Int(b[4]), month = Int(b[5])
        let year = Int(b[6]) | (Int(b[7]) << 8)
        guard (1...12).contains(month), (1...31).contains(day), year > 1970 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = jst
        var comps = DateComponents()
        comps.year = year
        comps.month = month
        comps.day = day
        comps.hour = min(hour, 23)
        comps.minute = min(minute, 59)
        comps.second = min(second, 59)
        return calendar.date(from: comps)
    }
}

// MARK: - 轻微格式化

enum Format {
    static func bytes(_ count: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(count))
    }
}
