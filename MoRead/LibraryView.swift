import SwiftUI

private enum ShelfTagMatchMode: String, CaseIterable { case any = "任一标签", all = "全部标签" }

struct LibraryView: View {
    @EnvironmentObject var store: LibraryStore
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @ObservedObject private var shelfOrder = ShelfOrderStore.shared
    @State private var showingImporter = false
    @State private var showImportMethods = false
    @State private var showFolderPicker = false
    @State private var showLANTransfer = false
    @State private var folderSession: FolderImportSession?
    @State private var importing = false
    @State private var importProgressText: String?
    @State private var errorText: String?
    @State private var txtPreview: TxtImportSource?
    @State private var managingBook: Book?
    @State private var selectedBookID: Int64?

    @State private var collections: [BookCollection] = []
    @State private var groups: [ShelfGroup] = []
    @State private var tags: [BookTag] = []
    @State private var tagRefs: [BookTagRef] = []

    @State private var searchQuery = ""
    @State private var readStateFilter: BookReadState?
    @State private var groupFilterKey: Int64 = -1 // -1 all, 0 ungrouped, >0 group id
    @State private var selectedTagIds = Set<Int64>()
    @State private var tagMatchMode: ShelfTagMatchMode = .any

    @State private var selectionMode = false
    @State private var selectedBookIds = Set<Int64>()
    @State private var showBulkDelete = false

    var body: some View {
        Group {
            if horizontalSizeClass == .regular {
                NavigationSplitView {
                    sidebar
                } detail: {
                    if let book = selectedBook {
                        NavigationStack { BookDetailView(book: book) }
                    } else if store.isReady && !store.books.isEmpty {
                        ContentUnavailableView("选择一本书", systemImage: "books.vertical", description: Text("在左侧选择书籍查看详情、继续阅读或进入伴读。"))
                    } else {
                        libraryEmptyState
                    }
                }
            } else {
                NavigationStack {
                    compactLibrary
                        .navigationDestination(for: Int64.self) { id in
                            if let book = store.books.first(where: { $0.id == id }) { BookDetailView(book: book) }
                        }
                }
            }
        }
        .sheet(isPresented: $showingImporter) { importerSheet }
        .sheet(isPresented: $showFolderPicker) {
            FolderPicker { url in
                showFolderPicker = false
                prepareFolder(url)
            }
        }
        .sheet(item: $folderSession) { session in
            FolderImportPreviewView(
                session: session,
                onImport: { urls in
                    folderSession = nil
                    Task { @MainActor in
                        await importBatch(urls)
                        session.cleanup()
                    }
                },
                onCancel: { session.cleanup(); folderSession = nil }
            )
        }
        .sheet(isPresented: $showLANTransfer) {
            NavigationStack {
                LANTransferSettingsView()
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { showLANTransfer = false } } }
            }
        }
        .overlay {
            if importing {
                VStack(spacing: 10) {
                    ProgressView()
                    Text(importProgressText ?? "正在导入…")
                        .font(.callout)
                        .multilineTextAlignment(.center)
                }
                .padding()
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
        }
        .safeAreaInset(edge: .bottom) {
            if selectionMode { selectionBar }
        }
        .sheet(item: $managingBook) { book in BookManageView(book: book).environmentObject(store) }
        .sheet(item: $txtPreview) { source in
            TXTImportPreviewView(source: source) { draft in
                importing = true
                Task { @MainActor in
                    do { try await store.importBook(draft) } catch { errorText = error.localizedDescription }
                    importing = false
                }
            }
        }
        .confirmationDialog("导入书籍", isPresented: $showImportMethods, titleVisibility: .visible) {
            Button("选择 TXT / EPUB 文件") { showingImporter = true }
            Button("扫描文件夹") { showFolderPicker = true }
            Button("局域网传书") { showLANTransfer = true }
            Button("取消", role: .cancel) {}
        } message: {
            Text("文件支持一次多选；文件夹会递归扫描最多 500 本、最多 8 层。")
        }
        .confirmationDialog("移除所选书籍", isPresented: $showBulkDelete, titleVisibility: .visible) {
            Button("移除正文，保留个人记录") { bulkRemove(permanent: false) }
            Button("永久删除书籍与全部记录", role: .destructive) { bulkRemove(permanent: true) }
            Button("取消", role: .cancel) {}
        } message: {
            Text("已选择 \(selectedBookIds.count) 本。永久删除会同时删除批注、笔记、会话、插图、统计关联记录和缓存。")
        }
        .onReceive(NotificationCenter.default.publisher(for: .moReadLibraryDidChange)) { _ in
            Task {
                try? await store.refresh()
                await reloadShelfMetadata()
                keepSelectionValid()
                trimSelection()
            }
        }
        .onChange(of: store.books.map(\.id)) { _, _ in
            keepSelectionValid()
            trimSelection()
        }
        .task { await reloadShelfMetadata() }
        .alert("操作失败", isPresented: Binding(get: { errorText != nil || store.lastError != nil }, set: { if !$0 { errorText = nil; store.lastError = nil } })) {
            Button("好", role: .cancel) {}
        } message: { Text(errorText ?? store.lastError ?? "未知错误") }
    }

    private var selectedBook: Book? {
        selectedBookID.flatMap { id in store.books.first { $0.id == id } }
    }

    private var tagIdsByBook: [Int64: Set<Int64>] {
        Dictionary(grouping: tagRefs, by: \.bookId).mapValues { Set($0.map(\.tagId)) }
    }

    private var collectionNames: [Int64: String] {
        Dictionary(uniqueKeysWithValues: collections.map { ($0.id, $0.name) })
    }

    private var filteredBooks: [Book] {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return shelfOrder.ordered(store.books).filter { book in
            let stateMatches = readStateFilter == nil || effectiveReadState(book) == readStateFilter
            let groupMatches: Bool = switch groupFilterKey {
            case -1: true
            case 0: book.groupId == nil
            default: book.groupId == groupFilterKey
            }
            let bookTags = tagIdsByBook[book.id] ?? []
            let tagsMatch: Bool = selectedTagIds.isEmpty || (tagMatchMode == .any
                ? !bookTags.isDisjoint(with: selectedTagIds)
                : bookTags.isSuperset(of: selectedTagIds))
            let searchMatches: Bool
            if query.isEmpty {
                searchMatches = true
            } else {
                let tagNameMatch = tags.contains { tag in tagIdsByBook[book.id, default: []].contains(tag.id) && tag.name.localizedCaseInsensitiveContains(query) }
                let collectionMatch = book.collectionId.flatMap { collectionNames[$0] }?.localizedCaseInsensitiveContains(query) == true
                searchMatches = book.title.localizedCaseInsensitiveContains(query) ||
                    book.author.localizedCaseInsensitiveContains(query) || tagNameMatch || collectionMatch
            }
            return stateMatches && groupMatches && tagsMatch && searchMatches
        }
    }

    private var rootBooks: [Book] { filteredBooks.filter { $0.collectionId == nil } }
    private func collectionBooks(_ id: Int64) -> [Book] {
        filteredBooks.filter { $0.collectionId == id }.sorted { $0.collectionOrder < $1.collectionOrder }
    }
    private func allCollectionBooks(_ id: Int64) -> [Book] {
        store.books.filter { $0.collectionId == id }.sorted { $0.collectionOrder < $1.collectionOrder }
    }
    private var visibleBookIds: Set<Int64> { Set(filteredBooks.map(\.id)) }
    private var filterActive: Bool { readStateFilter != nil || groupFilterKey != -1 || !selectedTagIds.isEmpty }

    private var sidebar: some View {
        Group {
            if !store.isReady { ProgressView("正在载入书库…") }
            else if store.books.isEmpty { libraryEmptyState }
            else if filteredBooks.isEmpty { noResults }
            else {
                List(selection: selectionMode ? .constant(nil) : $selectedBookID) {
                    if !visibleCollections.isEmpty {
                        Section("合集") {
                            ForEach(visibleCollections) { collection in
                                collectionDisclosure(collection, compact: false)
                            }
                        }
                    }
                    if !rootBooks.isEmpty {
                        Section("书籍") {
                            ForEach(rootBooks) { book in
                                if selectionMode {
                                    Button { toggleSelection(book.id) } label: { bookRow(book, selected: selectedBookIds.contains(book.id)) }
                                        .buttonStyle(.plain)
                                        .draggable(String(book.id))
                                        .dropDestination(for: String.self) { items, _ in handleRootDrop(items, targetBookId: book.id) }
                                } else {
                                    bookRow(book).tag(book.id)
                                        .draggable(String(book.id))
                                        .dropDestination(for: String.self) { items, _ in handleRootDrop(items, targetBookId: book.id) }
                                        .contextMenu { bookMenu(book) }
                                }
                            }
                        }
                    }
                }
            }
        }
        .searchable(text: $searchQuery, prompt: "搜索书名、作者、标签、合集")
        .navigationTitle("墨知 MoRead")
        .toolbar { libraryToolbar }
        .onAppear { if selectedBookID == nil { selectedBookID = store.books.first?.id } }
    }

    private var compactLibrary: some View {
        Group {
            if !store.isReady { ProgressView("正在载入书库…") }
            else if store.books.isEmpty { libraryEmptyState }
            else if filteredBooks.isEmpty { noResults }
            else {
                List {
                    if !visibleCollections.isEmpty {
                        Section("合集") {
                            ForEach(visibleCollections) { collection in collectionDisclosure(collection, compact: true) }
                        }
                    }
                    if !rootBooks.isEmpty {
                        Section("书籍") {
                            ForEach(rootBooks) { book in
                                if selectionMode {
                                    Button { toggleSelection(book.id) } label: { bookRow(book, selected: selectedBookIds.contains(book.id)) }
                                        .buttonStyle(.plain)
                                        .draggable(String(book.id))
                                        .dropDestination(for: String.self) { items, _ in handleRootDrop(items, targetBookId: book.id) }
                                } else {
                                    NavigationLink(value: book.id) { bookRow(book) }
                                        .draggable(String(book.id))
                                        .dropDestination(for: String.self) { items, _ in handleRootDrop(items, targetBookId: book.id) }
                                        .contextMenu { bookMenu(book) }
                                }
                            }
                        }
                    }
                }
            }
        }
        .searchable(text: $searchQuery, prompt: "搜索书名、作者、标签、合集")
        .navigationTitle("墨知 MoRead")
        .toolbar { libraryToolbar }
    }

    private var visibleCollections: [BookCollection] {
        collections.filter { !collectionBooks($0.id).isEmpty }
    }

    private var libraryEmptyState: some View {
        ContentUnavailableView("还没有书", systemImage: "books.vertical", description: Text("导入 TXT 或 EPUB 开始阅读"))
    }

    private var noResults: some View {
        ContentUnavailableView("没有匹配的书", systemImage: "line.3.horizontal.decrease.circle", description: Text(filterActive ? "调整筛选条件或搜索词后重试。" : "换一个搜索词试试。"))
    }

    @ViewBuilder
    private func collectionDisclosure(_ collection: BookCollection, compact: Bool) -> some View {
        let books = collectionBooks(collection.id)
        DisclosureGroup {
            ForEach(books) { book in
                if selectionMode {
                    Button { toggleSelection(book.id) } label: { bookRow(book, selected: selectedBookIds.contains(book.id)) }
                        .buttonStyle(.plain)
                        .draggable(String(book.id))
                        .dropDestination(for: String.self) { items, _ in
                            handleCollectionMemberDrop(items, targetBookId: book.id, collectionId: collection.id)
                        }
                } else if compact {
                    NavigationLink(value: book.id) { bookRow(book) }
                        .draggable(String(book.id))
                        .dropDestination(for: String.self) { items, _ in
                            handleCollectionMemberDrop(items, targetBookId: book.id, collectionId: collection.id)
                        }
                        .contextMenu { bookMenu(book) }
                } else {
                    bookRow(book).tag(book.id)
                        .draggable(String(book.id))
                        .dropDestination(for: String.self) { items, _ in
                            handleCollectionMemberDrop(items, targetBookId: book.id, collectionId: collection.id)
                        }
                        .contextMenu { bookMenu(book) }
                }
            }
        } label: {
            HStack {
                Image(systemName: "square.stack.3d.up.fill")
                Text(collection.name).font(.headline)
                Spacer()
                Text("\(books.count) 本").font(.caption).foregroundStyle(.secondary)
                if selectionMode {
                    Button {
                        let ids = Set(books.map(\.id))
                        if selectedBookIds.isSuperset(of: ids) { selectedBookIds.subtract(ids) }
                        else { selectedBookIds.formUnion(ids) }
                    } label: {
                        Image(systemName: selectedBookIds.isSuperset(of: Set(books.map(\.id))) ? "checkmark.circle.fill" : "circle")
                    }
                    .buttonStyle(.borderless)
                }
            }
            .contentShape(Rectangle())
        }
        .dropDestination(for: String.self) { items, _ in
            guard !selectionMode, let raw = items.first, let bookId = Int64(raw), store.books.contains(where: { $0.id == bookId }) else { return false }
            Task {
                let next = (allCollectionBooks(collection.id).map(\.collectionOrder).max() ?? -1) + 1
                try? await BookshelfRepository.shared.setCollection(bookId: bookId, collectionId: collection.id, order: next)
                try? await store.refresh(); await reloadShelfMetadata()
            }
            return true
        }
    }

    private func bookRow(_ book: Book, selected: Bool? = nil) -> some View {
        HStack(spacing: 12) {
            if let selected {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
            }
            BookCoverThumbnail(book: book)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    if book.pinnedAt > 0 { Image(systemName: "pin.fill").font(.caption).foregroundStyle(.secondary) }
                    Text(book.title).font(.headline).lineLimit(2)
                    Spacer(minLength: 6)
                    Text("\(book.progressPercent)%").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                if !book.author.isEmpty { Text(book.author).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                Text("\(book.format) · \(book.totalChapters) 章 · \(effectiveReadState(book).label)")
                    .font(.caption2).foregroundStyle(.tertiary)
                ProgressView(value: book.progress)
            }
        }
        .padding(.vertical, 5)
    }

    @ViewBuilder
    private func bookMenu(_ book: Book) -> some View {
        Button(book.pinnedAt > 0 ? "取消置顶" : "置顶") {
            Task { try? await BookshelfRepository.shared.setPinned(bookId: book.id, pinned: book.pinnedAt == 0); try? await store.refresh() }
        }
        Menu("阅读状态") {
            Button("自动判断") { setState(book, nil) }
            ForEach(BookReadState.allCases, id: \.self) { state in Button(state.label) { setState(book, state) } }
        }
        Button("分组 / 合集 / 标签 / 信息") { managingBook = book }
        Button("进入多选") { selectionMode = true; selectedBookIds = [book.id] }
        Divider()
        Button("从书架移除", role: .destructive) {
            Task { try? await LibraryRepository.shared.softRemove(bookId: book.id); try? await store.refresh(); keepSelectionValid() }
        }
    }

    @ToolbarContentBuilder
    private var libraryToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            Menu {
                Menu("阅读状态") {
                    Button("全部") { readStateFilter = nil }
                    ForEach(BookReadState.allCases, id: \.self) { state in
                        Button { readStateFilter = state } label: { Label(state.label, systemImage: readStateFilter == state ? "checkmark" : "circle") }
                    }
                }
                Menu("分组") {
                    Button { groupFilterKey = -1 } label: { Label("全部", systemImage: groupFilterKey == -1 ? "checkmark" : "circle") }
                    Button { groupFilterKey = 0 } label: { Label("未分组", systemImage: groupFilterKey == 0 ? "checkmark" : "circle") }
                    ForEach(groups) { group in
                        Button { groupFilterKey = group.id } label: { Label(group.name, systemImage: groupFilterKey == group.id ? "checkmark" : "circle") }
                    }
                }
                if !tags.isEmpty {
                    Menu("标签") {
                        Picker("匹配方式", selection: $tagMatchMode) {
                            ForEach(ShelfTagMatchMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                        Divider()
                        ForEach(tags) { tag in
                            Button {
                                if !selectedTagIds.insert(tag.id).inserted { selectedTagIds.remove(tag.id) }
                            } label: {
                                Label(tag.name, systemImage: selectedTagIds.contains(tag.id) ? "checkmark.circle.fill" : "circle")
                            }
                        }
                    }
                }
                Divider()
                Toggle("最近阅读影响排序", isOn: $shelfOrder.readingOrderAffectsShelf)
                if filterActive {
                    Divider()
                    Button("清除筛选", systemImage: "line.3.horizontal.decrease.circle") { clearFilters() }
                }
            } label: {
                Image(systemName: filterActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
            }
            Button(selectionMode ? "完成" : "多选") {
                selectionMode.toggle()
                if !selectionMode { selectedBookIds.removeAll() }
            }
            if !selectionMode {
                NavigationLink { ShelfOrganizerView() } label: { Image(systemName: "books.vertical.fill") }
                Button { showImportMethods = true } label: { Label("导入", systemImage: "plus") }
            }
        }
    }

    private var selectionBar: some View {
        HStack(spacing: 12) {
            Button(selectedBookIds.isSuperset(of: visibleBookIds) && !visibleBookIds.isEmpty ? "取消全选" : "全选") {
                if selectedBookIds.isSuperset(of: visibleBookIds) { selectedBookIds.subtract(visibleBookIds) }
                else { selectedBookIds.formUnion(visibleBookIds) }
            }
            .disabled(visibleBookIds.isEmpty)
            Text("已选 \(selectedBookIds.count) 本").font(.callout.monospacedDigit())
            Spacer()
            Menu("批量操作") {
                Button("全部置顶", systemImage: "pin.fill") { bulkPinned(true) }
                Button("取消置顶", systemImage: "pin.slash") { bulkPinned(false) }
                Menu("阅读状态") {
                    Button("自动判断") { bulkReadState(nil) }
                    ForEach(BookReadState.allCases, id: \.self) { state in Button(state.label) { bulkReadState(state) } }
                }
                Menu("移动到分组") {
                    Button("未分组") { bulkGroup(nil) }
                    ForEach(groups) { group in Button(group.name) { bulkGroup(group.id) } }
                }
                if !tags.isEmpty {
                    Menu("添加标签") { ForEach(tags) { tag in Button(tag.name) { bulkTag(tag.id, add: true) } } }
                    Menu("移除标签") { ForEach(tags) { tag in Button(tag.name) { bulkTag(tag.id, add: false) } } }
                }
                Menu("合集") {
                    Button("移出合集") { bulkCollection(nil) }
                    ForEach(collections) { collection in Button("加入 \(collection.name)") { bulkCollection(collection.id) } }
                }
                Divider()
                Button("移除所选书籍", systemImage: "trash", role: .destructive) { showBulkDelete = true }
            }
            .disabled(selectedBookIds.isEmpty)
            Button("完成") { selectionMode = false; selectedBookIds.removeAll() }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.regularMaterial)
    }

    private func prepareFolder(_ url: URL) {
        importing = true
        importProgressText = "正在扫描文件夹…"
        let existing = Set(store.books.map { $0.title.trimmingCharacters(in: .whitespacesAndNewlines) })
        Task { @MainActor in
            do {
                let session = try await FolderImportScanner.prepare(folderURL: url, existingTitles: existing)
                importing = false
                importProgressText = nil
                if session.candidates.isEmpty {
                    session.cleanup()
                    errorText = "所选文件夹及前 8 层子目录中没有找到 TXT / EPUB。"
                } else {
                    folderSession = session
                }
            } catch {
                importing = false
                importProgressText = nil
                errorText = error.localizedDescription
            }
        }
    }

    private var importerSheet: some View {
        ExtensionFilePicker(extensions: ["txt", "epub"], allowsMultiple: true) { urls in
            showingImporter = false
            guard !urls.isEmpty else { return }
            Task { @MainActor in
                if urls.count == 1, let url = urls.first, url.pathExtension.lowercased() == "txt" {
                    importing = true
                    importProgressText = "正在读取 TXT 并准备分章预览…"
                    do {
                        txtPreview = try await Task.detached(priority: .userInitiated) { try TextImporter.loadSource(url: url) }.value
                    } catch { errorText = error.localizedDescription }
                    importing = false
                    importProgressText = nil
                } else {
                    await importBatch(urls)
                }
            }
        }
    }

    @MainActor
    private func importBatch(_ urls: [URL]) async {
        importing = true
        var failures: [String] = []
        var successes = 0
        for (offset, url) in urls.enumerated() {
            importProgressText = "正在导入 \(offset + 1)/\(urls.count) · \(url.lastPathComponent)"
            do {
                let draft = try await BookImportService.importBook(url: url)
                try await store.importBook(draft)
                successes += 1
            } catch {
                failures.append("\(url.lastPathComponent)：\(error.localizedDescription)")
            }
        }
        importing = false
        importProgressText = nil
        try? await store.refresh()
        await reloadShelfMetadata()
        keepSelectionValid()
        if !failures.isEmpty {
            let summary = failures.prefix(8).joined(separator: "\n")
            let more = failures.count > 8 ? "\n其余 \(failures.count - 8) 个失败文件略。" : ""
            errorText = "批量导入完成：成功 \(successes) 本，失败 \(failures.count) 本。\n\n\(summary)\(more)"
        }
    }

    private func handleRootDrop(_ items: [String], targetBookId: Int64) -> Bool {
        guard !selectionMode, let raw = items.first, let sourceId = Int64(raw), sourceId != targetBookId,
              let source = store.books.first(where: { $0.id == sourceId }),
              let target = store.books.first(where: { $0.id == targetBookId }) else { return false }
        // Pinned and unpinned sections are intentionally separate; a drag cannot silently change pin state.
        guard (source.pinnedAt > 0) == (target.pinnedAt > 0) else { return false }
        Task { @MainActor in
            do {
                if source.collectionId != nil {
                    try await BookshelfRepository.shared.setCollection(bookId: sourceId, collectionId: nil, order: 0)
                    try await store.refresh()
                }
                // Reorder only the currently visible root books. Hidden rows keep their saved positions.
                var visible = rootBooks.map(\.id)
                if !visible.contains(sourceId) { visible.append(sourceId) }
                visible.removeAll { $0 == sourceId }
                guard let targetIndex = visible.firstIndex(of: targetBookId) else { return }
                visible.insert(sourceId, at: targetIndex)
                shelfOrder.saveVisibleOrder(visible, allBooks: store.books)
                try await store.refresh()
                await reloadShelfMetadata()
            } catch { errorText = error.localizedDescription }
        }
        return true
    }

    private func handleCollectionMemberDrop(_ items: [String], targetBookId: Int64, collectionId: Int64) -> Bool {
        guard !selectionMode, let raw = items.first, let sourceId = Int64(raw), sourceId != targetBookId,
              let source = store.books.first(where: { $0.id == sourceId }),
              let target = store.books.first(where: { $0.id == targetBookId }),
              target.collectionId == collectionId else { return false }
        Task { @MainActor in
            do {
                if source.collectionId != collectionId {
                    try await BookshelfRepository.shared.setCollection(bookId: sourceId, collectionId: collectionId, order: Int.max / 4)
                    try await store.refresh()
                }
                var ids = allCollectionBooks(collectionId).map(\.id)
                ids.removeAll { $0 == sourceId }
                guard let targetIndex = ids.firstIndex(of: targetBookId) else { return }
                ids.insert(sourceId, at: targetIndex)
                try await BookshelfRepository.shared.reorderCollection(bookIds: ids, collectionId: collectionId)
                try await store.refresh()
                await reloadShelfMetadata()
            } catch { errorText = error.localizedDescription }
        }
        return true
    }

    private func setState(_ book: Book, _ state: BookReadState?) {
        Task { try? await BookshelfRepository.shared.setReadState(bookId: book.id, state: state); try? await store.refresh() }
    }

    private func effectiveReadState(_ book: Book) -> BookReadState {
        if let raw = book.manualReadState, let manual = BookReadState(rawValue: raw) { return manual }
        if book.lastReadAt == 0 { return .unread }
        if book.reachedEnd { return .finished }
        return .reading
    }

    @MainActor
    private func reloadShelfMetadata() async {
        do {
            async let c = BookshelfRepository.shared.collections()
            async let g = BookshelfRepository.shared.groups()
            async let t = BookshelfRepository.shared.tags()
            async let r = BookshelfRepository.shared.tagRefs()
            (collections, groups, tags, tagRefs) = try await (c, g, t, r)
        } catch { errorText = error.localizedDescription }
    }

    private func clearFilters() {
        readStateFilter = nil
        groupFilterKey = -1
        selectedTagIds.removeAll()
        tagMatchMode = .any
    }

    private func toggleSelection(_ id: Int64) {
        if !selectedBookIds.insert(id).inserted { selectedBookIds.remove(id) }
    }

    private func trimSelection() {
        selectedBookIds.formIntersection(Set(store.books.map(\.id)))
        if selectedBookIds.isEmpty && selectionMode && store.books.isEmpty { selectionMode = false }
    }

    private func keepSelectionValid() {
        if let selectedBookID, store.books.contains(where: { $0.id == selectedBookID }) { return }
        selectedBookID = store.books.first?.id
    }

    private func afterBulkMutation(message: String? = nil) {
        Task { @MainActor in
            try? await store.refresh()
            await reloadShelfMetadata()
            trimSelection()
            if let message { errorText = nil }
        }
    }

    private func bulkPinned(_ pinned: Bool) {
        let ids = selectedBookIds
        Task { @MainActor in
            do {
                for id in ids { try await BookshelfRepository.shared.setPinned(bookId: id, pinned: pinned) }
                try await store.refresh(); await reloadShelfMetadata()
                selectedBookIds.removeAll(); selectionMode = false
            } catch { errorText = error.localizedDescription }
        }
    }

    private func bulkReadState(_ state: BookReadState?) {
        let ids = selectedBookIds
        Task { @MainActor in
            do {
                for id in ids { try await BookshelfRepository.shared.setReadState(bookId: id, state: state) }
                try await store.refresh(); selectedBookIds.removeAll(); selectionMode = false
            } catch { errorText = error.localizedDescription }
        }
    }

    private func bulkGroup(_ groupId: Int64?) {
        let ids = selectedBookIds
        Task { @MainActor in
            do {
                for id in ids { try await BookshelfRepository.shared.setGroup(bookId: id, groupId: groupId) }
                try await store.refresh(); await reloadShelfMetadata(); selectedBookIds.removeAll(); selectionMode = false
            } catch { errorText = error.localizedDescription }
        }
    }

    private func bulkCollection(_ collectionId: Int64?) {
        let ids = selectedBookIds
        Task { @MainActor in
            do {
                let existing = collectionId.map { allCollectionBooks($0).map(\.collectionOrder).max() ?? -1 } ?? -1
                var next = existing + 1
                for id in ids.sorted() {
                    try await BookshelfRepository.shared.setCollection(bookId: id, collectionId: collectionId, order: collectionId == nil ? 0 : next)
                    next += 1
                }
                try await store.refresh(); await reloadShelfMetadata(); selectedBookIds.removeAll(); selectionMode = false
            } catch { errorText = error.localizedDescription }
        }
    }

    private func bulkTag(_ tagId: Int64, add: Bool) {
        let ids = selectedBookIds
        let map = tagIdsByBook
        Task { @MainActor in
            do {
                for id in ids {
                    var current = map[id] ?? []
                    if add { current.insert(tagId) } else { current.remove(tagId) }
                    try await BookshelfRepository.shared.setTags(bookId: id, tagIds: Array(current))
                }
                await reloadShelfMetadata()
            } catch { errorText = error.localizedDescription }
        }
    }

    private func bulkRemove(permanent: Bool) {
        let ids = selectedBookIds
        Task { @MainActor in
            do {
                for id in ids {
                    if permanent { try await LibraryRepository.shared.permanentlyDelete(bookId: id) }
                    else { try await LibraryRepository.shared.softRemove(bookId: id) }
                }
                try await store.refresh(); await reloadShelfMetadata()
                selectedBookIds.removeAll(); selectionMode = false; keepSelectionValid()
            } catch { errorText = error.localizedDescription }
        }
    }
}

private struct BookCoverThumbnail: View {
    let book: Book
    var body: some View {
        Group {
            if let path = book.coverPath, let image = UIImage(contentsOfFile: path) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 8).fill(.secondary.opacity(0.12))
                    Text(String(book.title.prefix(2))).font(.headline)
                }
            }
        }
        .frame(width: 48, height: 70)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
