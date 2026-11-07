// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 ThecangShengdance
//
//  ContentView.swift
//  Max2Ps2
//

import SwiftUI
import UniformTypeIdentifiers
import AppKit

struct ContentView: View {
    @StateObject private var model = AppModel()
    @State private var dropMaxTargeted = false
    @State private var dropCardTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(spacing: 16) {
                    HStack(alignment: .top, spacing: 16) {
                        maxPanel
                        cardPanel
                    }
                    importPanel
                    footer
                }
                .padding(20)
            }
        }
        .frame(minWidth: 900, minHeight: 640)
        .background(Color(nsColor: .windowBackgroundColor))
        .alert("出错了",
               isPresented: Binding(get: { model.errorText != nil },
                                    set: { if !$0 { model.errorText = nil } })) {
            Button("好", role: .cancel) {}
        } message: {
            Text(model.errorText ?? "")
        }
        .onAppear(perform: loadDemoIfNeeded)
    }

    /// 开发期用环境变量预载存档与记忆卡，方便截图/演示（Release 构建里不存在）。
    private func loadDemoIfNeeded() {
        #if DEBUG
        let env = ProcessInfo.processInfo.environment
        guard env["MAX2PS2_DEMO"] == "1" else { return }
        if let maxPath = env["MAX2PS2_DEMO_MAX"] {
            model.openMax(URL(fileURLWithPath: maxPath))
        }
        if let cardPath = env["MAX2PS2_DEMO_CARD"] {
            model.openCard(URL(fileURLWithPath: cardPath))
        }
        #endif
    }

    // MARK: 顶部

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "externaldrive.badge.arrow.down")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Max2Ps2").font(.title2.weight(.semibold))
                Text("把 .max 游戏存档导入 .ps2 记忆卡，供 PCSX2 使用")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                model.showHelp.toggle()
            } label: {
                Label("说明", systemImage: "questionmark.circle")
            }
            .popover(isPresented: $model.showHelp, arrowEdge: .bottom) {
                helpText
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var helpText: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("它是怎么工作的").font(.headline)
            Text("""
            .max 是 Datel MAX Drive 格式的存档，里面是压缩后的存档目录与文件；\
            .ps2 是 PCSX2 使用的整张记忆卡镜像。本工具把 .max 解压后，按 PS2 记忆卡的\
            文件系统格式写进 .ps2 镜像。
            """)
            Text("PCSX2 的记忆卡位置").font(.headline)
            Text("~/Library/Application Support/PCSX2/memcards/")
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
            Text("导入前建议先在 PCSX2 里关闭游戏；写卡前会自动生成 .bak-时间戳 备份。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 380, alignment: .leading)
    }

    // MARK: 第 1 步：.max

    private var maxPanel: some View {
        PanelBox(title: "1 · 选择 .max 存档", systemImage: "doc.zipper") {
            VStack(alignment: .leading, spacing: 12) {
                if let save = model.maxSave, let url = model.maxURL {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(url.lastPathComponent)
                                .font(.headline)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(save.title ?? "（无标题）")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("更换…") { pickMaxFile() }
                    }
                    HStack(spacing: 14) {
                        StatBadge(text: "\(save.files.count) 个文件")
                        StatBadge(text: Format.bytes(save.totalBytes))
                        StatBadge(text: "\(save.dirName)")
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(save.files, id: \.name) { file in
                            HStack {
                                Image(systemName: file.name.lowercased() == "icon.sys" ? "photo" : "doc")
                                    .foregroundStyle(.secondary)
                                Text(file.name).lineLimit(1).truncationMode(.middle)
                                Spacer()
                                Text(Format.bytes(file.data.count))
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                            .font(.callout)
                        }
                    }
                } else {
                    DropTarget(isTargeted: dropMaxTargeted,
                               title: "把 .max 存档拖到这里",
                               subtitle: "或点击选择文件",
                               systemImage: "arrow.down.doc") {
                        pickMaxFile()
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .onDrop(of: [.fileURL], isTargeted: $dropMaxTargeted) { providers in
            handleDrop(providers, isMax: true)
        }
    }

    // MARK: 第 2 步：记忆卡

    private var cardPanel: some View {
        PanelBox(title: "2 · 选择记忆卡 (.ps2)", systemImage: "sdcard") {
            VStack(alignment: .leading, spacing: 12) {
                if let card = model.card, let url = model.cardURL {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(url.lastPathComponent)
                                .font(.headline)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(card.isFormatted ? model.freeText : "未格式化")
                                .font(.subheadline)
                                .foregroundStyle(card.isFormatted ? .secondary : Color.orange)
                        }
                        Spacer()
                        Text(card.isFormatted ? "已格式化" : "空白卡")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(card.isFormatted ? Color.green.opacity(0.15) : Color.orange.opacity(0.15)))
                            .foregroundStyle(card.isFormatted ? .green : .orange)
                    }

                    if !card.isFormatted {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                            Text("PCSX2 新建的记忆卡是空白卡，导入前需要先格式化。")
                                .font(.callout)
                            Spacer()
                            Button("格式化这张卡") { model.formatSelectedCard() }
                                .buttonStyle(.borderedProminent)
                                .tint(.orange)
                        }
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.08)))
                    } else {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("卡里的存档（\(model.cardSaves.count)）")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            if model.cardSaves.isEmpty {
                                Text("（空）").font(.callout).foregroundStyle(.secondary)
                            } else {
                                ScrollView {
                                    VStack(spacing: 4) {
                                        ForEach(model.cardSaves) { save in
                                            HStack(spacing: 8) {
                                                Image(systemName: "folder")
                                                Text(save.name).lineLimit(1).truncationMode(.middle)
                                                if save.name == model.sanitizedDirName {
                                                    let justImported = model.lastReport?.dirName == save.name
                                                    Text(justImported ? "刚刚写入" : "将被覆盖")
                                                        .font(.caption2.weight(.semibold))
                                                        .padding(.horizontal, 6)
                                                        .padding(.vertical, 2)
                                                        .background(Capsule().fill((justImported ? Color.green : Color.orange).opacity(0.18)))
                                                        .foregroundStyle(justImported ? Color.green : Color.orange)
                                                }
                                                Spacer()
                                                Text("\(save.files.count) 文件 · \(Format.bytes(save.bytes))")
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                            }
                                            .font(.callout)
                                        }
                                    }
                                }
                                .frame(maxHeight: 150)
                            }
                        }
                    }

                    HStack(spacing: 8) {
                        Button("换一张卡…") { pickCardFile() }
                        Button("新建 8MB 卡…") { createNewCard() }
                        if card.isFormatted {
                            Button("在 Finder 中显示") { model.revealCardInFinder() }
                        }
                        Spacer()
                    }
                    .controlSize(.small)
                } else {
                    DropTarget(isTargeted: dropCardTargeted,
                               title: "把 .ps2 记忆卡拖到这里",
                               subtitle: "或选择 PCSX2 的 Mcd001.ps2 / 新建一张",
                               systemImage: "sdcard") {
                        pickCardFile()
                    }
                    HStack(spacing: 8) {
                        Button("选择现有记忆卡…") { pickCardFile() }
                        Button("新建 8MB 记忆卡…") { createNewCard() }
                        Spacer()
                    }
                    .controlSize(.small)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .onDrop(of: [.fileURL], isTargeted: $dropCardTargeted) { providers in
            handleDrop(providers, isMax: false)
        }
    }

    // MARK: 第 3 步：导入

    private var importPanel: some View {
        PanelBox(title: "3 · 写入记忆卡", systemImage: "square.and.arrow.down") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Text("存档目录名")
                        .font(.callout.weight(.medium))
                        .frame(width: 80, alignment: .leading)
                    TextField("例如 BISLPS-25441", text: $model.dirName)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 300)
                        .font(.system(.body, design: .monospaced))
                    if model.canSuggestDirName, let suggestion = model.suggestedDirName {
                        Button("改用 12 位 ID \(suggestion)") {
                            model.dirName = suggestion
                            model.renameDataFile = true
                        }
                        .controlSize(.small)
                        .help("只有确认游戏使用 12 位 ID 目录时才需要改；多数存档应保持 .max 内的原始名字。")
                    }
                    Spacer()
                }

                HStack(spacing: 6) {
                    Image(systemName: model.dirNameIsStandard ? "checkmark.seal.fill" : "info.circle")
                        .foregroundStyle(model.dirNameIsStandard ? .green : .secondary)
                    Text(model.dirNameIsStandard
                         ? "目录名是标准 12 位游戏 ID，游戏一般能正常识别。"
                         : "目录名取自 .max 文件内的原始名称（游戏内部就是按这个名字查找存档），一般保持原样即可。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Toggle("把同名数据文件也改名为目录名", isOn: $model.renameDataFile)
                    .toggleStyle(.checkbox)
                    .font(.callout)
                    .help("当存档里的数据文件与目录同名时，改目录名后需要一起改，除非你清楚游戏会按固定文件名读取。")

                if model.pcsx2Running {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text("检测到 PCSX2 正在运行，请先完全退出 PCSX2 和游戏再导入，否则它退出时会覆盖刚写入的存档。")
                            .font(.callout)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if let existing = model.existingSave {
                    Toggle("覆盖记忆卡上已有的同名存档「\(existing.name)」", isOn: $model.overwrite)
                        .toggleStyle(.checkbox)
                        .font(.callout)
                }

                HStack(spacing: 12) {
                    Button {
                        model.performImport()
                    } label: {
                        Label("导入到记忆卡", systemImage: "arrow.down.to.line")
                            .frame(minWidth: 120)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!model.canImport)

                    if model.isBusy {
                        ProgressView().controlSize(.small)
                    }

                    if model.card == nil {
                        Text("先选择一张记忆卡")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else if model.cardNeedsFormat {
                        Text("先格式化记忆卡")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    if let report = model.lastReport {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            Text("\(report.dirName) · \(report.fileCount) 个文件 · \(Format.bytes(report.totalBytes))")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if let status = model.statusText {
                    Text(status)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Image(systemName: "shield.lefthalf.filled").foregroundStyle(.secondary)
            Text("写入前会自动备份原记忆卡（.bak-时间戳）。导出的 .max 不会改动原始文件。")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.top, 2)
    }

    // MARK: 面板与拖放

    private func handleDrop(_ providers: [NSItemProvider], isMax: Bool) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            var url: URL?
            if let data = item as? Data {
                url = URL(dataRepresentation: data, relativeTo: nil)
            } else if let value = item as? URL {
                url = value
            }
            guard let fileURL = url else { return }
            Task { @MainActor in
                if isMax {
                    model.openMax(fileURL)
                } else {
                    model.openCard(fileURL)
                }
            }
        }
        return true
    }

    private func pickMaxFile() {
        let panel = NSOpenPanel()
        panel.title = "选择 .max 存档"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [UTType(filenameExtension: "max") ?? .data]
        if panel.runModal() == .OK, let url = panel.url {
            model.openMax(url)
        }
    }

    private func pickCardFile() {
        let panel = NSOpenPanel()
        panel.title = "选择 .ps2 记忆卡"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [UTType(filenameExtension: "ps2") ?? .data]
        if panel.runModal() == .OK, let url = panel.url {
            model.openCard(url)
        }
    }

    private func createNewCard() {
        let panel = NSSavePanel()
        panel.title = "新建 8MB 记忆卡"
        panel.nameFieldStringValue = "Mcd003.ps2"
        panel.allowedContentTypes = [UTType(filenameExtension: "ps2") ?? .data]
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            model.createCard(url)
        }
    }
}

// MARK: - 小组件

private struct PanelBox<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: systemImage)
                .font(.headline)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08))
        )
    }
}

private struct StatBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.primary.opacity(0.06)))
    }
}

private struct DropTarget: View {
    let isTargeted: Bool
    let title: String
    let subtitle: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 26))
                    .foregroundStyle(.secondary)
                Text(title).font(.callout.weight(.medium))
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 28)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isTargeted ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.03))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                    .foregroundStyle(isTargeted ? Color.accentColor : Color.secondary.opacity(0.4))
            )
        }
        .buttonStyle(.plain)
    }
}
