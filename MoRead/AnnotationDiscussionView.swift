import SwiftUI

struct AnnotationDiscussionView: View {
    let annotation: ReaderAnnotation
    let book: Book
    @Environment(\.dismiss) private var dismiss
    @State private var replies: [AnnotationReplyRecord] = []
    @State private var personas: [PersonaRecord] = []
    @State private var personaId: Int64?
    @State private var input = ""
    @State private var running = false
    @State private var error: String?

    private var persona: PersonaRecord? { personas.first { $0.id == personaId } }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(annotation.selectedText).italic().textSelection(.enabled)
                            if !annotation.note.isEmpty { Text(annotation.note).textSelection(.enabled) }
                            AnnotationMediaView(mediaJSON: annotation.mediaJSON)
                        }
                        .padding()
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))

                        ForEach(replies) { reply in
                            HStack {
                                if reply.personaId == nil { Spacer(minLength: 48) }
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(reply.personaId == nil ? "我" : personas.first(where: { $0.id == reply.personaId })?.name ?? "已删除角色")
                                        .font(.caption).foregroundStyle(.secondary)
                                    Text(reply.contentMarkdown).textSelection(.enabled)
                                    AnnotationMediaView(mediaJSON: reply.mediaJSON, compact: true)
                                }
                                .padding(10)
                                .background(reply.personaId == nil ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
                                if reply.personaId != nil { Spacer(minLength: 48) }
                            }
                        }
                    }
                    .padding()
                }
                Divider()
                HStack {
                    Menu {
                        ForEach(personas) { p in Button(p.name) { personaId = p.id } }
                    } label: { Image(systemName: "person.crop.circle") }
                    TextField("继续讨论…", text: $input, axis: .vertical)
                        .lineLimit(1...5).textFieldStyle(.roundedBorder)
                    Button { send() } label: {
                        if running { ProgressView().controlSize(.small) }
                        else { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                    }
                    .disabled(running || input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || persona == nil)
                }
                .padding()
            }
            .navigationTitle("批注讨论")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
            .task { await load() }
            .alert("讨论失败", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("好", role: .cancel) { }
            } message: { Text(error ?? "") }
        }
    }

    @MainActor
    private func load() async {
        do {
            replies = try await AnnotationDiscussionRepository.shared.replies(annotationId: annotation.id)
            personas = try await PersonaRepository.shared.personas()
            personaId = personaId ?? personas.first?.id
        } catch { self.error = error.localizedDescription }
    }

    private func send() {
        guard let persona else { return }
        let clean = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        input = ""
        running = true
        Task { @MainActor in
            do {
                _ = try await AnnotationDiscussionRepository.shared.add(annotationId: annotation.id, personaId: nil, content: clean)
                let output = try await AnnotationDiscussionService.shared.reply(annotation: annotation, book: book, persona: persona, input: clean)
                _ = try await AnnotationDiscussionRepository.shared.add(annotationId: annotation.id, personaId: persona.id, content: output)
                await load()
            } catch { self.error = error.localizedDescription }
            running = false
        }
    }
}
