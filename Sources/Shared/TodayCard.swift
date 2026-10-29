import SwiftUI

enum TodayStyle {
    static let accent = Color(red: 0.27, green: 0.36, blue: 0.23)
    static let ink = Color(red: 0.16, green: 0.20, blue: 0.14)
    static let paper = Color(red: 0.97, green: 0.97, blue: 0.93)
    static let reminder = Color(red: 0.62, green: 0.27, blue: 0.04)
}

struct TodayCard<Row: View>: View {
    var date: Date
    var snapshot: ScheduleSnapshot
    var completed: Set<String>
    var limit: Int
    var compact = false
    @ViewBuilder var row: (ScheduleTask, Bool) -> Row

    private var tasks: [ScheduleTask] { snapshot.tasks(on: date) }
    private var remaining: Int { tasks.filter { !completed.contains($0.id) }.count }
    private var visible: [ScheduleTask] {
        Array(snapshot.orderedTasks(on: date, completed: completed).prefix(limit))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 9 : 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("今日事项").font(.system(size: compact ? 16 : 20, weight: .semibold, design: .rounded))
                    Text(date, format: .dateTime.month().day().weekday(.wide))
                        .font(.system(size: 11)).foregroundStyle(TodayStyle.ink.opacity(0.65))
                }
                Spacer(minLength: 4)
                Text("\(remaining)").font(.system(size: compact ? 28 : 34, weight: .light, design: .rounded))
                    .foregroundStyle(TodayStyle.accent).accessibilityLabel("剩余 \(remaining) 项")
            }
            Rectangle().fill(TodayStyle.accent.opacity(0.16)).frame(height: 1)
            if tasks.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Image(systemName: "sun.max").font(.title2).foregroundStyle(TodayStyle.accent)
                    Text(emptyTitle).font(.system(size: 13, weight: .medium))
                    if !compact { Text(emptyDetail).font(.system(size: 11)).foregroundStyle(.secondary) }
                }.frame(maxHeight: .infinity, alignment: .center)
            } else {
                VStack(alignment: .leading, spacing: compact ? 7 : 10) {
                    ForEach(visible) { task in row(task, completed.contains(task.id)) }
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 4) {
                Circle().fill(snapshot.error == nil ? TodayStyle.accent : Color.orange).frame(width: 5, height: 5)
                Text(footer).font(.system(size: 10)).lineLimit(1)
                    .foregroundStyle(TodayStyle.ink.opacity(0.65))
                Spacer(minLength: 0)
                if tasks.count > limit { Text("另 \(tasks.count - limit) 项").font(.system(size: 10)).foregroundStyle(TodayStyle.accent) }
            }
        }.foregroundStyle(TodayStyle.ink)
    }

    private var emptyTitle: String {
        if snapshot.error != nil { return "日程暂时无法同步" }
        if snapshot.refreshedAt == .distantPast { return "连接你的 Excel 日程" }
        return snapshot.coveredDays.contains(DayKey.string(date)) ? "今天没有安排" : "原表还没有这一天"
    }
    private var emptyDetail: String {
        snapshot.error != nil ? "打开应用检查，暂时保留上次记录。" : "打开“今日事项”管理日程。"
    }
    private var footer: String {
        if snapshot.error != nil { return "同步失败 · 显示上次记录" }
        if snapshot.refreshedAt == .distantPast { return "点击打开应用" }
        let formatter = DateFormatter()
        formatter.dateFormat = Calendar.current.isDateInToday(snapshot.refreshedAt) ? "HH:mm" : "M/d HH:mm"
        return "更新于 \(formatter.string(from: snapshot.refreshedAt))"
    }
}

struct TaskLabel: View {
    var task: ScheduleTask
    var done: Bool
    var compact = false
    var date = Date()
    var unlimitedLines = false
    var narrowTime = false
    private var due: Bool { !done && task.isDue(at: date) }
    var body: some View {
        let presentation = task.presentation
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .font(.system(size: compact ? 14 : 16))
                .foregroundStyle(due ? TodayStyle.reminder : TodayStyle.accent.opacity(done ? 0.7 : 1))
            Text(presentation.title).font(.system(size: compact ? 12 : 14))
                .fontWeight(due ? .semibold : .regular)
                .lineLimit(unlimitedLines ? nil : compact ? 1 : 2)
                .strikethrough(done).foregroundStyle(TodayStyle.ink.opacity(done ? 0.48 : 1))
            Spacer(minLength: 0)
            if let time = presentation.time {
                Group {
                    if due && narrowTime {
                        VStack(spacing: 0) {
                            Text(time.label)
                            Text("到时间").font(.system(size: 8, weight: .medium))
                        }
                    } else {
                        Text(due ? "\(time.label) 到时间" : time.label)
                    }
                }
                    .font(.system(size: compact ? 9 : 10, weight: .medium, design: .rounded))
                    .monospacedDigit().fixedSize()
                    .foregroundStyle(due ? TodayStyle.reminder : TodayStyle.accent.opacity(done ? 0.48 : 1))
                    .padding(.horizontal, compact ? 4 : 6).padding(.vertical, 2)
                    .background((due ? TodayStyle.reminder : TodayStyle.accent).opacity(done ? 0.04 : 0.10), in: RoundedRectangle(cornerRadius: 5))
            }
        }.contentShape(Rectangle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(presentation.title)\(presentation.time.map { "，提示时间 \($0.label)" } ?? "")，\(done ? "已完成" : due ? "到时间" : "未完成")")
    }
}
