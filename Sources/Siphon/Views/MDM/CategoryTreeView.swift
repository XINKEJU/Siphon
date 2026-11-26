import SwiftUI

/// MDM's category tree: four roots (All Downloads / Unfinished / Finished /
/// Queues) and the built-in file-type categories underneath "All Downloads".
/// Width is fixed at 143pt — the IDM-derived measure MDM uses.
struct MDMCategoryTreeView: View {
    @Environment(DownloadStore.self) private var store
    @Binding var selection: MDMCategory
    @Binding var selectedQueue: String?

    var body: some View {
        List(selection: Binding(
            get: { selection },
            set: { newValue in
                selection = newValue
                if newValue != .queues { selectedQueue = nil }
            }
        )) {
            Section {
                row(.all, count: store.tasks.count)
                row(.unfinished, count: store.tasks.filter { MDMCategory.unfinished.contains($0) }.count)
                row(.finished, count: store.tasks.filter { MDMCategory.finished.contains($0) }.count)
                row(.queues, count: store.tasks.count)
            } header: {
                Text(MDMI18n.t("category.all")).font(.caption2)
            }

            Section {
                ForEach(fileTypes, id: \.self) { category in
                    row(category, count: store.tasks.filter { category.contains($0) }.count)
                }
            } header: {
                Text(MDMI18n.t("options.fileTypes")).font(.caption2)
            }

            if selection == .queues {
                Section {
                    ForEach(store.queues.queues) { queue in
                        HStack(spacing: 6) {
                            Image(systemName: "line.3.horizontal")
                                .font(.system(size: 10))
                            Text(queue.name).lineLimit(1)
                            Spacer(minLength: 2)
                            Text("\(store.tasks.filter { $0.queueName == queue.name }.count)")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { selectedQueue = queue.name }
                    }
                } header: {
                    Text(MDMI18n.t("category.queues")).font(.caption2)
                }
            }
        }
        .listStyle(.sidebar)
        .frame(width: 143)
        .font(.system(size: 12))
    }

    private var fileTypes: [MDMCategory] {
        [.general, .compressed, .documents, .music, .programs, .video, .torrents]
    }

    @ViewBuilder
    private func row(_ category: MDMCategory, count: Int) -> some View {
        HStack(spacing: 6) {
            Image(systemName: category.symbolName)
                .font(.system(size: 12))
                .foregroundStyle(category == .finished ? .green : .accentColor)
            Text(category.displayName).lineLimit(1)
            Spacer(minLength: 2)
            if count > 0 {
                Text("\(count)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .tag(category)
    }
}
