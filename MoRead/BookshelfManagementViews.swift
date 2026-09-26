import SwiftUI

@MainActor
final class BookshelfManagerModel: ObservableObject {
    @Published var groups: [ShelfGroup] = []
    @Published var collections: [BookCollection] = []
    @Published var tags: [BookTag] = []
    @Published var errorText: String?

    func load() async {
        do {
            async let g = BookshelfRepository.shared.groups()
            async let c = BookshelfRepository.shared.collections()
            async let t = BookshelfRepository.shared.tags()
            (groups, collections, tags) = try await (g, c, t)
        } catch { errorText = error.localizedDescription }
    }
}

struct BookManageView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var library: LibraryStore
    @StateObject private var model = BookshelfManagerModel()
    let book: Book
    @State private var title: String
    @State private var author: String
    @State private var groupId: Int64?
    @State private var collectionId: Int64?
    @State private var tagIds = Set<Int64>()
    @State private var state: BookReadState?
    @State private var pinned: Bool
    @State private var saving = false
    @State private var errorText: String?

    init(book: Book) {
        self.book = book
        _title = State(initialValue: book.title); _author = State(initialValue: book.author)
        _groupId = State(initialValue: book.groupId); _collectionId = State(initialValue: book.collectionId)
        _state = State(initialValue: book.manualReadState.flatMap(BookReadState.init(rawValue:)))
        _pinned = State(initialValue: book.pinnedAt > 0)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("书籍信息") { TextField("书名", text: $title); TextField("作者", text: $author) }
                Section("书架") {
                    Toggle("置顶", isOn: $pinned)
                    Picker("阅读状态", selection: $state) {
                        Text("自动判断").tag(BookReadState?.none)
                        ForEach(BookReadState.allCases, id: \.self) { Text($0.label).tag(Optional($0)) }
                    }
                    Picker("分组", selection: $groupId) {
                        Text("未分组").tag(Int64?.none)
                        ForEach(model.groups) { Text($0.name).tag(Optional($0.id)) }
                    }
                    Picker("合集", selection: $collectionId) {
                        Text("无合集").tag(Int64?.none)
                        ForEach(model.collections) { Text($0.name).tag(Optional($0.id)) }
                    }
                }
                Section("标签") {
                    if model.tags.isEmpty { Text("还没有标签，可在书架管理中创建").foregroundStyle(.secondary) }
                    ForEach(model.tags) { tag in
                        Toggle(tag.name, isOn: Binding(get: { tagIds.contains(tag.id) }, set: { value in if value { tagIds.insert(tag.id) } else { tagIds.remove(tag.id) } }))
                    }
                }
            }
            .navigationTitle("管理《\(book.title)》")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button(saving ? "保存中…" : "保存") { save() }.disabled(saving) }
            }
            .task {
                await model.load()
                tagIds = Set((try? await BookshelfRepository.shared.tags(bookId: book.id).map(\.id)) ?? [])
            }
            .alert("保存失败", isPresented: Binding(get: { errorText != nil || model.errorText != nil }, set: { if !$0 { errorText = nil; model.errorText = nil } })) { Button("好", role: .cancel) {} } message: { Text(errorText ?? model.errorText ?? "") }
        }
    }

    private func save() {
        saving = true
        Task {
            do {
                try await BookshelfRepository.shared.updateMetadata(bookId: book.id, title: title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? book.title : title.trimmingCharacters(in: .whitespacesAndNewlines), author: author.trimmingCharacters(in: .whitespacesAndNewlines), coverPath: book.coverPath)
                try await BookshelfRepository.shared.setPinned(bookId: book.id, pinned: pinned)
                try await BookshelfRepository.shared.setReadState(bookId: book.id, state: state)
                try await BookshelfRepository.shared.setGroup(bookId: book.id, groupId: groupId)
                try await BookshelfRepository.shared.setCollection(bookId: book.id, collectionId: collectionId, order: book.collectionOrder)
                try await BookshelfRepository.shared.setTags(bookId: book.id, tagIds: Array(tagIds))
                try await library.refresh(); saving = false; dismiss()
            } catch { saving = false; errorText = error.localizedDescription }
        }
    }
}

struct ShelfOrganizerView: View {
    @EnvironmentObject private var library: LibraryStore
    @StateObject private var model = BookshelfManagerModel()
    @State private var createKind: CreateKind?
    @State private var newName = ""
    enum CreateKind: String, Identifiable { case group = "新建分组", collection = "新建合集", tag = "新建标签"; var id: String { rawValue } }

    var body: some View {
        List {
            Section("分组") {
                ForEach(model.groups) { group in Text(group.name) }
                    .onDelete { set in Task { for i in set where model.groups.indices.contains(i) { try? await BookshelfRepository.shared.deleteGroup(model.groups[i].id) }; await model.load(); try? await library.refresh() } }
                Button("新建分组") { newName = ""; createKind = .group }
            }
            Section("合集") {
                ForEach(model.collections) { collection in NavigationLink(collection.name) { CollectionOrderView(collection: collection) } }
                    .onDelete { set in Task { for i in set where model.collections.indices.contains(i) { try? await BookshelfRepository.shared.deleteCollection(model.collections[i].id) }; await model.load(); try? await library.refresh() } }
                Button("新建合集") { newName = ""; createKind = .collection }
            }
            Section("标签") {
                ForEach(model.tags) { tag in HStack { Text(tag.name); Spacer(); if !tag.groupName.isEmpty { Text(tag.groupName).font(.caption).foregroundStyle(.secondary) } } }
                Button("新建标签") { newName = ""; createKind = .tag }
            }
        }
        .navigationTitle("书架管理")
        .task { await model.load() }
        .alert(createKind?.rawValue ?? "新建", isPresented: Binding(get: { createKind != nil }, set: { if !$0 { createKind = nil } })) {
            TextField("名称", text: $newName)
            Button("取消", role: .cancel) { createKind = nil }
            Button("创建") { create() }
        }
        .alert("操作失败", isPresented: Binding(get: { model.errorText != nil }, set: { if !$0 { model.errorText = nil } })) { Button("好", role: .cancel) {} } message: { Text(model.errorText ?? "") }
    }

    private func create() {
        guard let kind = createKind else { return }
        let value = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        Task {
            do {
                switch kind {
                case .group: _ = try await BookshelfRepository.shared.createGroup(name: value)
                case .collection: _ = try await BookshelfRepository.shared.createCollection(name: value)
                case .tag: _ = try await BookshelfRepository.shared.createTag(name: value)
                }
                createKind = nil; await model.load()
            } catch { model.errorText = error.localizedDescription }
        }
    }
}

private struct CollectionOrderView: View {
    @EnvironmentObject private var library: LibraryStore
    let collection: BookCollection
    @State private var books: [Book] = []
    @State private var errorText: String?
    var body: some View {
        List {
            ForEach(books) { book in HStack { Image(systemName: "line.3.horizontal"); Text(book.title); Spacer(); Text("\(book.progressPercent)%").foregroundStyle(.secondary) } }
                .onMove { source, target in
                    books.move(fromOffsets: source, toOffset: target)
                    Task { do { try await BookshelfRepository.shared.reorderCollection(bookIds: books.map(\.id), collectionId: collection.id); try await library.refresh() } catch { errorText = error.localizedDescription } }
                }
        }
        .environment(\.editMode, .constant(.active))
        .navigationTitle(collection.name)
        .task { books = library.books.filter { $0.collectionId == collection.id }.sorted { $0.collectionOrder < $1.collectionOrder } }
        .alert("排序失败", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) { Button("好", role: .cancel) {} } message: { Text(errorText ?? "") }
    }
}
