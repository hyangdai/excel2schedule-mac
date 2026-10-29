import Foundation

@main
struct ScheduleTests {
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let fixture = root.appendingPathComponent("work/tests/schedule.xlsx")
        let snapshot = try XLSXReader.read(url: fixture, startYear: 2026, startMonth: 10)
        precondition(snapshot.tasks.count == 5, "Read all cells and exclude invalid dates")
        precondition(snapshot.tasks[0].title == "完成练习", "Read rich shared strings")
        precondition(snapshot.tasks[1].title == "重复事项", "Trim whitespace")
        precondition(snapshot.tasks[1].id != snapshot.tasks[2].id, "Duplicate titles stay distinct")
        precondition(snapshot.tasks[3].title == "内联 & 文本", "Decode inline XML entities")
        precondition(snapshot.tasks[4].day == "2027-01-01", "Roll over year")
        precondition(snapshot.coveredDays.contains("2026-10-20"), "Retain explicitly empty days")
        precondition(!snapshot.coveredDays.contains("2027-02-29"), "Reject invalid February 29")
        let leap = try XLSXReader.read(url: fixture, startYear: 2027, startMonth: 10)
        precondition(leap.tasks.last?.day == "2028-02-29", "Support leap years")
        let inline = try XLSXReader.read(url: root.appendingPathComponent("work/tests/inline-only.xlsx"), startYear: 2026, startMonth: 10)
        precondition(inline.tasks.count == 1, "sharedStrings.xml is optional")
        let reminders = try XLSXReader.read(url: root.appendingPathComponent("work/tests/reminders.xlsx"), startYear: 2026, startMonth: 10)
        precondition(reminders.tasks.count == 9, "Merge only directly adjacent valid time cells")
        precondition(reminders.tasks[0].title == "示例任务A" && reminders.tasks[0].presentation.time?.label == "21:00", "Attach adjacent reminder to original task")
        precondition(reminders.tasks[0].id == ScheduleTask(title: "示例任务A", day: "2026-10-01", cell: "10!B1").id, "Adding adjacent time preserves completion identity")
        precondition(reminders.tasks[1].presentation.time?.label == "09:05", "Read inline suffix from workbook")
        precondition(reminders.tasks[2].presentation.time == nil && reminders.tasks[4].presentation.time == nil, "Do not cross empty columns or accept invalid times")
        precondition(reminders.tasks.last?.presentation.time?.label == "08:30", "Support adjacent columns Z and AA")
        let reminderRoundTrip = try JSONDecoder().decode(ScheduleSnapshot.self, from: JSONEncoder().encode(reminders))
        precondition(reminderRoundTrip.tasks == reminders.tasks, "Persist adjacent time for widget")
        do {
            _ = try XLSXReader.read(url: root.appendingPathComponent("work/tests/bad.xlsx"), startYear: 2026, startMonth: 10)
            fatalError("Corrupted input must fail")
        } catch is WorkbookError {}
        let encoded = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(ScheduleSnapshot.self, from: encoded)
        precondition(decoded.tasks == snapshot.tasks, "Snapshot round trip")
        try ScheduleStore.save(snapshot)
        precondition(ScheduleStore.loadSnapshot().tasks == snapshot.tasks, "Atomic snapshot persistence")
        let first = snapshot.tasks[0]
        try ScheduleStore.setCompleted(true, id: first.id)
        precondition(ScheduleStore.completedIDs().contains(first.id), "Persist completion")
        try ScheduleStore.save(leap)
        precondition(ScheduleStore.completedIDs().contains(first.id), "Sync does not erase completion")
        try ScheduleStore.setCompleted(false, id: first.id)
        precondition(!ScheduleStore.completedIDs().contains(first.id), "Undo completion")
        try testReminderTimes()
        try testWriteback(root: root)
        try testLiveWriteback(root: root)
        print("PASS: workbook parsing, year rollover, persistence, completion, time suffixes, due boundaries, reminder timelines, old-snapshot compatibility.")
    }

    static func testReminderTimes() throws {
        for (raw, name, time) in [
            ("示例任务A 21:00", "示例任务A", "21:00"),
            ("示例任务A21:00", "示例任务A", "21:00"),
            ("示例任务A 9：05  ", "示例任务A", "09:05"),
            ("休息 00:00", "休息", "00:00"),
            ("读书 23:59", "读书", "23:59"),
            ("练习📝\n21:00", "练习📝", "21:00")
        ] {
            let parsed = TaskPresentation.parse(raw)
            precondition(parsed.title == name && parsed.time?.label == time, "Time parsing: \(raw)")
        }
        for raw in ["普通事项", "任务 24:00", "任务 25:00", "任务 21:60", "任务 121:00", "21:00", "21:00 示例任务A", "任务 21:00 完成后", "任务 21:0"] {
            precondition(TaskPresentation.parse(raw).time == nil, "Do not interpret invalid or non-suffix times: \(raw)")
            precondition(TaskPresentation.parse(raw).title == raw, "Preserve unsupported text")
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
        }
        let task = ScheduleTask(title: "示例任务A 21:00", day: "2026-10-19", cell: "10!C1")
        precondition(task.reminderDate(calendar: calendar) == date(19,21), "Use the row's day and local time zone")
        precondition(!task.isDue(at: date(19,20,59), calendar: calendar), "Not due before time")
        precondition(task.isDue(at: date(19,21), calendar: calendar), "Due at exact boundary")
        precondition(task.isDue(at: date(19,23), calendar: calendar), "Remain due until completed")
        let sameTime = ScheduleTask(title: "读书 21:00", day: task.day, cell: "10!D1")
        let nextDay = ScheduleTask(title: "复习 09:00", day: "2026-10-20", cell: "10!C2")
        let untimed = ScheduleTask(title: "散步", day: task.day, cell: "10!B1")
        let snapshot = ScheduleSnapshot(tasks: [untimed, task, sameTime, nextDay], coveredDays: [task.day, nextDay.day], sourceName: "test", refreshedAt: date(19,20))
        let timeline = snapshot.timelineDates(from: date(19,20), completed: [], calendar: calendar)
        precondition(timeline.first == date(19,20), "Begin with current state")
        precondition(timeline.filter { $0 == date(19,21) }.count == 1, "Deduplicate simultaneous reminders")
        precondition(timeline.contains(date(20,0)) && timeline.contains(date(20,9)), "Include both midnight and next-day reminder")
        precondition(timeline == timeline.sorted(), "Keep timeline chronological")
        let completed = snapshot.timelineDates(from: date(19,20), completed: [task.id, sameTime.id], calendar: calendar)
        precondition(!completed.contains(date(19,21)), "No reminder boundary for completed tasks")
        let oldJSON = try JSONEncoder().encode(task)
        let decoded = try JSONDecoder().decode(ScheduleTask.self, from: oldJSON)
        precondition(decoded.id == task.id && decoded.title == task.title && decoded.presentation.time?.label == "21:00", "Existing snapshot format and IDs stay compatible")
        let localDueDate = task.reminderDate()!
        precondition(snapshot.orderedTasks(on: localDueDate.addingTimeInterval(-60), completed: []).first?.id == untimed.id, "Keep original order before reminders")
        precondition(snapshot.orderedTasks(on: localDueDate, completed: []).first?.id == task.id, "Bring due tasks into view")
        precondition(snapshot.orderedTasks(on: localDueDate, completed: [task.id, sameTime.id]).first?.id == untimed.id, "Completed reminders no longer take priority")
        var losAngeles = calendar
        losAngeles.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let missingHour = ScheduleTask(title: "测试 02:30", day: "2026-03-08", cell: "3!B8")
        precondition(missingHour.reminderDate(calendar: losAngeles) == nil, "Do not silently shift a nonexistent DST time")
    }
}
