import SwiftUI

/// MDM's category tree: four roots (All Downloads / Unfinished / Finished /
/// Queues), the built-in file-type categories, and any user-defined custom
/// categories underneath. Width is fixed at 143pt — the IDM-derived measure
/// MDM uses.
///
/// Custom categories are not representable by `MDMCategory`, so the active
/// custom selection lives in `DownloadStore.selectedCategoryKey`. Selecting
/// any built-in / root node clears it; selecting a custom row clears the
/// built-in selection (`selection` becomes nil) so only one row highlights.
struct MDMCategoryTreeView: View {
    @Environment(DownloadStore.self) private var store
    @EnvironmentObject private var theme: MDMThemeStore
    @Binding var selection: MDMCategory?
    @Binding var selectedQueue: String?

    private var customCategories: [UserCategory] {
        CategoryStore.shared.categories.filter { !$0.isBuiltin }
    }

    var body: some View {
        List(selection: Binding(
            get: { selection },
            set: { newValue in
                store.selectedCategoryKey = nil
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

            if !customCategories.isEmpty {
                Section {
                    ForEach(customCategories) { cat in
                        customRow(cat, count: store.tasks.filter {
                            CategoryStore.shared.resolvedKey(for: $0) == cat.key
                        }.count)
                    }
                } header: {
                    Text("自定义分类").font(.caption2)
                }
            }

            if selection == .queues {
                Section {
                    ForEach(store.queues.queues) { queue in
                        HStack(spacing: 6) {
                            Image(systemName: "line.3.horizontal")
                                .font(theme.font(size: 10))
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
        .scrollContentBackground(.hidden)
        .background(theme.color(.listBackground))
        .frame(width: theme.scaled(143))
        .font(theme.font(size: 12))
    }

    private var fileTypes: [MDMCategory] {
        [.general, .compressed, .documents, .music, .programs, .video, .torrents]
    }

    @ViewBuilder
    private func row(_ category: MDMCategory, count: Int) -> some View {
        HStack(spacing: 6) {
            Image(systemName: category.symbolName)
                .font(theme.font(size: 12))
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

    @ViewBuilder
    private func customRow(_ cat: UserCategory, count: Int) -> some View {
        let selected = store.selectedCategoryKey == cat.key
        HStack(spacing: 6) {
            Image(systemName: cat.symbolName)
                .font(theme.font(size: 12))
                .foregroundStyle(selected ? Color.white : .accentColor)
            Text(cat.name).lineLimit(1)
                .foregroundStyle(selected ? Color.white : .primary)
            Spacer(minLength: 2)
            if count > 0 {
                Text("\(count)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(selected ? AnyShapeStyle(Color.white.opacity(0.85)) : AnyShapeStyle(.tertiary))
            }
        }
        .contentShape(Rectangle())
        .listRowBackground(
            RoundedRectangle(cornerRadius: 6)
                .fill(selected ? Color.accentColor : Color.clear)
                .padding(.horizontal, 2)
        )
        .onTapGesture {
            store.selectedCategoryKey = cat.key
            selection = nil          // drop the built-in highlight
            selectedQueue = nil
        }
    }
}
