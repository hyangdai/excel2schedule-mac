import Foundation
import AppKit
import CryptoKit

/// Updates only affected OOXML parts. All other archive entries (formulas, drawings, etc.) stay intact.
enum XLSXCompletionWriter {
    struct Mark: Codable {
        var originalCell: String
        var markedCell: String
        var originalStyle: Int
        var markedStyle: Int
        var originalStyleSignature: String
        var markedStyleSignature: String
    }
    struct Ledger: Codable { var marks: [String: Mark] = [:] }
    struct Transaction: Codable { var before: String; var after: String; var previous: Ledger; var next: Ledger }
    struct Result { var changedCells: Int; var backup: URL? }

    static func blockingEditor() -> String? {
        for (id, name) in [("com.microsoft.Excel", "Excel"), ("com.kingsoft.wpsoffice.mac", "WPS"),
                           ("com.apple.iWork.Numbers", "Numbers"), ("org.libreoffice.script", "LibreOffice")] {
            if !NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty { return name }
        }
        return nil
    }

    static func apply(url: URL, changes: [CompletionChange], startYear: Int, startMonth: Int,
                      storage: URL, editorCheck: () -> String? = blockingEditor) throws -> Result {
        guard !changes.isEmpty else { return Result(changedCells: 0, backup: nil) }
        guard changes.allSatisfy({ $0.sourcePath == url.path }) else { throw invalid("待同步操作属于另一份表格，未写入。") }
        if let editor = editorCheck() { throw invalid("待写回：请退出 \(editor)，应用会自动重试。") }
#if WRITEBACK_TESTING
        // Command-line tests cannot contact macOS filecoordinationd inside the tool sandbox.
        // The signed app always uses the coordinated branch below.
        return try update(url: url, sourcePath: url.path, changes: changes, startYear: startYear,
                          startMonth: startMonth, storage: storage, editorCheck: editorCheck)
#else
        var coordinationError: NSError?
        var outcome: Swift.Result<Result, Error>?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { coordinatedURL in
            outcome = Swift.Result { try update(url: coordinatedURL, sourcePath: url.path, changes: changes,
                                                startYear: startYear, startMonth: startMonth, storage: storage, editorCheck: editorCheck) }
        }
        if let error = coordinationError { throw error }
        guard let outcome else { throw invalid("暂时无法取得表格的写入权限。") }
        return try outcome.get()
#endif
    }

    private static func update(url: URL, sourcePath: String, changes: [CompletionChange], startYear: Int,
                               startMonth: Int, storage: URL, editorCheck: () -> String?) throws -> Result {
        let fm = FileManager.default
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 64 * 1024 * 1024 else { throw invalid("表格超过 64 MB，暂不自动写回。") }
        let originalData = try Data(contentsOf: url)
        let scratch = fm.temporaryDirectory.appendingPathComponent("schedule-write-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: scratch) }
        let archive = scratch.appendingPathComponent("workbook.xlsx")
        try originalData.write(to: archive)
        let current = try XLSXReader.read(url: archive, startYear: startYear, startMonth: startMonth)
        let currentIDs = Set(current.tasks.map(\.id))
        let workbook = try XMLValues.parse(XLSXReader.extract("xl/workbook.xml", from: archive))
        let relData = try XLSXReader.extract("xl/_rels/workbook.xml.rels", from: archive)
        let relations = try XMLValues.parse(relData).relationships
        let relDocument = try document(relData)
        guard let styleTarget = descendants(relDocument.rootElement()!, "Relationship").first(where: {
            ($0.attribute(forName: "Type")?.stringValue ?? "").hasSuffix("/styles") && $0.attribute(forName: "TargetMode")?.stringValue != "External"
        })?.attribute(forName: "Target")?.stringValue else { throw invalid("此表缺少样式定义，无法安全添加删除线。") }
        let stylesPath = try entryPath(styleTarget)
        let styles = try document(XLSXReader.extract(stylesPath, from: archive))
        guard let styleRoot = styles.rootElement(), let fonts = child(styleRoot, "fonts"), let formats = child(styleRoot, "cellXfs") else {
            throw invalid("表格样式不完整，未修改原表。")
        }
        let sharedData = try XLSXReader.extract("xl/sharedStrings.xml", from: archive, optional: true)
        let shared = sharedData.isEmpty ? [] : children(try document(sharedData).rootElement()!, "si")
        let key = SHA256.hash(data: Data(sourcePath.utf8)).map { String(format: "%02x", $0) }.joined()
        let stateFolder = storage.appendingPathComponent("excel-writeback/" + key, isDirectory: true)
        try fm.createDirectory(at: stateFolder, withIntermediateDirectories: true)
        let ledgerURL = stateFolder.appendingPathComponent("marks.json")
        var ledger = fm.fileExists(atPath: ledgerURL.path) ? try JSONDecoder().decode(Ledger.self, from: Data(contentsOf: ledgerURL)) : Ledger()
        let journalURL = stateFolder.appendingPathComponent("transaction.json")
        if fm.fileExists(atPath: journalURL.path) {
            let journal = try JSONDecoder().decode(Transaction.self, from: Data(contentsOf: journalURL))
            let digest = hash(originalData)
            guard digest == journal.before || digest == journal.after else { throw invalid("上次写回中断后表格又被修改，请保留备份并检查后重试。") }
            ledger = digest == journal.after ? journal.next : journal.previous
            try JSONEncoder().encode(ledger).write(to: ledgerURL, options: .atomic)
            try fm.removeItem(at: journalURL)
        }
        let liveOriginals = try CompletionStrikeStore.load(sourcePath: sourcePath, storage: storage)
        let previousLedger = ledger
        var latest: [String: CompletionChange] = [:]
        for change in changes.sorted(by: { $0.createdAt == $1.createdAt ? $0.id < $1.id : $0.createdAt < $1.createdAt }) { latest[change.task.id] = change }
        var sheets: [String: XMLDocument] = [:]
        var dirtySheets: Set<String> = []
        var changed = 0
        var stylesChanged = false
        for change in latest.values.sorted(by: { $0.task.id < $1.task.id }) {
            let task = change.task
            if !change.completed && ledger.marks[task.id] == nil && liveOriginals[task.id] == nil { continue }
            guard currentIDs.contains(task.id), let separator = task.cell.lastIndex(of: "!") else {
                throw invalid("待写回的“\(task.title)”已移动或改名，请先恢复对应单元格后重试。原表未修改。")
            }
            let sheetName = String(task.cell[..<separator]), address = String(task.cell[task.cell.index(after: separator)...])
            guard let relation = workbook.sheets.first(where: { $0.name == sheetName })?.relation, let target = relations[relation] else {
                throw invalid("找不到事项所在工作表，原表未修改。")
            }
            let path = try entryPath(target)
            if sheets[path] == nil { sheets[path] = try document(XLSXReader.extract(path, from: archive)) }
            let sheet = sheets[path]!
            guard let root = sheet.rootElement(), descendants(root, "sheetProtection").isEmpty,
                  let cell = descendants(root, "c").first(where: { $0.attribute(forName: "r")?.stringValue == address }) else {
                throw invalid("单元格不存在或工作表受保护，原表未修改。")
            }
            let originalXML = cell.xmlString
            if let liveOriginal = liveOriginals[task.id] {
                guard liveOriginal.text.trimmingCharacters(in: .whitespacesAndNewlines) == task.title else { throw invalid("事项文字已变化，暂缓恢复原格式。") }
                let baseline = try CompletionStrikeStore.utf16Flags(text: liveOriginal.text, flags: liveOriginal.flags)
                let desired = change.completed ? Array(repeating: true, count: baseline.count) : baseline
                try applyFlags(desired, text: liveOriginal.text, cell: cell, shared: shared, formats: formats, fonts: fonts)
                if originalXML != cell.xmlString { dirtySheets.insert(path); changed += 1; stylesChanged = true }
                continue
            }
            if let mark = ledger.marks[task.id] {
                guard try signature(mark.originalStyle, formats: formats, fonts: fonts) == mark.originalStyleSignature,
                      try signature(mark.markedStyle, formats: formats, fonts: fonts) == mark.markedStyleSignature else {
                    throw invalid("“\(task.title)”的样式已在其他应用中更改，暂缓写回以保留你的修改。")
                }
                guard originalXML == mark.originalCell || originalXML == mark.markedCell else {
                    throw invalid("“\(task.title)”的单元格格式已更改，暂缓写回以保留你的修改。")
                }
                let desiredXML = change.completed ? mark.markedCell : mark.originalCell
                if originalXML != desiredXML {
                    try replace(cell, with: desiredXML)
                    dirtySheets.insert(path); changed += 1
                }
                // Keep the mapping after undo so repeated toggles reuse styles and crash recovery stays idempotent.
                continue
            }
            let originalStyle = Int(cell.attribute(forName: "s")?.stringValue ?? "0") ?? -1
            let originalSignature = try signature(originalStyle, formats: formats, fonts: fonts)
            let allFormats = children(formats, "xf")
            guard allFormats.indices.contains(originalStyle) else { throw invalid("单元格样式索引无效。") }
            let format = allFormats[originalStyle].copy() as! XMLElement
            let fontID = Int(format.attribute(forName: "fontId")?.stringValue ?? "0") ?? -1
            let allFonts = children(fonts, "font")
            guard allFonts.indices.contains(fontID) else { throw invalid("字体索引无效。") }
            let font = allFonts[fontID].copy() as! XMLElement
            setStrike(font)
            let newFont = intern(font, in: fonts, named: "font")
            setAttribute(format, "fontId", String(newFont)); setAttribute(format, "applyFont", "1")
            let newStyle = intern(format, in: formats, named: "xf")
            setAttribute(cell, "s", String(newStyle))
            if cell.attribute(forName: "t")?.stringValue == "s", let index = Int(child(cell, "v")?.stringValue ?? ""), shared.indices.contains(index), !children(shared[index], "r").isEmpty {
                // A shared string may be used by unrelated cells. Copy rich text to this cell before changing its runs.
                let inline = element("is", like: cell)
                for node in shared[index].children ?? [] { inline.addChild(node.copy() as! XMLNode) }
                child(cell, "v")?.detach(); setAttribute(cell, "t", "inlineStr"); cell.addChild(inline)
            }
            if let inline = child(cell, "is") {
                for run in children(inline, "r") {
                    let properties: XMLElement
                    if let existing = child(run, "rPr") { properties = existing }
                    else { properties = element("rPr", like: run); run.insertChild(properties, at: 0) }
                    setStrike(properties)
                }
            }
            let mark = Mark(originalCell: originalXML, markedCell: cell.xmlString, originalStyle: originalStyle,
                            markedStyle: newStyle, originalStyleSignature: originalSignature,
                            markedStyleSignature: try signature(newStyle, formats: formats, fonts: fonts))
            ledger.marks[task.id] = mark
            if originalXML != cell.xmlString { dirtySheets.insert(path); changed += 1; stylesChanged = true }
        }
        guard changed > 0 else { return Result(changedCells: 0, backup: nil) }
        if stylesChanged {
            setAttribute(fonts, "count", String(children(fonts, "font").count))
            setAttribute(formats, "count", String(children(formats, "xf").count))
            sheets[stylesPath] = styles; dirtySheets.insert(stylesPath)
        }
        for path in dirtySheets {
            let destination = scratch.appendingPathComponent(path)
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try sheets[path]!.xmlData(options: []).write(to: destination)
        }
        let zip = Process(); zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = scratch
        zip.arguments = ["-q", archive.path] + dirtySheets.sorted()
        zip.standardOutput = FileHandle.nullDevice; zip.standardError = FileHandle.nullDevice
        try zip.run(); zip.waitUntilExit()
        guard zip.terminationStatus == 0 else { throw invalid("无法保存表格，原表未修改。") }
        let verified = try XLSXReader.read(url: archive, startYear: startYear, startMonth: startMonth)
        guard verified.tasks == current.tasks, verified.coveredDays == current.coveredDays else { throw invalid("保存校验失败，原表未修改。") }
        let updatedData = try Data(contentsOf: archive)
        if let editor = editorCheck() { throw invalid("待写回：请退出 \(editor)，应用会自动重试。") }
        guard try Data(contentsOf: url) == originalData else { throw invalid("表格刚刚被其他程序修改，稍后自动重试。") }
        let backup = stateFolder.appendingPathComponent("backup-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString).xlsx")
        try originalData.write(to: backup, options: .atomic)
        // A recovery journal keeps the workbook and undo metadata consistent if the app stops between these writes.
        let transaction = Transaction(before: hash(originalData), after: hash(updatedData), previous: previousLedger, next: ledger)
        try JSONEncoder().encode(transaction).write(to: journalURL, options: .atomic)
        try updatedData.write(to: url, options: .atomic)
        try JSONEncoder().encode(ledger).write(to: ledgerURL, options: .atomic)
        try fm.removeItem(at: journalURL)
        return Result(changedCells: changed, backup: backup)
    }

    static func originalStrikeFlags(task: ScheduleTask, url: URL, storage: URL, characterCount: Int) throws -> [Bool]? {
        let folder = CompletionStrikeStore.folder(sourcePath: url.path, storage: storage)
        let ledgerURL = folder.appendingPathComponent("marks.json")
        guard FileManager.default.fileExists(atPath: ledgerURL.path) else { return nil }
        var ledger = try JSONDecoder().decode(Ledger.self, from: Data(contentsOf: ledgerURL))
        let journalURL = folder.appendingPathComponent("transaction.json")
        if FileManager.default.fileExists(atPath: journalURL.path) {
            let journal = try JSONDecoder().decode(Transaction.self, from: Data(contentsOf: journalURL))
            let digest = hash(try Data(contentsOf: url))
            guard digest == journal.before || digest == journal.after else { throw invalid("上次写回尚未恢复，请先检查备份。") }
            ledger = digest == journal.after ? journal.next : journal.previous
        }
        guard let mark = ledger.marks[task.id] else { return nil }
        func fragment(_ xml: String) throws -> XMLElement {
            try document(Data(("<root xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\">" + xml + "</root>").utf8)).rootElement()!
        }
        let signature = try fragment(mark.originalStyleSignature)
        let base = child(signature, "font").map { strikeFlag($0, fallback: false) } ?? false
        let cell = try fragment(mark.originalCell).children!.compactMap { $0 as? XMLElement }.first!
        var inline = child(cell, "is")
        if cell.attribute(forName: "t")?.stringValue == "s", let index = Int(child(cell, "v")?.stringValue ?? "") {
            let shared = try document(XLSXReader.extract("xl/sharedStrings.xml", from: url))
            let strings = children(shared.rootElement()!, "si")
            guard strings.indices.contains(index) else { throw invalid("原有富文本索引已变化，暂缓同步。") }
            inline = strings[index]
        }
        guard let inline, !children(inline, "r").isEmpty else { return Array(repeating: base, count: characterCount) }
        let runs = children(inline, "r")
        let texts = runs.map { child($0, "t")?.stringValue ?? "" }
        guard texts.joined().trimmingCharacters(in: .whitespacesAndNewlines) == task.title else { throw invalid("原有富文本已变化，暂缓恢复删除线。") }
        let flags = runs.map { child($0, "rPr").map { strikeFlag($0, fallback: false) } ?? false }
        for counter in [0, 1, 2] {
            let lengths = texts.map { counter == 0 ? $0.utf16.count : counter == 1 ? $0.unicodeScalars.count : $0.count }
            if lengths.reduce(0, +) == characterCount {
                return zip(lengths, flags).flatMap { Array(repeating: $0.1, count: $0.0) }
            }
        }
        throw invalid("富文本字符计数已变化，暂缓同步。")
    }

    private static func strikeFlag(_ parent: XMLElement, fallback: Bool) -> Bool {
        guard let strike = child(parent, "strike") else { return fallback }
        return !["0", "false", "off"].contains(strike.attribute(forName: "val")?.stringValue?.lowercased() ?? "1")
    }
    private static func setStrikeFlag(_ parent: XMLElement, _ flag: Bool) {
        for strike in children(parent, "strike") { strike.detach() }
        let strike = element("strike", like: parent)
        if !flag { setAttribute(strike, "val", "0") }
        parent.addChild(strike)
    }
    private static func applyFlags(_ flags: [Bool], text: String, cell: XMLElement, shared: [XMLElement], formats: XMLElement, fonts: XMLElement) throws {
        guard !flags.isEmpty, flags.count == text.utf16.count else { throw invalid("原文字与删除线信息不一致。") }
        let formatID = Int(cell.attribute(forName: "s")?.stringValue ?? "0") ?? -1
        let allFormats = children(formats, "xf"), allFonts = children(fonts, "font")
        guard allFormats.indices.contains(formatID) else { throw invalid("单元格样式无效。") }
        let format = allFormats[formatID].copy() as! XMLElement
        let fontID = Int(format.attribute(forName: "fontId")?.stringValue ?? "0") ?? -1
        guard allFonts.indices.contains(fontID) else { throw invalid("字体样式无效。") }
        let font = allFonts[fontID].copy() as! XMLElement
        setStrikeFlag(font, flags[0])
        setAttribute(format, "fontId", String(intern(font, in: fonts, named: "font")))
        setAttribute(format, "applyFont", "1")
        setAttribute(cell, "s", String(intern(format, in: formats, named: "xf")))
        var inline = child(cell, "is")
        if cell.attribute(forName: "t")?.stringValue == "s", let index = Int(child(cell, "v")?.stringValue ?? ""), shared.indices.contains(index) {
            if !children(shared[index], "r").isEmpty || Set(flags).count > 1 {
                inline = element("is", like: cell)
                for node in shared[index].children ?? [] { inline!.addChild(node.copy() as! XMLNode) }
                child(cell, "v")?.detach(); setAttribute(cell, "t", "inlineStr"); cell.addChild(inline!)
            }
        }
        guard let inline else {
            guard Set(flags).count == 1 else { throw invalid("此单元格无法恢复混合删除线。") }
            return
        }
        var runs = children(inline, "r")
        if runs.isEmpty, Set(flags).count > 1, let textNode = child(inline, "t") {
            let run = element("r", like: inline); run.addChild(textNode.copy() as! XMLNode)
            textNode.detach(); inline.addChild(run); runs = [run]
        }
        if runs.isEmpty { return }
        guard runs.map({ child($0, "t")?.stringValue ?? "" }).joined() == text else { throw invalid("富文本内容已变化，未修改。") }
        var offset = 0
        for run in runs {
            guard let textNode = child(run, "t"), let runText = textNode.stringValue else { continue }
            var groups: [(String, Bool)] = []
            for scalar in runText.unicodeScalars {
                let scalarText = String(scalar), length = scalarText.utf16.count
                guard offset + length <= flags.count, flags[offset..<(offset + length)].allSatisfy({ $0 == flags[offset] }) else { throw invalid("不能安全拆分字符格式。") }
                let flag = flags[offset]; offset += length
                if let last = groups.last, last.1 == flag { groups[groups.count - 1].0 += scalarText }
                else { groups.append((scalarText, flag)) }
            }
            let position = run.index
            run.detach()
            for (i, group) in groups.enumerated() {
                let replacement = run.copy() as! XMLElement
                child(replacement, "t")?.stringValue = group.0
                let properties = child(replacement, "rPr") ?? element("rPr", like: replacement)
                if properties.parent == nil { replacement.insertChild(properties, at: 0) }
                setStrikeFlag(properties, group.1)
                inline.insertChild(replacement, at: position + i)
            }
        }
    }

    private static func invalid(_ text: String) -> WorkbookError { .invalid(text) }
    private static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func entryPath(_ target: String) throws -> String {
        let path = target.hasPrefix("/") ? String(target.dropFirst()) : "xl/" + target
        guard path.hasPrefix("xl/"), !path.contains(".."), !path.contains(":"), !path.contains("\\"), !path.contains("\n") else { throw invalid("不支持的工作表路径。") }
        return path
    }
    private static func document(_ data: Data) throws -> XMLDocument {
        guard let text = String(data: data, encoding: .utf8), !text.uppercased().contains("<!DOCTYPE"), !text.uppercased().contains("<!ENTITY") else { throw invalid("不支持的 XML 内容。") }
        return try XMLDocument(data: data, options: [.nodePreserveAll, .nodeLoadExternalEntitiesNever])
    }
    private static func children(_ element: XMLElement, _ name: String) -> [XMLElement] {
        (element.children ?? []).compactMap { $0 as? XMLElement }.filter { ($0.localName ?? $0.name) == name }
    }
    private static func child(_ element: XMLElement, _ name: String) -> XMLElement? { children(element, name).first }
    private static func descendants(_ element: XMLElement, _ name: String) -> [XMLElement] {
        let elements = (element.children ?? []).compactMap { $0 as? XMLElement }
        return elements.flatMap { (($0.localName ?? $0.name) == name ? [$0] : []) + descendants($0, name) }
    }
    private static func element(_ name: String, like parent: XMLElement) -> XMLElement {
        let prefix = parent.prefix ?? ""
        return XMLElement(name: prefix.isEmpty ? name : prefix + ":" + name)
    }
    private static func setAttribute(_ node: XMLElement, _ name: String, _ value: String) {
        if let attribute = node.attribute(forName: name) { attribute.stringValue = value }
        else { node.addAttribute(XMLNode.attribute(withName: name, stringValue: value) as! XMLNode) }
    }
    private static func setStrike(_ parent: XMLElement) {
        for strike in children(parent, "strike") { strike.detach() }
        parent.addChild(element("strike", like: parent))
    }
    private static func intern(_ item: XMLElement, in parent: XMLElement, named name: String) -> Int {
        let existing = children(parent, name)
        if let index = existing.firstIndex(where: { $0.xmlString == item.xmlString }) { return index }
        parent.addChild(item); return existing.count
    }
    private static func signature(_ index: Int, formats: XMLElement, fonts: XMLElement) throws -> String {
        let values = children(formats, "xf"), fontValues = children(fonts, "font")
        guard values.indices.contains(index), let font = Int(values[index].attribute(forName: "fontId")?.stringValue ?? "0"), fontValues.indices.contains(font) else {
            throw invalid("表格样式已变化，无法安全恢复格式。")
        }
        return values[index].xmlString + fontValues[font].xmlString
    }
    private static func replace(_ cell: XMLElement, with xml: String) throws {
        // Preserve inherited namespaces when parsing a detached cell fragment.
        var namespaces: [String: String] = [:]
        var ancestor: XMLNode? = cell
        while let node = ancestor {
            if let element = node as? XMLElement {
                for namespace in element.namespaces ?? [] where namespaces[namespace.name ?? ""] == nil {
                    namespaces[namespace.name ?? ""] = namespace.stringValue ?? ""
                }
            }
            ancestor = node.parent
        }
        let wrapper = XMLElement(name: "wrapper")
        for (prefix, uri) in namespaces { wrapper.addNamespace(XMLNode.namespace(withName: prefix, stringValue: uri) as! XMLNode) }
        let wrapperXML = wrapper.xmlString
        // Build the fragment with XMLDocument rather than dropping namespace-qualified attributes.
        let declaration = wrapperXML.hasSuffix("/>") ? String(wrapperXML.dropLast(2)) + ">" : String(wrapperXML.prefix(while: { $0 != ">" })) + ">"
        let doc = try document(Data((declaration + xml + "</wrapper>").utf8))
        guard let replacement = doc.rootElement()?.children?.first(where: { $0 is XMLElement })?.copy() as? XMLElement,
              let parent = cell.parent as? XMLElement else { throw invalid("无法恢复单元格格式。") }
        parent.replaceChild(at: cell.index, with: replacement)
    }
}
