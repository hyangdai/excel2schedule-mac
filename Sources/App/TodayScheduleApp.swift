import SwiftUI
import AppKit
import UniformTypeIdentifiers
import WidgetKit

@MainActor
final class ScheduleModel: ObservableObject {
    @Published var snapshot = ScheduleStore.loadSnapshot()
    @Published var completed = ScheduleStore.completedIDs()
    @Published var settings = AppSettings.initial
    @Published var message: String?
    @Published var syncing = false
    @Published var writingBack = false
    @Published var writebackMessage = "重新选择原表后，可将勾选状态写回 Excel。"
    @Published var pendingCount = 0
    @Published var selectedDate = Date()
    private var timer: Timer?
    private var lastModification: Date?
    private var sourceURL: URL?
    private var scoped = false

    init() {
        do { settings = try ScheduleStore.loadSettings() } catch { message = error.localizedDescription }
        resolveSource()
        refresh(force: true)
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.completed = ScheduleStore.completedIDs()
                self?.refresh()
                self?.flushCompletions()
            }
        }
    }

    private func resolveSource() {
        if scoped, let sourceURL { sourceURL.stopAccessingSecurityScopedResource() }
        scoped = false
        if let data = settings.bookmark {
            do {
                var stale = false
                let url = try URL(resolvingBookmarkData: data, options: .withSecurityScope, bookmarkDataIsStale: &stale)
                scoped = url.startAccessingSecurityScopedResource()
                sourceURL = url
                settings.filePath = url.path
                if stale {
                    let options: URL.BookmarkCreationOptions = settings.writebackEnabled == true ? [.withSecurityScope] : [.withSecurityScope, .securityScopeAllowOnlyReadAccess]
                    settings.bookmark = try url.bookmarkData(options: options, includingResourceValuesForKeys: nil, relativeTo: nil)
                    try ScheduleStore.saveSettings(settings)
                }
                return
            } catch { message = "文件授权已失效，请重新选择 Excel。" }
        }
        sourceURL = settings.filePath.isEmpty ? nil : URL(fileURLWithPath: settings.filePath)
    }

    func chooseFile() {
        guard !syncing, !writingBack else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "xlsx")!]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "选择 Excel 日程表并允许写回完成标记。勾选后添加删除线，取消勾选后恢复原样。"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            let sameSource = settings.filePath == url.path
            settings.filePath = url.path
            settings.bookmark = try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
            settings.writebackEnabled = true
            try ScheduleStore.saveSettings(settings)
            if sameSource {
                for task in snapshot.tasks where completed.contains(task.id) {
                    try ScheduleStore.enqueue(CompletionChange(sourcePath: url.path, task: task, completed: true))
                }
            }
            resolveSource()
            lastModification = nil
            refresh(force: true)
        } catch { message = error.localizedDescription }
    }

    func saveDates() {
        guard !writingBack else { return }
        do {
            try ScheduleStore.saveSettings(settings)
            lastModification = nil
            refresh(force: true)
        } catch { message = error.localizedDescription }
    }

    func refresh(force: Bool = false) {
        guard !syncing, !writingBack, let url = sourceURL else { return }
        let modification = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        guard force || modification != lastModification || snapshot.error != nil || modification == nil else { return }
        syncing = true
        let year = settings.startYear, month = settings.startMonth
        Task {
            do {
                let updated = try await Task.detached(priority: .utility) {
                    try XLSXReader.read(url: url, startYear: year, startMonth: month)
                }.value
                try ScheduleStore.save(updated)
                snapshot = updated
                lastModification = modification
                message = nil
                WidgetCenter.shared.reloadTimelines(ofKind: ScheduleStore.widgetKind)
            } catch {
                message = error.localizedDescription
                var old = snapshot
                old.error = error.localizedDescription
                snapshot = old
                try? ScheduleStore.save(old)
                WidgetCenter.shared.reloadTimelines(ofKind: ScheduleStore.widgetKind)
            }
            syncing = false
            flushCompletions()
        }
    }

    func toggle(_ task: ScheduleTask) {
        do {
            try ScheduleStore.setCompleted(!completed.contains(task.id), id: task.id, sourcePath: snapshot.sourcePath)
            completed = ScheduleStore.completedIDs()
            WidgetCenter.shared.reloadTimelines(ofKind: ScheduleStore.widgetKind)
            flushCompletions()
        } catch { message = error.localizedDescription }
    }

    func flushCompletions() {
        guard !syncing, !writingBack, let url = sourceURL else { return }
        do {
            let changes = try ScheduleStore.pendingChanges(sourcePath: settings.filePath)
            pendingCount = Set(changes.map { $0.task.id }).count
            guard settings.writebackEnabled == true else {
                writebackMessage = pendingCount > 0 ? "有 \(pendingCount) 项待写回，请重新选择原表以允许写入。" : "重新选择原表后，可将勾选状态写回 Excel。"
                return
            }
            guard !changes.isEmpty else {
                writebackMessage = "已同步 · 勾选完成后自动添加删除线"
                return
            }
            let storage = try ScheduleStore.directory()
            let year = settings.startYear, month = settings.startMonth
            writingBack = true
            writebackMessage = "正在写回 \(pendingCount) 项…"
            Task {
                do {
                    try await Task.detached(priority: .utility) {
                        if ExcelLiveWriter.isRunning {
                            let applied = try ExcelLiveWriter.apply(url: url, changes: changes, startYear: year, startMonth: month, storage: storage)
                            guard applied else { throw WorkbookError.invalid("请在 Excel 中打开这份日程表以实时同步；操作已保留。") }
                        } else {
                            _ = try XLSXCompletionWriter.apply(url: url, changes: changes, startYear: year, startMonth: month, storage: storage)
                        }
                    }.value
                    try ScheduleStore.acknowledge(changes)
                    pendingCount = Set(try ScheduleStore.pendingChanges(sourcePath: settings.filePath).map { $0.task.id }).count
                    writebackMessage = pendingCount == 0 ? "已写回 Excel · 原表已备份" : "还有 \(pendingCount) 项待写回"
                    writingBack = false
                    lastModification = nil
                    refresh(force: true)
                } catch {
                    writebackMessage = error.localizedDescription
                    writingBack = false
                }
            }
        } catch { writebackMessage = error.localizedDescription }
    }

    func openBackups() {
        do {
            let folder = try ScheduleStore.directory().appendingPathComponent("excel-writeback", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            NSWorkspace.shared.open(folder)
        } catch { message = error.localizedDescription }
    }

    func openExcel() {
        if let sourceURL { NSWorkspace.shared.open(sourceURL) }
    }
}

struct MainView: View {
    @ObservedObject var model: ScheduleModel
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 10) {
                    Image(systemName: "checklist").font(.title2).foregroundStyle(TodayStyle.accent)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("把今天，放在眼前").font(.system(size: 19, weight: .semibold))
                        Text("Excel 日程 · 桌面小组件").font(.caption).foregroundStyle(.secondary)
                    }
                }
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    TodayCard(date: context.date, snapshot: model.snapshot, completed: model.completed, limit: 6) { task, done in
                        Button { model.toggle(task) } label: { TaskLabel(task: task, done: done, date: context.date) }.buttonStyle(.plain)
                    }
                    .padding(22).frame(width: 320, height: 370)
                    .background(TodayStyle.paper, in: RoundedRectangle(cornerRadius: 24))
                    .overlay(RoundedRectangle(cornerRadius: 24).stroke(TodayStyle.accent.opacity(0.12), lineWidth: 1))
                    .shadow(color: .black.opacity(0.04), radius: 16, y: 8)
                }
                Text("桌面组件预览 · 点击圆圈标记完成")
                    .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                Spacer(minLength: 0)
            }.padding(28).background(Color(nsColor: .windowBackgroundColor))
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 10) {
                        sectionTitle("日程来源", icon: "tablecells")
                        Text(model.settings.filePath.isEmpty ? "尚未选择 Excel，请点击“选择 Excel…”" : model.settings.filePath).font(.callout).textSelection(.enabled).lineLimit(3)
                        HStack {
                            Button("选择 Excel…", action: model.chooseFile).disabled(model.syncing || model.writingBack)
                            Button("打开原表", action: model.openExcel)
                        }
                        HStack(spacing: 7) {
                            Button { model.refresh(force: true) } label: {
                                Label(model.syncing ? "同步中…" : "立即同步", systemImage: "arrow.clockwise")
                            }.disabled(model.syncing || model.writingBack)
                            Text("保存后自动读取").font(.caption).foregroundStyle(.secondary)
                        }
                        if let message = model.message {
                            Label(message, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                        }
                        Text(model.writebackMessage).font(.caption)
                            .foregroundStyle(model.pendingCount > 0 ? Color.orange : Color.secondary)
                        HStack {
                            if model.settings.writebackEnabled != true {
                                Button("启用 Excel 写回…", action: model.chooseFile).disabled(model.syncing || model.writingBack)
                            }
                            Button("查看备份", action: model.openBackups)
                        }
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 10) {
                        sectionTitle("学期日期", icon: "calendar")
                        HStack {
                            Picker("起始年", selection: $model.settings.startYear) {
                                ForEach(2020...2040, id: \.self) { Text(String($0)).tag($0) }
                            }
                            Picker("月份", selection: $model.settings.startMonth) {
                                ForEach(1...12, id: \.self) { Text("\($0) 月").tag($0) }
                            }
                        }
                        .disabled(model.syncing || model.writingBack)
                        .onChange(of: model.settings.startYear) { _, _ in model.saveDates() }
                        .onChange(of: model.settings.startMonth) { _, _ in model.saveDates() }
                        Text("早于起始月份的工作表归入下一年。例如 2026 年 10 月开学，1 月对应 2027 年。")
                            .font(.caption).foregroundStyle(.secondary)
                    Text("事项末尾写上时间，例如“示例任务A 21:00”，也可在紧邻右侧一格写文本时间。当天到点后突出显示“到时间”，仅在卡片内提示。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 10) {
                        sectionTitle("查看某一天", icon: "list.bullet")
                        DatePicker("日期", selection: $model.selectedDate, displayedComponents: .date).datePickerStyle(.field)
                        let tasks = model.snapshot.tasks(on: model.selectedDate)
                        if tasks.isEmpty {
                            Text("这一天暂无事项").font(.callout).foregroundStyle(.secondary)
                        } else {
                            TimelineView(.periodic(from: .now, by: 60)) { context in
                                ForEach(tasks) { task in
                                    Button { model.toggle(task) } label: {
                                        TaskLabel(task: task, done: model.completed.contains(task.id), date: context.date, unlimitedLines: true)
                                    }.buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        sectionTitle("放到桌面", icon: "macwindow")
                        Text("右键点击桌面 → 编辑小组件 → 搜索“TodaySchedule”，选择“今日事项”并添加。")
                            .font(.callout)
#if LOCAL_DEVELOPMENT
                        Text("当前为本机开发版。如果组件列表未出现本应用，需要用 Xcode 签名运行工程。此版本在应用中勾选事项；正式签名版支持在组件内勾选。")
                            .font(.caption).foregroundStyle(.secondary)
#endif
                        Text("关闭此窗口后应用仍在菜单栏运行。退出应用后，小组件继续显示最后同步的日程；Excel 的新改动需再次打开应用同步。系统决定桌面组件的实际刷新时间。")
                            .font(.caption).foregroundStyle(.secondary)
                        Text("启用写回后，勾选会给 Excel 中对应事项添加删除线，取消勾选则撤销本应用的标记。Excel 打开日程表时实时标记并自动保存整份表格；首次需允许控制 Excel。Excel 编辑中暂缓重试，其他表格软件仍需退出。每次修改前保留已保存版本的备份。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(28)
            }.frame(width: 365)
        }.frame(width: 742, height: 620)
            .tint(TodayStyle.accent)
    }

    private func sectionTitle(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon).font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
    }
}

@main
struct TodayScheduleApp: App {
    @StateObject private var model = ScheduleModel()
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        Window("今日事项", id: "main") {
            MainView(model: model).environment(\.locale, Locale(identifier: "zh_CN"))
                .onOpenURL { _ in showMainWindow() }
        }.windowResizability(.contentSize)
        MenuBarExtra("今日事项", systemImage: "checklist") {
            Button("打开今日事项", action: showMainWindow)
            Button("立即同步") { model.refresh(force: true) }
            Button("打开 Excel", action: model.openExcel)
            Divider()
            Button("退出今日事项") { NSApplication.shared.terminate(nil) }.keyboardShortcut("q")
        }
    }

    private func showMainWindow() {
        openWindow(id: "main")
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}
