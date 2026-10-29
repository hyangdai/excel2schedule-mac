import Foundation
import CryptoKit

struct ScheduleTask: Codable, Identifiable, Equatable {
    let id: String
    let title: String
    let day: String
    let cell: String
    var adjacentReminder: ReminderTime? = nil

    init(title: String, day: String, cell: String) {
        self.title = title
        self.day = day
        self.cell = cell
        self.id = SHA256.hash(data: Data("\(day)|\(cell)|\(title)".utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    // Keep the original title and ID in storage, including for existing snapshots.
    var presentation: TaskPresentation {
        let parsed = TaskPresentation.parse(title)
        return TaskPresentation(title: parsed.title, time: parsed.time ?? adjacentReminder)
    }

    func reminderDate(calendar: Calendar = .current) -> Date? {
        guard let time = presentation.time else { return nil }
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        let components = DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: time.hour, minute: time.minute)
        guard let date = calendar.date(from: components) else { return nil }
        let actual = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        guard actual.year == parts[0], actual.month == parts[1], actual.day == parts[2],
              actual.hour == time.hour, actual.minute == time.minute else { return nil }
        return date
    }

    func isDue(at date: Date, calendar: Calendar = .current) -> Bool {
        guard let reminder = reminderDate(calendar: calendar) else { return false }
        return reminder <= date
    }
}

struct ReminderTime: Codable, Equatable {
    let hour: Int
    let minute: Int
    var label: String { String(format: "%02d:%02d", hour, minute) }
}

struct TaskPresentation: Equatable {
    let title: String
    let time: ReminderTime?
    private static let suffix = try! NSRegularExpression(
        pattern: #"^(.*?[^0-9:：])([01]?[0-9]|2[0-3])[:：]([0-5][0-9])\s*$"#,
        options: [.dotMatchesLineSeparators])

    static func parse(_ raw: String) -> Self {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let fullRange = NSRange(text.startIndex..., in: text)
        guard let match = suffix.firstMatch(in: text, range: fullRange),
              let nameRange = Range(match.range(at: 1), in: text),
              let hourRange = Range(match.range(at: 2), in: text),
              let minuteRange = Range(match.range(at: 3), in: text),
              let hour = Int(text[hourRange]), let minute = Int(text[minuteRange]) else {
            return Self(title: text, time: nil)
        }
        let name = text[nameRange].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return Self(title: text, time: nil) }
        return Self(title: name, time: ReminderTime(hour: hour, minute: minute))
    }
}

enum DayKey {
    static func string(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }

    static func make(year: Int, month: Int, day: Int) -> String? {
        let calendar = Calendar(identifier: .gregorian)
        let parts = DateComponents(year: year, month: month, day: day)
        guard let date = calendar.date(from: parts) else { return nil }
        let actual = calendar.dateComponents([.year, .month, .day], from: date)
        guard actual.year == year, actual.month == month, actual.day == day else { return nil }
        return string(date, calendar: calendar)
    }
}

struct ScheduleSnapshot: Codable {
    var tasks: [ScheduleTask]
    var coveredDays: [String]
    var sourceName: String
    var refreshedAt: Date
    var error: String?
    var sourcePath: String? = nil

    static var empty: Self {
        Self(tasks: [], coveredDays: [], sourceName: "尚未连接 Excel", refreshedAt: .distantPast)
    }

    func tasks(on date: Date) -> [ScheduleTask] {
        tasks.filter { $0.day == DayKey.string(date) }
    }

    func orderedTasks(on date: Date, completed: Set<String>) -> [ScheduleTask] {
        let today = tasks(on: date)
        let pending = today.filter { !completed.contains($0.id) }
        return pending.filter { $0.isDue(at: date) }
            + pending.filter { !$0.isDue(at: date) }
            + today.filter { completed.contains($0.id) }
    }

    // Precompute reminder boundaries as well as midnight; no continuously running timer is needed in the widget.
    func timelineDates(from now: Date, completed: Set<String>, calendar: Calendar = .current) -> [Date] {
        let start = calendar.startOfDay(for: now)
        guard let end = calendar.date(byAdding: .day, value: 7, to: start) else { return [now] }
        var dates: Set<Date> = [now]
        for offset in 1...7 {
            if let midnight = calendar.date(byAdding: .day, value: offset, to: start) { dates.insert(midnight) }
        }
        for task in tasks where !completed.contains(task.id) {
            if let time = task.reminderDate(calendar: calendar), time > now, time <= end { dates.insert(time) }
        }
        return dates.sorted()
    }

    static var sample: Self {
        let day = DayKey.string(Date())
        return Self(tasks: ["整理今天的计划", "完成一项重要的事 21:00", "留一点时间休息"].enumerated().map {
            ScheduleTask(title: $0.element, day: day, cell: "sample\($0.offset)")
        }, coveredDays: [day], sourceName: "示例日程", refreshedAt: Date())
    }
}

struct AppSettings: Codable {
    var filePath: String
    var bookmark: Data?
    var startYear: Int
    var startMonth: Int
    var writebackEnabled: Bool? = nil

    static var initial: Self {
        Self(filePath: "", startYear: 2026, startMonth: 10)
    }
}

struct CompletionChange: Codable, Identifiable {
    var id = UUID().uuidString
    var createdAt = Date()
    var sourcePath: String
    var task: ScheduleTask
    var completed: Bool
}

enum ScheduleStore {
    static let widgetKind = "TodayScheduleWidget"

    static func directory() throws -> URL {
        let info = Bundle.main.infoDictionary ?? [:]
        if let path = info["LocalDataDirectory"] as? String, !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        guard let group = info["ScheduleAppGroup"] as? String,
              let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else {
            throw NSError(domain: "TodaySchedule", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "共享空间不可用，请检查 App Group 和签名配置。"])
        }
        return url.appendingPathComponent("TodaySchedule", isDirectory: true)
    }

    static func loadSnapshot() -> ScheduleSnapshot {
        do {
            let url = try directory().appendingPathComponent("schedule.json")
            guard FileManager.default.fileExists(atPath: url.path) else { return .empty }
            return try JSONDecoder().decode(ScheduleSnapshot.self, from: Data(contentsOf: url))
        } catch {
            var snapshot = ScheduleSnapshot.empty
            snapshot.error = "暂时无法读取日程，请打开应用重新同步。"
            return snapshot
        }
    }

    static func save(_ snapshot: ScheduleSnapshot) throws {
        try saveJSON(snapshot, filename: "schedule.json")
    }

    static func loadSettings() throws -> AppSettings {
        let url = try directory().appendingPathComponent("settings.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return .initial }
        return try JSONDecoder().decode(AppSettings.self, from: Data(contentsOf: url))
    }

    static func saveSettings(_ settings: AppSettings) throws {
        try saveJSON(settings, filename: "settings.json")
    }

    private static func saveJSON<T: Encodable>(_ value: T, filename: String) throws {
        let directory = try directory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(value).write(to: directory.appendingPathComponent(filename), options: .atomic)
    }

    static func completedIDs() -> Set<String> {
        guard let directory = try? directory().appendingPathComponent("completed"),
              let files = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return [] }
        return Set(files.filter { $0.hasSuffix(".done") }.map { String($0.dropLast(5)) })
    }

    static func setCompleted(_ completed: Bool, id: String, sourcePath: String? = nil) throws {
        guard id.count == 64, id.allSatisfy({ $0.isHexDigit }) else { return }
        // Immutable queue entries prevent a new widget tap being lost while the app acknowledges an older one.
        if let task = loadSnapshot().tasks.first(where: { $0.id == id }) {
            let settings = try loadSettings()
            if let sourcePath, sourcePath != settings.filePath {
                throw NSError(domain: "TodaySchedule", code: 2, userInfo: [NSLocalizedDescriptionKey: "表格来源已切换，请刷新小组件后重试。"])
            }
            try enqueue(CompletionChange(sourcePath: settings.filePath, task: task, completed: completed))
        }
        let directory = try directory().appendingPathComponent("completed", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent(id + ".done")
        if completed {
            try Data().write(to: file, options: .atomic)
        } else if FileManager.default.fileExists(atPath: file.path) {
            try FileManager.default.removeItem(at: file)
        }
    }

    static func enqueue(_ change: CompletionChange) throws {
        let folder = try directory().appendingPathComponent("pending-completions", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONEncoder().encode(change).write(to: folder.appendingPathComponent(change.id + ".json"), options: .atomic)
    }

    static func pendingChanges(sourcePath: String) throws -> [CompletionChange] {
        let folder = try directory().appendingPathComponent("pending-completions", isDirectory: true)
        guard FileManager.default.fileExists(atPath: folder.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .map { try JSONDecoder().decode(CompletionChange.self, from: Data(contentsOf: $0)) }
            .filter { $0.sourcePath == sourcePath }
            .sorted { $0.createdAt == $1.createdAt ? $0.id < $1.id : $0.createdAt < $1.createdAt }
    }

    static func acknowledge(_ changes: [CompletionChange]) throws {
        let folder = try directory().appendingPathComponent("pending-completions", isDirectory: true)
        for change in changes {
            guard UUID(uuidString: change.id) != nil else { continue }
            let file = folder.appendingPathComponent(change.id + ".json")
            if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
        }
    }
}
