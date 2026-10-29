import AppIntents
import SwiftUI
import WidgetKit

struct SetTaskCompletion: AppIntent {
    static var title: LocalizedStringResource = "标记今日事项"
    static var description = IntentDescription("记录完成状态，由后台应用同步至 Excel。")
    @Parameter(title: "事项") var taskID: String
    @Parameter(title: "完成") var completed: Bool
    @Parameter(title: "表格") var sourcePath: String
    init() {}
    init(id: String, completed: Bool, sourcePath: String) { self.taskID = id; self.completed = completed; self.sourcePath = sourcePath }
    func perform() async throws -> some IntentResult {
        try ScheduleStore.setCompleted(completed, id: taskID, sourcePath: sourcePath.isEmpty ? nil : sourcePath)
        WidgetCenter.shared.reloadTimelines(ofKind: ScheduleStore.widgetKind)
        return .result()
    }
}

struct ScheduleEntry: TimelineEntry {
    var date: Date
    var snapshot: ScheduleSnapshot
    var completed: Set<String>
}

struct ScheduleProvider: TimelineProvider {
    func placeholder(in context: Context) -> ScheduleEntry {
        ScheduleEntry(date: Date(), snapshot: .sample, completed: [])
    }
    func getSnapshot(in context: Context, completion: @escaping (ScheduleEntry) -> Void) {
        completion(ScheduleEntry(date: Date(), snapshot: context.isPreview ? .sample : ScheduleStore.loadSnapshot(), completed: ScheduleStore.completedIDs()))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<ScheduleEntry>) -> Void) {
        let now = Date()
        let snapshot = ScheduleStore.loadSnapshot(), completed = ScheduleStore.completedIDs()
        let entries = snapshot.timelineDates(from: now, completed: completed).map { date in
            ScheduleEntry(date: date, snapshot: snapshot, completed: completed)
        }
        completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(1800))))
    }
}

struct ScheduleWidgetView: View {
    let entry: ScheduleEntry
    @Environment(\.widgetFamily) var family
    private var small: Bool { family == .systemSmall }
    private var limit: Int { family == .systemLarge ? 7 : small ? 2 : 3 }
    var body: some View {
        TodayCard(date: entry.date, snapshot: entry.snapshot, completed: entry.completed, limit: limit, compact: family != .systemLarge) { task, done in
#if LOCAL_DEVELOPMENT
            // Command Line Tools lacks the App Intents metadata processor.
            // Local preview opens the companion app via widgetURL instead.
            TaskLabel(task: task, done: done, compact: family != .systemLarge, date: entry.date, narrowTime: small)
#else
            Button(intent: SetTaskCompletion(id: task.id, completed: !done, sourcePath: entry.snapshot.sourcePath ?? "")) {
                TaskLabel(task: task, done: done, compact: family != .systemLarge, date: entry.date, narrowTime: small)
            }.buttonStyle(.plain)
#endif
        }
        .environment(\.locale, Locale(identifier: "zh_CN"))
        .containerBackground(TodayStyle.paper, for: .widget)
        .widgetURL(URL(string: "todayschedule://today"))
    }
}

@main
struct TodayScheduleWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: ScheduleStore.widgetKind, provider: ScheduleProvider()) { entry in
            ScheduleWidgetView(entry: entry)
        }
        .configurationDisplayName("今日事项")
        .description("从 Excel 看今天的安排，勾选后同步完成标记。")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}
