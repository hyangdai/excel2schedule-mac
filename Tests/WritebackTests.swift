import Foundation
import CryptoKit

func testWriteback(root: URL) throws {
    func expect(_ value: Bool, _ message: String = "Writeback assertion failed") { precondition(value, message) }
    let fm = FileManager.default
    let folder = root.appendingPathComponent("work/tests/writeback-run")
    if fm.fileExists(atPath: folder.path) { try fm.removeItem(at: folder) }
    try fm.createDirectory(at: folder, withIntermediateDirectories: true)
    let url = folder.appendingPathComponent("schedule.xlsx")
    try fm.copyItem(at: root.appendingPathComponent("work/tests/writeback.xlsx"), to: url)
    let originalData = try Data(contentsOf: url)
    let snapshot = try XLSXReader.read(url: url, startYear: 2026, startMonth: 10)
    let tasks = snapshot.tasks.filter { ["10!B1", "10!E1", "10!G1", "10!H1"].contains($0.cell) }
    expect(tasks.count == 4)
    let changes = tasks.map { CompletionChange(sourcePath: url.path, task: $0, completed: true) }
    let storage = folder.appendingPathComponent("state")
    let preserved = ["xl/sharedStrings.xml", "xl/workbook.xml", "xl/_rels/workbook.xml.rels", "[Content_Types].xml", "docProps/custom.xml", "xl/media/preserved.bin"]
    var originalEntries: [String: Data] = [:]
    // unzip treats [ ] as patterns; use escaping only for this test's content-types entry.
    for path in preserved { originalEntries[path] = try XLSXReader.extract(path == "[Content_Types].xml" ? "\\[Content_Types\\].xml" : path, from: url) }
    func xml(_ path: String) throws -> XMLDocument { try XMLDocument(data: XLSXReader.extract(path, from: url), options: [.nodePreserveAll]) }
    func cells(_ doc: XMLDocument) throws -> [String: String] {
        Dictionary(uniqueKeysWithValues: try doc.nodes(forXPath: "//*[local-name()='c']").compactMap { node in
            guard let cell = node as? XMLElement, let address = cell.attribute(forName: "r")?.stringValue else { return nil }
            return (address, cell.xmlString)
        })
    }
    let beforeCells = try cells(xml("xl/worksheets/sheet1.xml"))
    let beforeStyles = try xml("xl/styles.xml")
    do {
        _ = try XLSXCompletionWriter.apply(url: url, changes: changes, startYear: 2026, startMonth: 10, storage: storage, editorCheck: { "Excel" })
        fatalError("An open editor must defer writing")
    } catch is WorkbookError {}
    expect(try Data(contentsOf: url) == originalData, "Deferral never modifies workbook")
    let result = try XLSXCompletionWriter.apply(url: url, changes: changes, startYear: 2026, startMonth: 10, storage: storage, editorCheck: { nil })
    expect(result.changedCells == 4)
    expect(try Data(contentsOf: result.backup!) == originalData, "Backup must be byte-for-byte original")
    let markedSheet = try xml("xl/worksheets/sheet1.xml")
    let markedCells = try cells(markedSheet)
    for cell in ["A1", "C1", "D1", "F1"] { expect(markedCells[cell] == beforeCells[cell], "Unrelated cells and formula cache stay intact") }
    for path in preserved {
        let data = try XLSXReader.extract(path == "[Content_Types].xml" ? "\\[Content_Types\\].xml" : path, from: url)
        expect(data == originalEntries[path], "Unrelated archive entry preserved: \(path)")
    }
    let markedStyles = try xml("xl/styles.xml")
    for address in ["B1", "E1", "G1", "H1"] {
        let cell = try markedSheet.nodes(forXPath: "//*[local-name()='c' and @r='\(address)']").first! as! XMLElement
        let style = Int(cell.attribute(forName: "s")!.stringValue!)!
        let formats = try markedStyles.nodes(forXPath: "//*[local-name()='cellXfs']/*")
        let font = Int((formats[style] as! XMLElement).attribute(forName: "fontId")!.stringValue!)!
        let strikes = try markedStyles.nodes(forXPath: "//*[local-name()='fonts']/*[\(font + 1)]/*[local-name()='strike']")
        expect(!strikes.isEmpty, "Marked font must have strikethrough")
        if address == "B1" || address == "E1" {
            let runs = try cell.nodes(forXPath: ".//*[local-name()='r']")
            expect(runs.count == 2)
            for run in runs {
                expect(try run.nodes(forXPath: "./*[local-name()='rPr']/*[local-name()='strike' and not(@val='0')]").count == 1, "Rich text must also be struck")
            }
        }
    }
    let appliedData = try Data(contentsOf: url)
    let stateDirectory = try fm.contentsOfDirectory(at: storage.appendingPathComponent("excel-writeback"), includingPropertiesForKeys: nil).first!
    let savedLedger = try JSONDecoder().decode(XLSXCompletionWriter.Ledger.self, from: Data(contentsOf: stateDirectory.appendingPathComponent("marks.json")))
    let repeated = try XLSXCompletionWriter.apply(url: url, changes: changes, startYear: 2026, startMonth: 10, storage: storage, editorCheck: { nil })
    expect(repeated.changedCells == 0 && repeated.backup == nil)
    expect(try Data(contentsOf: url) == appliedData, "Retry is idempotent")
    let undo = tasks.map { CompletionChange(sourcePath: url.path, task: $0, completed: false) }
    _ = try XLSXCompletionWriter.apply(url: url, changes: undo, startYear: 2026, startMonth: 10, storage: storage, editorCheck: { nil })
    expect(try cells(xml("xl/worksheets/sheet1.xml")) == beforeCells, "Undo restores exact original cells, rich text and pre-existing strikethrough")
    let restoredStyles = try xml("xl/styles.xml")
    let oldFormats = try beforeStyles.nodes(forXPath: "//*[local-name()='cellXfs']/*").map(\.xmlString)
    let restoredFormats = try restoredStyles.nodes(forXPath: "//*[local-name()='cellXfs']/*").map(\.xmlString)
    expect(Array(restoredFormats.prefix(oldFormats.count)) == oldFormats, "Never mutate a shared original style")
    _ = try XLSXCompletionWriter.apply(url: url, changes: changes, startYear: 2026, startMonth: 10, storage: storage, editorCheck: { nil })
    expect(try xml("xl/styles.xml").nodes(forXPath: "//*[local-name()='cellXfs']/*").count == restoredFormats.count, "Repeated toggles do not grow styles")
    _ = try XLSXCompletionWriter.apply(url: url, changes: undo, startYear: 2026, startMonth: 10, storage: storage, editorCheck: { nil })

    // Reject stale task identity, foreign workbooks, and edits that happen during a write.
    let stale = CompletionChange(sourcePath: url.path, task: ScheduleTask(title: "renamed", day: tasks[0].day, cell: tasks[0].cell), completed: true)
    let beforeConflict = try Data(contentsOf: url)
    do {
        _ = try XLSXCompletionWriter.apply(url: url, changes: [stale], startYear: 2026, startMonth: 10, storage: storage, editorCheck: { nil })
        fatalError("Stale cells must not be overwritten")
    } catch is WorkbookError {}
    expect(try Data(contentsOf: url) == beforeConflict)
    var foreign = changes[0]; foreign.sourcePath = "/different.xlsx"
    do {
        _ = try XLSXCompletionWriter.apply(url: url, changes: [foreign], startYear: 2026, startMonth: 10, storage: storage, editorCheck: { nil })
        fatalError("Never write another source's pending action")
    } catch is WorkbookError {}
    var checkCount = 0
    let externallyChanged = beforeConflict + Data([0, 1, 2])
    do {
        _ = try XLSXCompletionWriter.apply(url: url, changes: changes, startYear: 2026, startMonth: 10, storage: storage, editorCheck: {
            checkCount += 1
            if checkCount == 2 { try! externallyChanged.write(to: url) }
            return nil
        })
        fatalError("Concurrent edits must be preserved")
    } catch is WorkbookError {}
    expect(try Data(contentsOf: url) == externallyChanged)
    try beforeConflict.write(to: url)

    // Recover either side of an interrupted atomic workbook replacement.
    func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    let interrupted = XLSXCompletionWriter.Transaction(before: digest(originalData), after: digest(appliedData), previous: .init(), next: savedLedger)
    let journalURL = stateDirectory.appendingPathComponent("transaction.json")
    try originalData.write(to: url)
    try JSONEncoder().encode(interrupted).write(to: journalURL)
    _ = try XLSXCompletionWriter.apply(url: url, changes: changes, startYear: 2026, startMonth: 10, storage: storage, editorCheck: { nil })
    expect(!fm.fileExists(atPath: journalURL.path), "Recover crash before workbook replacement")
    try appliedData.write(to: url)
    try JSONEncoder().encode(interrupted).write(to: journalURL)
    let recovered = try XLSXCompletionWriter.apply(url: url, changes: changes, startYear: 2026, startMonth: 10, storage: storage, editorCheck: { nil })
    expect(recovered.changedCells == 0 && !fm.fileExists(atPath: journalURL.path), "Recover crash after workbook replacement without double-applying")
    _ = try XLSXCompletionWriter.apply(url: url, changes: undo, startYear: 2026, startMonth: 10, storage: storage, editorCheck: { nil })

    // Immutable queue: acknowledging an old tap must not remove a newer opposite tap.
    try ScheduleStore.enqueue(changes[0])
    try ScheduleStore.enqueue(undo[0])
    try ScheduleStore.acknowledge([changes[0]])
    let pending = try ScheduleStore.pendingChanges(sourcePath: url.path)
    expect(pending.contains { $0.id == undo[0].id && !$0.completed })
    expect(try ScheduleStore.pendingChanges(sourcePath: "/other.xlsx").isEmpty)
    try ScheduleStore.acknowledge(pending)
    print("PASS: Excel writeback, backup, rich text, untouched entries/formulas/styles, undo, retry, editor deferral, conflicts, durable queue.")
}
