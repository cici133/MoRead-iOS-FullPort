import AVFoundation
import Foundation

actor AudiobookProducer {
    static let shared=AudiobookProducer()

    func synthesize(bookId:Int64,chapterIndex:Int,onProgress:(@Sendable (AudiobookProductionProgress)->Void)?=nil)async throws->AudiobookProductionSummary{
        try await produce(bookId:bookId,chapterIndices:[chapterIndex],onProgress:onProgress)
    }

    func produce(bookId:Int64,chapterIndices:[Int],onProgress:(@Sendable (AudiobookProductionProgress)->Void)?=nil)async throws->AudiobookProductionSummary{
        let roles=try await AudiobookRepository.shared.roles(bookId:bookId);let roleMap=Dictionary(uniqueKeysWithValues:roles.map{($0.id,$0)});let chapters=try await LibraryRepository.shared.chapters(bookId:bookId);let map=Dictionary(uniqueKeysWithValues:chapters.map{($0.chapterIndex,$0)});let selected=chapterIndices.sorted().compactMap{map[$0]}
        let allSegments = try await selected.asyncMap { chapter in try await AudiobookRepository.shared.segments(bookId:bookId,chapterIndex:chapter.chapterIndex) }
        let totalAI=allSegments.flatMap{$0}.filter{seg in seg.roleId.flatMap{roleMap[$0]}?.engine == .ai}.count
        var completed=allSegments.flatMap{$0}.filter{seg in seg.roleId.flatMap{roleMap[$0]}?.engine == .ai && usable(seg.audioPath)}.count;var readyChapters=0
        let settings=await MainActor.run{TTSSettingsStore.shared.settings};let replacementRules=await MainActor.run{ReaderEnhancementSettingsStore.shared.settings.replacementRules}
        for chapter in selected{
            try Task.checkCancellation();guard var state=try await AudiobookRepository.shared.chapterState(bookId:bookId,chapterIndex:chapter.chapterIndex) else{throw CloudSpeechError.invalid("第 \(chapter.chapterIndex+1) 章尚未生成剧本")}
            guard state.status == .confirmed || state.status == .synthesizing || state.status == .ready else{throw CloudSpeechError.invalid("第 \(chapter.chapterIndex+1) 章剧本尚未确认")}
            let body=try await LibraryRepository.shared.chapterText(chapter);let revision=ReaderTextReplacementEngine.audiobookRevision(body,rules:replacementRules);let segments=try await AudiobookRepository.shared.segments(bookId:bookId,chapterIndex:chapter.chapterIndex)
            guard !segments.isEmpty else{throw CloudSpeechError.invalid("第 \(chapter.chapterIndex+1) 章尚未生成剧本")}
            if segments.contains(where:{$0.revision != revision}){try await AudiobookRepository.shared.markStale(bookId:bookId,chapterIndex:chapter.chapterIndex);throw CloudSpeechError.invalid("第 \(chapter.chapterIndex+1) 章正文已变化，请重新排剧本")}
            let aiSegments=segments.filter{seg in seg.roleId.flatMap{roleMap[$0]}?.engine == .ai};var chapterReady=aiSegments.filter{usable($0.audioPath)}.count
            try await AudiobookRepository.shared.setChapterStatus(bookId:bookId,chapterIndex:chapter.chapterIndex,status:.synthesizing,ready:chapterReady,totalMillis:segments.reduce(0){$0+$1.audioMillis})
            onProgress?(.init(chapterIndex:chapter.chapterIndex,chapterTitle:chapter.title,completedSegments:completed,totalSegments:totalAI))
            for segment in aiSegments where !usable(segment.audioPath){
                try Task.checkCancellation();guard let role=segment.roleId.flatMap({roleMap[$0]}) else{continue};let ns=body as NSString;let start=max(0,min(ns.length,segment.start)),end=max(start,min(ns.length,segment.end));let text=ReaderTextReplacementEngine.listeningText(body,start:start,end:end,rules:replacementRules).display.replacingOccurrences(of:"\u{FFFC}",with:" ").trimmingCharacters(in:.whitespacesAndNewlines)
                if text.isEmpty{try await AudiobookRepository.shared.markAudio(segmentId:segment.id,path:"",millis:0)}else{let url=try await synthesizeWithRetry(text: text, role: role, segment: segment, settings: settings, bookId: bookId);let millis=await durationMillis(url);try await AudiobookRepository.shared.markAudio(segmentId:segment.id,path:url.path,millis:millis)}
                chapterReady += 1;completed += 1;let refreshed=try await AudiobookRepository.shared.segments(bookId:bookId,chapterIndex:chapter.chapterIndex);try await AudiobookRepository.shared.setChapterStatus(bookId:bookId,chapterIndex:chapter.chapterIndex,status:.synthesizing,ready:chapterReady,totalMillis:refreshed.reduce(0){$0+$1.audioMillis});onProgress?(.init(chapterIndex:chapter.chapterIndex,chapterTitle:chapter.title,completedSegments:completed,totalSegments:totalAI))
            }
            let refreshed=try await AudiobookRepository.shared.segments(bookId:bookId,chapterIndex:chapter.chapterIndex);let refreshedAI=refreshed.filter{seg in seg.roleId.flatMap{roleMap[$0]}?.engine == .ai};let ready=refreshedAI.filter{usable($0.audioPath)}.count;let isReady=ready==refreshedAI.count;try await AudiobookRepository.shared.setChapterStatus(bookId:bookId,chapterIndex:chapter.chapterIndex,status:isReady ? .ready:.synthesizing,ready:ready,totalMillis:refreshed.reduce(0){$0+$1.audioMillis});if isReady{readyChapters += 1};state=try await AudiobookRepository.shared.chapterState(bookId:bookId,chapterIndex:chapter.chapterIndex) ?? state
        }
        return .init(completedSegments:completed,totalSegments:totalAI,readyChapters:readyChapters)
    }

    private func synthesizeWithRetry(text:String,role:AudiobookRole,segment:AudiobookSegment,settings:TTSSettings,bookId:Int64)async throws->URL{
        var last:Error?;for attempt in 0...max(0,min(5,settings.retryCount)){do{return try await CloudSpeechService.shared.cachedSpeech(text:text,voice:role.voiceId.isEmpty ? settings.aiVoiceId:role.voiceId,settings:settings,bookId:bookId)}catch is CancellationError{throw CancellationError()}catch{last=error;if attempt<settings.retryCount{try? await Task.sleep(for:.milliseconds(500 * (1 << attempt)))}}};throw last ?? CloudSpeechError.invalid("语音合成失败")
    }
    private func durationMillis(_ url:URL)async->Int64{let asset=AVURLAsset(url:url);if let d=try? await asset.load(.duration){let seconds=CMTimeGetSeconds(d);if seconds.isFinite{return Int64(max(0,seconds*1000))}};return 0}
    private func usable(_ path:String?)->Bool{guard let path else{return false};return path.isEmpty || FileManager.default.fileExists(atPath:path)}
}

private extension Array { func asyncMap<T>(_ transform:(Element) async throws->T) async rethrows->[T]{var out:[T]=[];out.reserveCapacity(count);for x in self{out.append(try await transform(x))};return out} }
