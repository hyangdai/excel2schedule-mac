import AppKit
import Foundation

/// Sends formatting changes to the in-memory workbook, rather than replacing an open file on disk.
enum ExcelLiveWriter {
    typealias Executor = (String) throws -> NSAppleEventDescriptor
    struct CellState {
        var rawText: String
        var flags: [Bool]
    }
    static var isRunning: Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: "com.microsoft.Excel").isEmpty }

    static func apply(url: URL, changes: [CompletionChange], startYear: Int, startMonth: Int, storage: URL,
                      execute: Executor = executeScript) throws -> Bool {
        guard !changes.isEmpty else { return true }
        guard changes.allSatisfy({ $0.sourcePath == url.path }) else { throw WorkbookError.invalid("待同步操作属于另一份表格。") }
        var latest: [String: CompletionChange] = [:]
        for change in changes.sorted(by: { $0.createdAt == $1.createdAt ? $0.id < $1.id : $0.createdAt < $1.createdAt }) { latest[change.task.id] = change }
        var originals = try CompletionStrikeStore.load(sourcePath: url.path, storage: storage)
        var plans: [(CompletionChange, String, [Bool])] = []
        // Read and validate every cell before applying any member of this batch.
        for change in latest.values.sorted(by: { $0.task.id < $1.task.id }) {
            let location = try location(change.task, startYear: startYear, startMonth: startMonth)
            let reply = try execute(readScript(path: url.path, sheet: location.sheet, address: location.address, row: location.row))
            guard reply.numberOfItems >= 1, reply.atIndex(1)?.booleanValue == true else { return false }
            guard reply.numberOfItems == 4, let raw = reply.atIndex(2)?.stringValue,
                  raw.trimmingCharacters(in: .whitespacesAndNewlines) == change.task.title,
                  let day = reply.atIndex(3)?.stringValue, Double(day.replacingOccurrences(of: ",", with: ".")) == Double(location.day),
                  let flags = reply.atIndex(4), flags.numberOfItems > 0 else {
                throw WorkbookError.invalid("Excel 中的“\(change.task.title)”已移动或改名，暂缓同步以免标错事项。")
            }
            let current = (1...flags.numberOfItems).map { flags.atIndex($0)?.booleanValue ?? false }
            if originals[change.task.id] == nil {
                let legacy = try XLSXCompletionWriter.originalStrikeFlags(task: change.task, url: url, storage: storage, characterCount: current.count)
                originals[change.task.id] = .init(text: raw, flags: legacy ?? current)
            }
            guard let original = originals[change.task.id], original.text == raw, original.flags.count == current.count else {
                throw WorkbookError.invalid("事项文字已变化，无法安全恢复删除线，操作保留待重试。")
            }
            let desired = change.completed ? Array(repeating: true, count: current.count) : original.flags
            plans.append((change, raw, desired))
        }
        let folder = CompletionStrikeStore.folder(sourcePath: url.path, storage: storage)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let backup = folder.appendingPathComponent("backup-live-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString).xlsx")
        // Back up the last saved workbook. Other unsaved Excel edits will be included when Excel saves below.
        try Data(contentsOf: url).write(to: backup, options: .atomic)
        try CompletionStrikeStore.save(originals, sourcePath: url.path, storage: storage)
        let commands = try plans.map { change, raw, flags in
            let location = try location(change.task, startYear: startYear, startMonth: startMonth)
            return command(sheet: location.sheet, address: location.address, row: location.row, day: location.day, raw: raw, flags: flags)
        }.joined(separator: "\n")
        let reply = try execute(writeScript(path: url.path, commands: commands))
        guard reply.booleanValue else { throw WorkbookError.invalid("Excel 中未找到原表，待下次同步重试。") }
        return true
    }

    static func location(_ task: ScheduleTask, startYear: Int, startMonth: Int) throws -> (sheet: String, address: String, row: Int, day: Int) {
        guard let separator = task.cell.lastIndex(of: "!") else { throw WorkbookError.invalid("事项位置无效。") }
        let sheet = String(task.cell[..<separator]), address = String(task.cell[task.cell.index(after: separator)...])
        guard address.range(of: "^[A-Z]+[1-9][0-9]*$", options: .regularExpression) != nil,
              let row = Int(address.drop(while: { $0.isLetter })), row <= 1_048_576,
              let month = Int(sheet.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "月", with: "")), (1...12).contains(month),
              let day = Int(task.day.suffix(2)),
              DayKey.make(year: month < startMonth ? startYear + 1 : startYear, month: month, day: day) == task.day else {
            throw WorkbookError.invalid("事项的日期或单元格位置已改变，未写入 Excel。")
        }
        return (sheet, address, row, day)
    }

    static func literal(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: "\\r").replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\t", with: "\\t") + "\""
    }
    static let handlers = """
    on sameFile(leftPath, rightPath)
        if leftPath is rightPath then return true
        try
            return ((POSIX file leftPath) as alias) is ((POSIX file rightPath) as alias)
        on error
            return false
        end try
    end sameFile
    on targetWorkbook(expectedPath)
        tell application id "com.microsoft.Excel"
            repeat with workbookIndex from 1 to (count workbooks)
                set candidate to workbook workbookIndex
                set candidatePath to full name of candidate
                if candidatePath does not start with "/" then
                    try
                        set candidatePath to POSIX path of (candidatePath as alias)
                    end try
                end if
                if my sameFile(candidatePath, expectedPath) then return candidate
            end repeat
        end tell
        return missing value
    end targetWorkbook
    """
    static func readScript(path: String, sheet: String, address: String, row: Int) -> String {
        """
        using terms from application "Microsoft Excel"
        \(handlers)
        with timeout of 8 seconds
            set wb to my targetWorkbook(\(literal(path)))
            if wb is missing value then return {false}
            tell application id "com.microsoft.Excel"
                if read only of wb then error "日程表以只读方式打开，未修改。" number 1001
                set targetCell to range \(literal(address)) of worksheet \(literal(sheet)) of wb
                set cellText to (value of targetCell) as text
                set rowDay to (value of range \(literal("A\(row)")) of worksheet \(literal(sheet)) of wb) as text
                set characterCount to count characters of targetCell
                if characterCount > 512 then error "事项过长，暂不实时修改。" number 1002
                set flags to {}
                repeat with i from 1 to characterCount
                    set end of flags to strikethrough of font object of character i of targetCell
                end repeat
                return {true, cellText, rowDay, flags}
            end tell
        end timeout
        end using terms from
        """
    }
    static func command(sheet: String, address: String, row: Int, day: Int, raw: String, flags: [Bool]) -> String {
        let setting: String
        if flags.allSatisfy({ $0 == flags.first }) {
            setting = "set strikethrough of font object of targetCell to \(flags.first == true ? "true" : "false")"
        } else {
            setting = flags.enumerated().map { "set strikethrough of font object of character \($0.offset + 1) of targetCell to \($0.element ? "true" : "false")" }.joined(separator: "\n")
        }
        return """
        set targetCell to range \(literal(address)) of worksheet \(literal(sheet)) of wb
        if ((value of targetCell) as text) is not \(literal(raw)) then error "事项内容刚被修改，稍后重试。" number 1003
        if (value of range \(literal("A\(row)")) of worksheet \(literal(sheet)) of wb) is not \(day) then error "日期行刚被修改，稍后重试。" number 1004
        \(setting)
        """
    }
    static func writeScript(path: String, commands: String) -> String {
        """
        using terms from application "Microsoft Excel"
        \(handlers)
        with timeout of 15 seconds
            set wb to my targetWorkbook(\(literal(path)))
            if wb is missing value then return false
            tell application id "com.microsoft.Excel"
                if read only of wb then error "日程表以只读方式打开，未修改。" number 1001
                \(commands)
                set previousAlerts to display alerts
                try
                    set display alerts to false
                    save workbook as wb filename ((POSIX file \(literal(path))) as text)
                on error reason number errorNumber
                    set display alerts to previousAlerts
                    error reason number errorNumber
                end try
                set display alerts to previousAlerts
                if my sameFile(full name of wb, \(literal(path))) is false then error "Excel 保存位置不一致，待人工检查。" number 1006
                if saved of wb is not true then error "Excel 尚未保存，操作保留待重试。" number 1005
                return true
            end tell
        end timeout
        end using terms from
        """
    }
    static func executeScript(_ source: String) throws -> NSAppleEventDescriptor {
        if !Thread.isMainThread { return try DispatchQueue.main.sync { try executeScript(source) } }
        guard let script = NSAppleScript(source: source) else { throw WorkbookError.invalid("无法建立 Excel 同步脚本。") }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            let code = (error[NSAppleScript.errorNumber] as? NSNumber)?.intValue ?? 0
            if code == -1743 || code == -10004 {
                throw WorkbookError.invalid("请允许“今日事项”控制 Microsoft Excel：系统设置 → 隐私与安全性 → 自动化。操作已保留。")
            }
            if code == -1712 || code == -1728 || code == -600 {
                throw WorkbookError.invalid("Excel 正在编辑或等待响应，稍后自动重试。")
            }
            let reason = error[NSAppleScript.errorMessage] as? String ?? "暂时无法与 Excel 通信。"
            throw WorkbookError.invalid("Excel 实时同步暂缓：\(reason)")
        }
        return result
    }
}
