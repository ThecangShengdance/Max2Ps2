//
//  main.swift
//  Max2Ps2 CLI（用于开发期验证核心逻辑，不参与 App 打包）
//

import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("错误: " + message + "\n").utf8))
    exit(1)
}

func info(_ url: URL) throws {
    let save = try MaxSaveParser.parse(url: url)
    print("文件: \(url.lastPathComponent)")
    print("目录名: \(save.dirName)  (标准 12 位: \(save.dirNameLooksStandard))")
    if let suggestion = save.standardSuggestion {
        print("备选 12 位 ID: \(suggestion)（默认不使用）")
    }
    print("标题: \(save.title ?? "(无)")")
    print("文件数: \(save.files.count)，解压长度: \(save.uncompressedLength)，压缩体: \(save.compressedLength)")
    for file in save.files {
        print(String(format: "  %-32@ %8d 字节", file.name, file.data.count))
    }
    print("图标标题字段: \(save.iconSysName.isEmpty ? "(空)" : save.iconSysName)")
}

func formatCard(_ path: String) throws {
    let url = URL(fileURLWithPath: path)
    let card = try MemoryCard.createFormatted(at: url)
    print("已格式化: \(path)")
    print("  容量: \(Format.bytes(card.capacityBytes))，空闲: \(Format.bytes(card.freeBytes))，空闲簇: \(card.freeClusterCount())")
}

func listCard(_ path: String) throws {
    let card = try MemoryCard(url: URL(fileURLWithPath: path))
    print("已格式化: \(card.isFormatted)")
    guard card.isFormatted else { return }
    print("空闲: \(Format.bytes(card.freeBytes)) / \(Format.bytes(card.capacityBytes))，空闲簇: \(card.freeClusterCount())")
    let saves = try card.listSaves()
    print("存档数: \(saves.count)")
    for save in saves {
        let modified = save.modified.map { ISO8601DateFormatter().string(from: $0) } ?? "-"
        print("  \(save.name)  \(save.files.count) 个文件  \(save.bytes) 字节  \(modified)")
        for file in save.files {
            print("      - \(file.name) \(file.bytes)")
        }
    }
}

func importSave(_ maxPath: String, _ cardPath: String, _ dirName: String?) throws {
    let save = try MaxSaveParser.parse(url: URL(fileURLWithPath: maxPath))
    let card = try MemoryCard(url: URL(fileURLWithPath: cardPath))
    if !card.isFormatted {
        card.format()
        print("（记忆卡原本未格式化，已自动格式化）")
    }
    // 默认使用 .max 内的原始目录名（游戏内部名称，可能不是 12 位 ID）
    let target = dirName ?? save.dirName
    let renameDataFile = dirName != nil && dirName != save.dirName
    if let dirName, dirName != save.dirName {
        print("提示: 目录名改为 \(dirName)（原为 \(save.dirName)）")
    }
    let files = save.filesForImport(newDirName: target, renameDataFile: renameDataFile)
    let report = try card.importSave(files, as: target, overwrite: true)
    try card.save(to: card.url, backup: false)
    print("导入完成: \(report.dirName)")
    print("  文件: \(report.fileCount)，字节: \(report.totalBytes)，覆盖已有: \(report.replacedExisting)")
    print("  空闲簇: \(report.freeClustersBefore) -> \(report.freeClustersAfter)")
}

func deleteSave(_ cardPath: String, _ dirName: String) throws {
    let card = try MemoryCard(url: URL(fileURLWithPath: cardPath))
    guard card.isFormatted else { fail("记忆卡未格式化") }
    guard try card.containsSave(named: dirName) else { fail("卡内没有存档 \(dirName)") }
    try card.deleteSave(named: dirName)
    try card.save(to: card.url, backup: true)
    print("已删除存档: \(dirName)")
    print("  空闲簇: \(card.freeClusterCount())")
}

func extract(_ cardPath: String, _ dirName: String, _ outDir: String) throws {
    let card = try MemoryCard(url: URL(fileURLWithPath: cardPath))
    // 通过 public API 重新走一遍读取：把卡里该存档的文件取出来
    let saves = try card.listSaves()
    guard saves.contains(where: { $0.name == dirName }) else { fail("找不到存档 \(dirName)") }
    let directory = URL(fileURLWithPath: outDir)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let extracted = try card.extractSave(named: dirName)
    for (name, data) in extracted {
        try Data(data).write(to: directory.appendingPathComponent(name))
    }
    print("已导出 \(extracted.count) 个文件到 \(outDir)")
    for (name, data) in extracted {
        print("  \(name) \(data.count) 字节")
    }
}

func verifyECC(_ path: String) throws {
    let card = try MemoryCard(url: URL(fileURLWithPath: path))
    let result = try card.verifyECC()
    print("ECC 校验: \(result.badPages) 个坏页 / \(result.totalPages)")
}

do {
    let args = Array(CommandLine.arguments.dropFirst())
    guard let command = args.first else {
        print("用法: verify <info|format|list|import|delete|extract|ecc> ...")
        exit(0)
    }
    switch command {
    case "info":
        guard args.count > 1 else { fail("缺少 .max 路径") }
        try info(URL(fileURLWithPath: args[1]))
    case "format":
        guard args.count > 1 else { fail("缺少记忆卡路径") }
        try formatCard(args[1])
    case "list":
        guard args.count > 1 else { fail("缺少记忆卡路径") }
        try listCard(args[1])
    case "import":
        guard args.count > 2 else { fail("用法: import <max> <card> [dirname]") }
        try importSave(args[1], args[2], args.count > 3 ? args[3] : nil)
    case "delete":
        guard args.count > 2 else { fail("用法: delete <card> <dirname>") }
        try deleteSave(args[1], args[2])
    case "extract":
        guard args.count > 3 else { fail("用法: extract <card> <dirname> <outdir>") }
        try extract(args[1], args[2], args[3])
    case "ecc":
        guard args.count > 1 else { fail("缺少记忆卡路径") }
        try verifyECC(args[1])
    default:
        fail("未知命令 \(command)")
    }
} catch {
    fail(error.localizedDescription)
}
