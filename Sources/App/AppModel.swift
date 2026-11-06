//
//  AppModel.swift
//  Max2Ps2
//
//  UI 状态与业务流程（打开 .max、打开/新建记忆卡、导入、落盘备份）。
//

import Foundation
import SwiftUI
import AppKit

@MainActor
final class AppModel: ObservableObject {
    @Published var maxSave: MaxSave?
    @Published var maxURL: URL?
    @Published var card: MemoryCard?
    @Published var cardURL: URL?
    @Published var cardSaves: [CardSave] = []
    @Published var freeBytes = 0
    @Published var capacityBytes = 0
    @Published var dirName = ""
    @Published var renameDataFile = false
    @Published var overwrite = false
    @Published var isBusy = false
    @Published var errorText: String?
    @Published var statusText: String?
    @Published var lastReport: ImportReport?
    @Published var showHelp = false

    // MARK: 派生状态

    var sanitizedDirName: String {
        EntryName.sanitizeEntryName(dirName.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    var dirNameIsStandard: Bool {
        MaxSave.isStandardDirName(sanitizedDirName)
    }

    var suggestedDirName: String? {
        maxSave?.standardSuggestion
    }

    var canSuggestDirName: Bool {
        guard let suggestion = suggestedDirName else { return false }
        return suggestion != sanitizedDirName
    }

    var existingSave: CardSave? {
        let name = sanitizedDirName
        guard !name.isEmpty else { return nil }
        return cardSaves.first { $0.name == name }
    }

    var canImport: Bool {
        guard maxSave != nil, let card, card.isFormatted, !isBusy else { return false }
        return !sanitizedDirName.isEmpty
    }

    /// PCSX2 是否正在运行：运行中写卡，退出时会被它内存里的旧内容覆盖。
    var pcsx2Running: Bool {
        NSWorkspace.shared.runningApplications.contains { app in
            let name = (app.localizedName ?? "").lowercased()
            let bundle = (app.bundleIdentifier ?? "").lowercased()
            return name.contains("pcsx2") || bundle.contains("pcsx2")
        }
    }

    var cardNeedsFormat: Bool {
        card != nil && card?.isFormatted == false
    }

    var freeText: String {
        guard card != nil else { return "" }
        return "\(Format.bytes(freeBytes)) / \(Format.bytes(capacityBytes)) 可用"
    }

    // MARK: 打开 .max

    func openMax(_ url: URL) {
        do {
            let save = try MaxSaveParser.parse(url: url)
            maxSave = save
            maxURL = url
            // 以 .max 内的原始目录名为准：不少游戏（如《奥特曼格斗进化 3》）的存档目录
            // 并不是 12 位游戏 ID，而是更长的内部名称，改名反而会让游戏找不到存档。
            dirName = save.dirName
            renameDataFile = false
            lastReport = nil
            errorText = nil
            if let standard = save.standardSuggestion, standard != save.dirName {
                statusText = "存档目录名使用 .max 内的原始名称「\(save.dirName)」。如果游戏里看不到存档，可以试试「改用 12 位 ID」。"
            } else {
                statusText = nil
            }
        } catch {
            errorText = error.localizedDescription
        }
    }

    // MARK: 记忆卡

    func openCard(_ url: URL) {
        do {
            let card = try MemoryCard(url: url)
            self.card = card
            self.cardURL = url
            refreshCardSummary()
            errorText = nil
            lastReport = nil
            if !card.isFormatted {
                statusText = "这张 .ps2 还没有格式化（PCSX2 新建的卡默认是空白卡），先点「格式化这张卡」。"
            } else {
                statusText = nil
            }
        } catch {
            self.card = nil
            self.cardURL = nil
            cardSaves = []
            errorText = error.localizedDescription
        }
    }

    func createCard(_ url: URL) {
        do {
            let card = try MemoryCard.createFormatted(at: url)
            self.card = card
            self.cardURL = url
            refreshCardSummary()
            statusText = "已新建 8MB 记忆卡：\(url.lastPathComponent)"
            errorText = nil
        } catch {
            errorText = error.localizedDescription
        }
    }

    func formatSelectedCard() {
        guard let card, let cardURL else { return }
        do {
            card.format()
            try card.save(to: cardURL, backup: true)
            refreshCardSummary()
            statusText = "已格式化，原文件备份为 .bak-…（如已存在文件）。"
            errorText = nil
        } catch {
            errorText = error.localizedDescription
            reloadCard()
        }
    }

    private func reloadCard() {
        guard let cardURL else { return }
        if let fresh = try? MemoryCard(url: cardURL) {
            card = fresh
            refreshCardSummary()
        }
    }

    func refreshCardSummary() {
        guard let card else {
            cardSaves = []
            freeBytes = 0
            capacityBytes = 0
            return
        }
        freeBytes = card.freeBytes
        capacityBytes = card.capacityBytes
        cardSaves = (try? card.listSaves()) ?? []
    }

    // MARK: 导入

    func performImport() {
        guard let card, let cardURL, let save = maxSave else { return }
        let name = sanitizedDirName
        guard !name.isEmpty else {
            errorText = "请填写存档目录名。"
            return
        }
        if name.utf8.count > 32 {
            errorText = "存档目录名最长 32 个字节。"
            return
        }
        if existingSave != nil && !overwrite {
            errorText = "记忆卡上已存在同名存档「\(name)」。勾选「覆盖同名存档」后再导入，或改一个目录名。"
            return
        }

        if pcsx2Running {
            errorText = "PCSX2 正在运行。请先完全退出 PCSX2 和游戏，再导入存档——否则 PCSX2 退出时会把内存里的旧记忆卡写回，覆盖刚导入的存档。"
            return
        }

        isBusy = true
        defer { isBusy = false }
        do {
            let files = save.filesForImport(newDirName: name, renameDataFile: renameDataFile)
            let report = try card.importSave(files, as: name, overwrite: overwrite)
            try card.save(to: cardURL, backup: true)
            lastReport = report
            refreshCardSummary()
            statusText = report.replacedExisting
                ? "已覆盖旧存档「\(report.dirName)」并写入 \(report.fileCount) 个文件。"
                : "已写入新存档「\(report.dirName)」，共 \(report.fileCount) 个文件。"
            errorText = nil
        } catch {
            reloadCard()
            errorText = error.localizedDescription
        }
    }

    func revealCardInFinder() {
        guard let cardURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([cardURL])
    }
}
