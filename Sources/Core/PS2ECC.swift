//
//  PS2ECC.swift
//  Max2Ps2
//
//  PS2 记忆卡每 128 字节数据产生 3 字节 Hamming ECC，一个 512 字节页共 12 字节，
//  存放在每页 16 字节的 spare 区开头；其余 4 字节为 0。
//  算法与 mymc 的 ps2mc_ecc.py 完全一致。
//

import Foundation

enum PS2ECC {
    static let parityTable: [UInt8] = (0...255).map { value -> UInt8 in
        var a = value
        a ^= a >> 1
        a ^= a >> 2
        a ^= a >> 4
        return UInt8(a & 1)
    }

    private static let columnParityMasks: [UInt8] = {
        let cpmasks: [UInt8] = [0x55, 0x33, 0x0F, 0x00, 0xAA, 0xCC, 0xF0]
        return (0...255).map { byte -> UInt8 in
            var mask: UInt8 = 0
            for (index, cp) in cpmasks.enumerated() {
                if parityTable[byte & Int(cp)] != 0 {
                    mask |= UInt8(1 << index)
                }
            }
            return mask
        }
    }()

    /// 计算 128 字节数据块的 3 字节 ECC。
    static func calculate(_ data: ArraySlice<UInt8>) -> (UInt8, UInt8, UInt8) {
        var column: UInt8 = 0x77
        var line0 = 0x7F
        var line1 = 0x7F
        var i = 0
        for byte in data {
            column ^= columnParityMasks[Int(byte)]
            if parityTable[Int(byte)] != 0 {
                line0 ^= ~i
                line1 ^= i
            }
            i += 1
        }
        return (column, UInt8(line0 & 0x7F), UInt8(line1 & 0x7F))
    }

    /// 一页（512 字节）对应的 12 字节 ECC。
    static func page(_ page: [UInt8]) -> [UInt8] {
        var result = [UInt8](repeating: 0, count: 12)
        var offset = 0
        for block in 0..<4 {
            let start = block * 128
            let end = min(start + 128, page.count)
            let ecc = calculate(page[start..<end])
            result[offset] = ecc.0
            result[offset + 1] = ecc.1
            result[offset + 2] = ecc.2
            offset += 3
        }
        return result
    }
}
