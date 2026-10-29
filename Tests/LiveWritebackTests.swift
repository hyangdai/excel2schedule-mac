import Foundation

func testLiveWriteback(root: URL) throws {
    func check(_ value: Bool, _ message: String = "Live writeback check") { precondition(value, message) }
    let folder = root.appendingPathComponent("work/tests/live-run")
    let fm = FileManager.default
    if fm.fileExists(atPath: folder.path) { try fm.removeItem(at: folder) }
    try fm.createDirectory(at: folder, withIntermediateDirectories: true)
    let url = folder.appendingPathComponent("schedule.xlsx"), storage = folder.appendingPathComponent("state")
    try fm.copyItem(at: root.appendingPathComponent("work/tests/writeback.xlsx"), to: url)
    let snapshot = try XLSXReader.read(url: url, startYear: 2026, startMonth: 10)
    let task = snapshot.tasks.first { $0.cell == "10!B1" }!
    let done = CompletionChange(sourcePath: url.path, task: task, completed: true)
    let undo = CompletionChange(sourcePath: url.path, task: task, completed: false)
    func list(_ values: [NSAppleEventDescriptor]) -> NSAppleEventDescriptor {
        let result = NSAppleEventDescriptor.list()
        for (i, value) in values.enumerated() { result.insert(value, at: i + 1) }
        return result
    }
    func response(_ raw: String, _ flags: [Bool]) -> NSAppleEventDescriptor {
        list([.init(boolean: true), .init(string: raw), .init(string: "19"), list(flags.map { .init(boolean: $0) })])
    }
    let baseline = [true, false, false, false, false]
    var scripts: [String] = []
    let applied = try ExcelLiveWriter.apply(url: url, changes: [done], startYear: 2026, startMonth: 10, storage: storage) { script in
        scripts.append(script)
        return scripts.count == 1 ? response(task.title, baseline) : .init(boolean: true)
    }
    check(applied && scripts.count == 2)
    check(scripts[1].contains("save workbook as wb filename ((POSIX file") && scripts[1].contains("set strikethrough of font object of targetCell to true"), "Apply and save through Excel")
    check(!scripts[1].contains("activate") && !scripts[1].contains("open workbook"), "Only target an already open workbook")
    scripts = []
    _ = try ExcelLiveWriter.apply(url: url, changes: [undo], startYear: 2026, startMonth: 10, storage: storage) { script in
        scripts.append(script)
        return scripts.count == 1 ? response(task.title, Array(repeating: true, count: baseline.count)) : .init(boolean: true)
    }
    check(scripts[1].contains("character 1 of targetCell to true") && scripts[1].contains("character 2 of targetCell to false"), "Undo restores original mixed strikethrough")
    check(try CompletionStrikeStore.load(sourcePath: url.path, storage: storage)[task.id]?.flags == baseline)
    scripts = []
    do {
        _ = try ExcelLiveWriter.apply(url: url, changes: [done], startYear: 2026, startMonth: 10, storage: storage) { script in
            scripts.append(script); return response("changed title", baseline)
        }
        fatalError("Refuse stale live cells")
    } catch is WorkbookError {}
    check(scripts.count == 1, "A stale live cell must never reach mutation script")
    let unopened = try ExcelLiveWriter.apply(url: url, changes: [done], startYear: 2026, startMonth: 10, storage: storage) { _ in list([.init(boolean: false)]) }
    check(!unopened, "An unopened workbook is not acknowledged")
    do {
        _ = try ExcelLiveWriter.location(.init(title: task.title, day: "2027-10-19", cell: task.cell), startYear: 2026, startMonth: 10)
        fatalError("Reject stale year mapping")
    } catch is WorkbookError {}
    check(ExcelLiveWriter.literal("a\"\\\nend tell") == "\"a\\\"\\\\\\nend tell\"", "Workbook content remains quoted data")
    check(try CompletionStrikeStore.utf16Flags(text: "a😀b", flags: [false, true, false]) == [false, true, true, false], "Preserve supplementary Unicode character formatting")

    // A live-original record remains usable after Excel closes: change only strike, preserve the rich text.
    _ = try XLSXCompletionWriter.apply(url: url, changes: [done], startYear: 2026, startMonth: 10, storage: storage, editorCheck: { nil })
    _ = try XLSXCompletionWriter.apply(url: url, changes: [undo], startYear: 2026, startMonth: 10, storage: storage, editorCheck: { nil })
    let sheet = try XMLDocument(data: XLSXReader.extract("xl/worksheets/sheet1.xml", from: url), options: [])
    let nodes = try sheet.nodes(forXPath: "//*[local-name()='c' and @r='B1']//*[local-name()='r']")
    check(!nodes.isEmpty)
    check(try XLSXReader.read(url: url, startYear: 2026, startMonth: 10).tasks == snapshot.tasks, "Cross-mode writes preserve all task contents")
    let stored = try CompletionStrikeStore.load(sourcePath: url.path, storage: storage)
    check(stored[task.id]?.flags == baseline, "Cross-mode undo keeps its baseline")

    // A pre-upgrade offline completion imports its original mixed-font strike values.
    let legacyURL = folder.appendingPathComponent("legacy.xlsx")
    try fm.copyItem(at: root.appendingPathComponent("work/tests/writeback.xlsx"), to: legacyURL)
    let legacyDone = CompletionChange(sourcePath: legacyURL.path, task: task, completed: true)
    _ = try XLSXCompletionWriter.apply(url: legacyURL, changes: [legacyDone], startYear: 2026, startMonth: 10, storage: storage, editorCheck: { nil })
    let legacyFlags = try XLSXCompletionWriter.originalStrikeFlags(task: task, url: legacyURL, storage: storage, characterCount: 5)
    check(legacyFlags == Array(repeating: false, count: 5), "Read pre-upgrade undo data")
    print("PASS: live Excel planning, autosave, mixed-format undo, source/date/text guards, Unicode, legacy migration, offline transition.")
}
