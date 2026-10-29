import Foundation
import AppKit

@main
struct NativeLiveIntegration {
    static func main() throws {
        func debugExecute(_ source: String) throws -> NSAppleEventDescriptor {
            var problem: NSDictionary?
            let result = NSAppleScript(source: source)!.executeAndReturnError(&problem)
            if let problem { print("NATIVE ERROR", problem, "SOURCE", source); fflush(stdout); throw NSError(domain: "NativeLiveTest", code: 1) }
            return result
        }
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let fm = FileManager.default
        let folder = root.appendingPathComponent("work/native-live")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("native-probe-\(UUID().uuidString).xlsx")
        try fm.copyItem(at: root.appendingPathComponent("work/tests/writeback.xlsx"), to: url)
        let path = ExcelLiveWriter.literal(url.path)
        _ = try debugExecute("""
        using terms from application "Microsoft Excel"
        with timeout of 12 seconds
            tell application id "com.microsoft.Excel"
                open (POSIX file \(path))
            end tell
        end timeout
        end using terms from
        """)
        defer {
            _ = try? debugExecute("""
            using terms from application "Microsoft Excel"
            \(ExcelLiveWriter.handlers)
            set wb to my targetWorkbook(\(path))
            if wb is not missing value then
                tell application id "com.microsoft.Excel" to close wb saving no
            end if
            end using terms from
            """)
        }
        _ = try debugExecute("""
        using terms from application "Microsoft Excel"
        \(ExcelLiveWriter.handlers)
        set wb to my targetWorkbook(\(path))
        tell application id "com.microsoft.Excel"
            set targetCell to range "H1" of worksheet "10" of wb
            set strikethrough of font object of character 1 of targetCell to true
            set strikethrough of font object of character 2 of targetCell to false
        end tell
        end using terms from
        """)
        let snapshot = try XLSXReader.read(url: url, startYear: 2026, startMonth: 10)
        let tasks = snapshot.tasks.filter { ["10!B1", "10!E1", "10!G1", "10!H1"].contains($0.cell) }
        let storage = folder.appendingPathComponent("state")
        let complete = tasks.map { CompletionChange(sourcePath: url.path, task: $0, completed: true) }
        let undo = tasks.map { CompletionChange(sourcePath: url.path, task: $0, completed: false) }
        let applied = try ExcelLiveWriter.apply(url: url, changes: complete, startYear: 2026, startMonth: 10, storage: storage, execute: debugExecute)
        precondition(applied)
        let completedSheet = try XMLDocument(data: XLSXReader.extract("xl/worksheets/sheet1.xml", from: url), options: [])
        let afterSnapshot = try XLSXReader.read(url: url, startYear: 2026, startMonth: 10)
        precondition(afterSnapshot.tasks == snapshot.tasks, "Native Excel save preserves task values")
        print("NATIVE: saved and values verified"); fflush(stdout)
        let flags = try debugExecute(ExcelLiveWriter.readScript(path: url.path, sheet: "10", address: "B1", row: 1)).atIndex(4)!
        precondition(flags.numberOfItems > 0)
        for i in 1...flags.numberOfItems { precondition(flags.atIndex(i)!.booleanValue) }
        print("Native Excel: completion visible in open workbook and saved on disk.")
        _ = completedSheet
        let undone = try ExcelLiveWriter.apply(url: url, changes: undo, startYear: 2026, startMonth: 10, storage: storage, execute: debugExecute)
        precondition(undone)
        let originals = try CompletionStrikeStore.load(sourcePath: url.path, storage: storage)
        let h = tasks.first { $0.cell == "10!H1" }!
        precondition(originals[h.id]!.flags == [true, false, false, false], "Capture a genuinely mixed live font")
        for task in tasks {
            let location = try ExcelLiveWriter.location(task, startYear: 2026, startMonth: 10)
            let state = try debugExecute(ExcelLiveWriter.readScript(path: url.path, sheet: "10", address: location.address, row: 1))
            let flags = state.atIndex(4)!
            let values = (1...flags.numberOfItems).map { flags.atIndex($0)!.booleanValue }
            precondition(values == originals[task.id]!.flags, "Native undo restores every original character's strike")
        }
        print("Native Excel: undo restores rich-text and pre-existing strike flags; source workbook was not touched.")
    }
}
