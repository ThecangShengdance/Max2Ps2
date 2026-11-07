// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 ThecangShengdance
//
//  model_test.swift
//  Max2Ps2 开发期 UI 流程测试（不参与 App 打包）
//
//  用无窗口方式驱动 AppModel：打开 .max、打开/新建记忆卡、导入、覆盖、备份。
//

import Foundation
import AppKit

@main
enum ModelTest {
    @MainActor
    static func main() {
    let work = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent(".build/modeltest-work")
    try? FileManager.default.removeItem(at: work)
    try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)

    let sample = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("../tests_sample.max").standardizedFileURL
    guard FileManager.default.fileExists(atPath: sample.path) else {
        print("FAIL: 找不到 \(sample.path)")
        exit(1)
    }

    var failures = 0
    func check(_ condition: Bool, _ message: String) {
        if condition {
            print("PASS: \(message)")
        } else {
            print("FAIL: \(message)")
            failures += 1
        }
    }

    let model = AppModel()

    // 1. 打开 .max
    model.openMax(sample)
    check(model.maxSave != nil, "打开 .max 成功")
    check(model.maxSave?.files.count == 3, "解析出 3 个文件")
    check(model.dirName == "BISLPS-25441icoULTR3", "默认使用 .max 内的原始目录名（实际 \(model.dirName)）")
    check(!model.renameDataFile, "默认不改名数据文件")
    check(model.suggestedDirName == "BISLPS-25441", "提供 12 位 ID 备选方案")

    // 2. 空白卡（模拟 PCSX2 新建的卡）打开后需要格式化
    let cardURL = work.appendingPathComponent("Mcd001.ps2")
    FileManager.default.createFile(atPath: cardURL.path,
                                   contents: Data(repeating: 0xFF, count: MemoryCard.standardFileSize))
    model.openCard(cardURL)
    check(model.card != nil, "打开空白卡成功")
    check(model.cardNeedsFormat, "识别出空白卡需要格式化")
    check(!model.canImport, "未格式化时不能导入")

    model.formatSelectedCard()
    check(model.card?.isFormatted == true, "格式化后 isFormatted == true")
    check(model.cardSaves.isEmpty, "格式化后卡内无存档")
    check(model.canImport, "格式化后允许导入")

    // 3. 模拟点击「改用 12 位 ID」，再导入
    model.dirName = model.suggestedDirName!
    model.renameDataFile = true
    model.performImport()
    check(model.errorText == nil, "导入没有报错：\(model.errorText ?? "nil")")
    check(model.lastReport?.dirName == "BISLPS-25441", "报告目录名正确")
    check(model.cardSaves.count == 1, "卡内出现 1 个存档（实际 \(model.cardSaves.count)）")
    check(model.cardSaves.first?.files.count == 3, "存档内有 3 个文件")
    check(model.cardSaves.first?.files.contains { $0.name == "BISLPS-25441" } == true, "数据文件已改名为 BISLPS-25441")

    let backupFiles = (try? FileManager.default.contentsOfDirectory(atPath: work.path))?
        .filter { $0.contains(".bak-") } ?? []
    check(backupFiles.count >= 1, "写入前生成了备份文件（\(backupFiles.count) 个）")

    // 4. 重名时不勾选覆盖 → 报错且不改卡
    let freeBefore = model.card!.freeBytes
    model.overwrite = false
    model.performImport()
    check(model.errorText != nil, "重名未勾选覆盖时给出错误")
    check(model.card!.freeBytes == freeBefore, "失败时记忆卡空间未被消耗")

    // 5. 勾选覆盖 → 成功，空间不泄漏
    model.errorText = nil
    model.overwrite = true
    model.performImport()
    check(model.errorText == nil, "覆盖导入成功：\(model.errorText ?? "nil")")
    check(model.lastReport?.replacedExisting == true, "报告显示覆盖了旧存档")
    check(model.card!.freeBytes == freeBefore, "覆盖后空间没有泄漏")

    // 6. 存档内容与 .max 内文件一致
    let extracted = (try? model.card!.extractSave(named: "BISLPS-25441")) ?? []
    check(extracted.count == 3, "从卡里读回 3 个文件")
    if let original = model.maxSave, let dataFile = extracted.first(where: { $0.0 == "BISLPS-25441" }) {
        let source = original.files.first { $0.name == "BISLPS-25441icoULTR3" }
        check(source?.data == dataFile.1, "数据文件字节与 .max 内完全一致")
    }

    // 7. 用 .max 内原始目录名导入（游戏真实查找的名字）
    let card2 = work.appendingPathComponent("Mcd002.ps2")
    try? FileManager.default.removeItem(at: card2)
    model.createCard(card2)
    model.dirName = model.maxSave!.dirName
    model.renameDataFile = false
    model.overwrite = true
    model.performImport()
    check(model.errorText == nil, "原始目录名导入成功：\(model.errorText ?? "nil")")
    check(model.cardSaves.contains { $0.name == "BISLPS-25441icoULTR3" }, "卡内出现原始目录名存档")
    check(model.cardSaves.first?.files.contains { $0.name == "BISLPS-25441icoULTR3" } == true,
          "原始目录名下数据文件同名")

    print(failures == 0 ? "\n全部通过 ✅" : "\n\(failures) 项失败 ❌")
    exit(failures == 0 ? 0 : 1)
    }
}
