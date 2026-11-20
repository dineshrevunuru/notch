import NotchCore
import SwiftUI

/// The Kanban board: To Do, Doing, Done. Drag a card between columns, or drop it onto another
/// card to place it above. Doing is what the notch shows as "now", and it says so when it
/// holds more than a few cards at once.
struct BoardView: View {
    let model: NotchModel
    @Binding var selectedTask: UUID?
    @State private var project: UUID?
    @State private var draft = ""
    @State private var targeted: BoardColumn?

    private var store: TaskStore { model.tasks }

    var body: some View {
        let board = TaskRules.board(store.tasks, project: project, now: model.now, calendar: .current)

        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Board")
                    .font(.system(size: 28, weight: .semibold))
                    .tracking(-0.5)
                Spacer()
                // A quiet text menu rather than a bordered pop-up: the header stays one title.
                Menu {
                    Picker("Project", selection: $project) {
                        Text("All projects").tag(UUID?.none)
                        if !store.projects.isEmpty { Divider() }
                        ForEach(store.sortedProjects) { p in Text(p.name).tag(UUID?.some(p.id)) }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } label: {
                    HStack(spacing: 5) {
                        Text(store.project(project)?.name ?? "All projects")
                        Image(systemName: "chevron.down").font(.system(size: 11, weight: .semibold))
                    }
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("Project")
            }
            .padding(.horizontal, 32)
            .padding(.top, 28)
            .padding(.bottom, 20)

            // Columns share the width; only when there's truly no room (say, with the inspector
            // open on a small window) does the board scroll sideways instead of squeezing.
            ViewThatFits(in: .horizontal) {
                columns(board, width: nil)
                ScrollView(.horizontal, showsIndicators: false) {
                    columns(board, width: Self.minColumnWidth)
                }
            }
        }
    }

    // MARK: Columns

    private static let minColumnWidth: CGFloat = 250

    private func columns(_ board: [BoardColumn: [NotchCore.TaskItem]], width: CGFloat?) -> some View {
        HStack(alignment: .top, spacing: 18) {
            ForEach(BoardColumn.allCases) { column in
                columnView(column, cards: board[column] ?? [])
                    .frame(
                        minWidth: width ?? Self.minColumnWidth,
                        idealWidth: width ?? Self.minColumnWidth,
                        maxWidth: width ?? .infinity
                    )
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 24)
    }

    private func columnView(_ column: BoardColumn, cards: [NotchCore.TaskItem]) -> some View {
        let overLimit = column == .doing && cards.count > TaskStore.doingLimit

        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(column.title)
                    .font(.system(size: 15, weight: .semibold))
                Text(column == .doing ? "\(cards.count) / \(TaskStore.doingLimit)" : "\(cards.count)")
                    .font(.system(size: 13).monospacedDigit())
                    .foregroundStyle(overLimit ? Palette.late : .secondary)
                Spacer()
                if column == .done {
                    Text("Last 7 days").font(.system(size: 12)).foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 6)

            if overLimit {
                Text("More than \(TaskStore.doingLimit) at once. Finish one before starting another.")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.late)
                    .padding(.horizontal, 6)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if column == .todo {
                HStack(spacing: 10) {
                    Image(systemName: "plus").foregroundStyle(.secondary)
                    TextField("Add a card", text: $draft)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14))
                        .onSubmit {
                            store.add(draft, project: project)
                            draft = ""
                        }
                }
                .padding(.horizontal, 12)
                .frame(height: 38)
                .background(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.10), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
            }

            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 10) {
                    ForEach(cards) { card in
                        BoardCard(model: model, task: card, showsProject: project == nil, isSelected: selectedTask == card.id)
                            .onTapGesture { selectedTask = card.id }
                            .draggable(card.id.uuidString) {
                                BoardCard(model: model, task: card, showsProject: project == nil, isSelected: true)
                                    .frame(width: 260)
                            }
                            .dropDestination(for: String.self) { items, _ in
                                drop(items, into: column, before: card.id, cards: cards)
                            }
                    }
                    if cards.isEmpty {
                        Text(emptyText(column))
                            .font(.system(size: 13))
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, minHeight: 80)
                    }
                }
                .padding(2)
            }
        }
        .padding(12)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.primary.opacity(targeted == column ? 0.07 : 0.035))
        )
        .dropDestination(for: String.self) { items, _ in
            drop(items, into: column, before: nil, cards: cards)
        } isTargeted: { over in
            targeted = over ? column : (targeted == column ? nil : targeted)
        }
    }

    private func drop(_ items: [String], into column: BoardColumn, before target: UUID?, cards: [NotchCore.TaskItem]) -> Bool {
        guard let id = items.first.flatMap(UUID.init(uuidString:)), id != target else { return false }
        withAnimation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.3)) {
            store.move(id, to: column, before: target, in: cards)
        }
        return true
    }

    private func emptyText(_ column: BoardColumn) -> String {
        switch column {
        case .todo: "Nothing waiting."
        case .doing: "Drag a card here when you start it."
        case .done: "Finished cards land here."
        }
    }
}

/// One card: title, then only the details that apply.
private struct BoardCard: View {
    let model: NotchModel
    let task: NotchCore.TaskItem
    let showsProject: Bool
    let isSelected: Bool

    var body: some View {
        let store = model.tasks
        let now = model.now
        let calendar = Calendar.current
        let blocked = store.isBlocked(task.id)
        let late = TaskRules.isOverdue(task, now: now, calendar: calendar)

        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Text(task.title)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(task.isDone || blocked ? Color.secondary : Color.primary)
                    .strikethrough(task.isDone)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if task.priority != .none {
                    Text(task.priority.marks)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Palette.accent)
                        .accessibilityLabel("\(task.priority.label) priority")
                }
            }

            let chips = chips(blocked: blocked, late: late, now: now, calendar: calendar)
            if !chips.isEmpty {
                FlowRow(spacing: 10) {
                    ForEach(chips, id: \.text) { chip in
                        Label(chip.text, systemImage: chip.symbol)
                            .font(.system(size: 12))
                            .foregroundStyle(chip.isLate ? Palette.late : Color.secondary)
                            .lineLimit(1)
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .textBackgroundColor))
                .shadow(color: .black.opacity(0.06), radius: 2, y: 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(isSelected ? Palette.accent : Color.primary.opacity(0.08), lineWidth: isSelected ? 2 : 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .contextMenu {
            ForEach(BoardColumn.allCases) { column in
                if column != task.column {
                    Button("Move to \(column.title)") { store.move(task.id, to: column) }
                }
            }
            if !task.isDone {
                Button("Focus on This") { model.startFocus(task: task.id) }
            }
            Divider()
            Button("Delete", role: .destructive) { store.delete(task.id) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint("Drag to another column to move it")
    }

    private struct Chip {
        let text: String
        let symbol: String
        var isLate = false
    }

    private func chips(blocked: Bool, late: Bool, now: Date, calendar: Calendar) -> [Chip] {
        var chips: [Chip] = []
        if let due = task.due, !task.isDone {
            chips.append(Chip(
                text: late ? TaskRules.lateness(due, now: now, calendar: calendar) : TaskRules.dueLabel(due, now: now, calendar: calendar),
                symbol: "calendar", isLate: late
            ))
        }
        if let progress = model.tasks.subtaskProgress(of: task.id) {
            chips.append(Chip(text: "\(progress.done)/\(progress.total)", symbol: "checklist"))
        }
        if blocked { chips.append(Chip(text: "Waiting", symbol: "lock")) }
        if task.recurrence != nil { chips.append(Chip(text: task.recurrence!.label, symbol: "repeat")) }
        if showsProject, let project = model.tasks.project(task.projectID) {
            chips.append(Chip(text: project.name, symbol: "folder"))
        }
        if task.status == .doing, !task.isDone, let started = task.startedAt {
            chips.append(Chip(text: "Started \(TimeText.weekdayClock(started, calendar: calendar))", symbol: "play"))
        }
        return chips
    }
}

/// Lays chips out left to right, wrapping to a new line when they run out of room.
private struct FlowRow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                y += lineHeight + 6
                x = 0
                lineHeight = 0
            }
            x += size.width + spacing
            widest = max(widest, x - spacing)
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: min(widest, width), height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                y += lineHeight + 6
                x = bounds.minX
                lineHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
