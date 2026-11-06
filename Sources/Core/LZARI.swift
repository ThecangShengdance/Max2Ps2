//
//  LZARI.swift
//  Max2Ps2
//
//  Haruhiko Okumura 的 LZARI（算术编码 + LZSS 匹配）解压实现。
//  .max（Datel MAX Drive）存档的压缩体就是 LZARI。
//  这里严格照搬 mymc/mymc+ 的 Python 实现（lzari.py）以保证兼容。
//

import Foundation

enum LZARI {
    static let histLen = 4096
    static let minMatch = 3
    static let maxMatch = 60

    static let arithBits = 15
    static let q1 = 1 << arithBits            // 32768
    static let q2 = q1 * 2                    // 65536
    static let q3 = q1 * 3                    // 98304
    static let q4 = q1 * 4                    // 131072
    static let maxCum = q1 - 1                // 32767
    static let maxChar = 256 + maxMatch - minMatch + 1   // 314

    static let maxOutputLength = 64 << 20     // 64 MB，防御性上限

    static func decode(_ input: [UInt8], outputLength: Int) throws -> [UInt8] {
        guard outputLength > 0 else { return [] }
        guard outputLength <= maxOutputLength else {
            throw ToolError("压缩数据声明的解压长度异常（\(outputLength) 字节）")
        }
        var decoder = Decoder(input: input)
        decoder.start()

        var out = [UInt8](repeating: 0, count: outputLength)
        var history = [UInt8](repeating: 0x20, count: histLen)
        for i in (histLen - maxMatch)..<histLen { history[i] = 0 }
        var histPos = histLen - maxMatch
        var outPos = 0

        while outPos < outputLength {
            let ch = decoder.decodeChar()
            if ch >= 0x100 {
                let pos = decoder.decodePosition()
                let length = ch - 0x100 + minMatch
                var base = histPos - pos - 1
                base = ((base % histLen) + histLen) % histLen
                for offset in 0..<length {
                    if outPos >= outputLength { break }
                    let byte = history[(base + offset) % histLen]
                    out[outPos] = byte
                    outPos += 1
                    history[histPos] = byte
                    histPos = (histPos + 1) % histLen
                }
            } else {
                out[outPos] = UInt8(ch)
                outPos += 1
                history[histPos] = UInt8(ch)
                histPos = (histPos + 1) % histLen
            }
        }
        return out
    }

    // MARK: - 解码器

    private struct Decoder {
        private let input: [UInt8]
        private var bitPosition = 0

        private var high = LZARI.q4
        private var low = 0
        private var code = 0

        private var symFreq: [Int]
        private var symCum: [Int]
        private var symbolToChar: [Int]
        private var positionCum: [Int]

        init(input: [UInt8]) {
            self.input = input
            var freq = [Int](repeating: 1, count: LZARI.maxChar + 1)
            freq[0] = 0
            symFreq = freq
            symCum = Array(0...LZARI.maxChar)
            symbolToChar = (0...LZARI.maxChar).map { $0 == 0 ? 0 : $0 - 1 }

            var cum = [Int](repeating: 0, count: LZARI.histLen + 1)
            var a = 0
            var i = LZARI.histLen
            while i >= 1 {
                a += 10000 / (200 + i)
                cum[i - 1] = a
                i -= 1
            }
            cum[LZARI.histLen] = 0
            positionCum = cum
        }

        private mutating func nextBit() -> Int {
            let index = bitPosition
            bitPosition += 1
            let byteIndex = index >> 3
            guard byteIndex < input.count else { return 0 }
            let shift = 7 - (index & 7)
            return Int((input[byteIndex] >> UInt8(shift)) & 1)
        }

        mutating func start() {
            code = 0
            for _ in 0..<(LZARI.arithBits + 2) {
                code = (code << 1) + nextBit()
            }
        }

        private mutating func renormalize() {
            while true {
                if low < LZARI.q2 {
                    if low < LZARI.q1 || high > LZARI.q3 {
                        if high > LZARI.q2 { return }
                    } else {
                        low -= LZARI.q1
                        code -= LZARI.q1
                        high -= LZARI.q1
                    }
                } else {
                    low -= LZARI.q2
                    code -= LZARI.q2
                    high -= LZARI.q2
                }
                low <<= 1
                high <<= 1
                code = (code << 1) + nextBit()
            }
        }

        mutating func decodeChar() -> Int {
            let range = high - low
            let maxCum = symCum[LZARI.maxChar]
            let n = ((code - low + 1) * maxCum - 1) / range

            // bisect_right(sym_cum, n, lo: 1)
            var lo = 1
            var hi = LZARI.maxChar
            while lo < hi {
                let mid = (lo + hi) / 2
                if symCum[mid] <= n { lo = mid + 1 } else { hi = mid }
            }
            let i = lo

            let newHigh = low + symCum[i] * range / maxCum
            low += symCum[i - 1] * range / maxCum
            high = newHigh

            let symbol = LZARI.maxChar + 1 - i
            renormalize()
            let ch = symbolToChar[symbol]
            updateModel(symbol)
            return ch
        }

        mutating func decodePosition() -> Int {
            let range = high - low
            let maxCum = positionCum[0]
            let x = ((code - low + 1) * maxCum - 1) / range

            // mymc 的二分查找（positionCum 递减）
            var c = 1
            var s = LZARI.histLen
            while true {
                let a = (s + c) / 2
                if positionCum[a] <= x { s = a } else { c = a + 1 }
                if c >= s { break }
            }
            let pos = c - 1

            let newHigh = low + positionCum[pos] * range / maxCum
            low += positionCum[pos + 1] * range / maxCum
            high = newHigh

            while true {
                if low < LZARI.q2 {
                    if low < LZARI.q1 || high > LZARI.q3 {
                        if high > LZARI.q2 { return pos }
                    } else {
                        low -= LZARI.q1
                        code -= LZARI.q1
                        high -= LZARI.q1
                    }
                } else {
                    low -= LZARI.q2
                    code -= LZARI.q2
                    high -= LZARI.q2
                }
                low <<= 1
                high <<= 1
                code = (code << 1) + nextBit()
            }
        }

        private mutating func updateModel(_ symbol: Int) {
            if symCum[LZARI.maxChar] >= LZARI.maxCum {
                var c = 0
                var i = LZARI.maxChar
                while i >= 1 {
                    symCum[LZARI.maxChar - i] = c
                    let a = (symFreq[i] + 1) / 2
                    symFreq[i] = a
                    c += a
                    i -= 1
                }
                symCum[LZARI.maxChar] = c
            }

            let freq = symFreq[symbol]
            var newSymbol = symbol
            while newSymbol > 1 && symFreq[newSymbol - 1] == freq {
                newSymbol -= 1
            }
            if newSymbol != symbol {
                let tmp = symbolToChar[newSymbol]
                symbolToChar[newSymbol] = symbolToChar[symbol]
                symbolToChar[symbol] = tmp
            }
            symFreq[newSymbol] = freq + 1
            var k = LZARI.maxChar - newSymbol + 1
            while k <= LZARI.maxChar {
                symCum[k] += 1
                k += 1
            }
        }
    }
}
