import Foundation

enum WorkbookError: LocalizedError {
    case invalid(String)
    var errorDescription: String? {
        switch self { case .invalid(let message): return message }
    }
}

// Parse values only. Workbook contents are data, never commands or instructions.
final class XMLValues: NSObject, XMLParserDelegate {
    var sheets: [(name: String, relation: String)] = []
    var relationships: [String: String] = [:]
    var strings: [String] = []
    var rows: [[(reference: String, value: String)]] = []
    private var row: [(reference: String, value: String)] = []
    private var reference = ""
    private var cellType = ""
    private var value = ""
    private var sharedText = ""
    private var inShared = false
    private var capture = false
    private var skipPhonetic = false
    var lookup: [String] = []

    func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        switch element {
        case "sheet": sheets.append((attributes["name"] ?? "", attributes["r:id"] ?? ""))
        case "Relationship":
            if attributes["TargetMode"] != "External", let id = attributes["Id"], let target = attributes["Target"] { relationships[id] = target }
        case "si": inShared = true; sharedText = ""
        case "rPh": skipPhonetic = true
        case "row": row = []
        case "c": reference = attributes["r"] ?? ""; cellType = attributes["t"] ?? ""; value = ""
        case "v", "t": capture = !skipPhonetic
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard capture else { return }
        if inShared { sharedText += string } else { value += string }
    }

    func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName: String?) {
        switch element {
        case "v", "t": capture = false
        case "rPh": skipPhonetic = false
        case "si": strings.append(sharedText); inShared = false
        case "c":
            var resolved = value
            if cellType == "s" {
                if let index = Int(value), lookup.indices.contains(index) { resolved = lookup[index] }
                else { parser.abortParsing(); return }
            }
            if cellType == "e" { resolved = "[Excel 错误：\(value)]" }
            row.append((reference, resolved))
        case "row": rows.append(row)
        default: break
        }
    }

    static func parse(_ data: Data, lookup: [String] = []) throws -> XMLValues {
        let delegate = XMLValues()
        delegate.lookup = lookup
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse() else { throw WorkbookError.invalid("Excel 内部数据无法解析，请重新保存为 .xlsx 后再试。") }
        return delegate
    }
}

enum XLSXReader {
    static func extract(_ entry: String, from url: URL, optional: Bool = false) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-p", url.path, entry]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        var data = Data()
        while let chunk = try output.fileHandleForReading.read(upToCount: 65_536), !chunk.isEmpty {
            data.append(chunk)
            if data.count > 16 * 1024 * 1024 {
                process.terminate()
                process.waitUntilExit()
                throw WorkbookError.invalid("工作表过大，当前版本每个内部文件最多读取 16 MB。")
            }
        }
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            if optional && process.terminationStatus == 11 { return Data() }
            throw WorkbookError.invalid("无法读取 Excel。请选择未加密的 .xlsx 文件。")
        }
        return data
    }

    static func read(url: URL, startYear: Int, startMonth: Int) throws -> ScheduleSnapshot {
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            throw WorkbookError.invalid("无法访问原表，请点击“选择 Excel”重新选择文件。")
        }
        let shared = try extract("xl/sharedStrings.xml", from: url, optional: true)
        let strings = shared.isEmpty ? [] : try XMLValues.parse(shared).strings
        let workbook = try XMLValues.parse(extract("xl/workbook.xml", from: url))
        let relations = try XMLValues.parse(extract("xl/_rels/workbook.xml.rels", from: url)).relationships
        var tasks: [ScheduleTask] = []
        var days: Set<String> = []
        var monthSheets = 0
        for sheet in workbook.sheets {
            let name = sheet.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let month = Int(name.replacingOccurrences(of: "月", with: "")), (1...12).contains(month) else { continue }
            monthSheets += 1
            guard let target = relations[sheet.relation] else { throw WorkbookError.invalid("工作表链接缺失：\(name)") }
            let entry = target.hasPrefix("/") ? String(target.dropFirst()) : "xl/" + target
            guard !entry.contains(".."), entry.hasPrefix("xl/"), !entry.contains(":") else { throw WorkbookError.invalid("不支持的工作表路径。") }
            let xml = try XMLValues.parse(extract(entry, from: url), lookup: strings)
            let year = month < startMonth ? startYear + 1 : startYear
            for row in xml.rows {
                guard let first = row.first(where: { column($0.reference) == "A" }),
                      let number = Double(first.value), number.isFinite, number.rounded() == number,
                      (1...31).contains(number),
                      let day = DayKey.make(year: year, month: month, day: Int(number)) else { continue }
                days.insert(day)
                let cells = row.filter { column($0.reference) != "A" }.sorted { columnNumber($0.reference) < columnNumber($1.reference) }
                var consumedTimeCells: Set<String> = []
                for (index, cell) in cells.enumerated() {
                    if consumedTimeCells.contains(cell.reference) { continue }
                    let title = cell.value.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !title.isEmpty {
                        var task = ScheduleTask(title: title, day: day, cell: "\(sheet.name)!\(cell.reference)")
                        if task.presentation.time == nil, standaloneTime(title) == nil, index + 1 < cells.count {
                            let next = cells[index + 1]
                            if columnNumber(next.reference) == columnNumber(cell.reference) + 1,
                               let time = standaloneTime(next.value) {
                                task.adjacentReminder = time
                                consumedTimeCells.insert(next.reference)
                            }
                        }
                        tasks.append(task)
                    }
                }
            }
        }
        guard monthSheets > 0 else { throw WorkbookError.invalid("未找到月份工作表。请使用 1—12 或 1月—12月作为工作表名称。") }
        guard !days.isEmpty else { throw WorkbookError.invalid("月份表的 A 列需要填写 1—31 的日期数字，B 列起每格一条事项。") }
        return ScheduleSnapshot(tasks: tasks, coveredDays: days.sorted(), sourceName: url.lastPathComponent, refreshedAt: Date(), sourcePath: url.path)
    }

    private static func column(_ reference: String) -> String { String(reference.prefix(while: { $0.isLetter })) }

    private static func columnNumber(_ reference: String) -> Int {
        column(reference).uppercased().utf8.reduce(0) { $0 * 26 + Int($1) - 64 }
    }

    private static func standaloneTime(_ value: String) -> ReminderTime? {
        let parsed = TaskPresentation.parse("事项 " + value.trimmingCharacters(in: .whitespacesAndNewlines))
        return parsed.title == "事项" ? parsed.time : nil
    }
}
