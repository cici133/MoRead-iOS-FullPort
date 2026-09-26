import AVFoundation
import Foundation

@MainActor final class AudiobookPlaybackSession:NSObject,ObservableObject,AVAudioPlayerDelegate,AVSpeechSynthesizerDelegate{
    @Published var playing=false;@Published var currentIndex=0;@Published var errorText:String?
    private var book:Book?;private var chapter:Chapter?;private var roles:[Int64:AudiobookRole]=[:];private var segments:[AudiobookSegment]=[];private var body="";private var player:AVAudioPlayer?;private let synthesizer=AVSpeechSynthesizer();private var task:Task<Void,Never>?
    override init(){super.init();synthesizer.delegate=self}
    func load(book:Book,chapter:Chapter,body:String,roles:[AudiobookRole],segments:[AudiobookSegment]){stop();self.book=book;self.chapter=chapter;self.body=body;self.roles=Dictionary(uniqueKeysWithValues:roles.map{($0.id,$0)});self.segments=segments;currentIndex=min(currentIndex,max(0,segments.count-1))}
    func play(){guard !segments.isEmpty else{return};playing=true;playCurrent()}
    func pause(){playing=false;if player?.isPlaying == true{player?.pause()};if synthesizer.isSpeaking{synthesizer.pauseSpeaking(at:.immediate)}}
    func resume(){guard !playing else{return};playing=true;if let p=player,p.currentTime>0,!p.isPlaying{p.play();return};if synthesizer.isPaused{synthesizer.continueSpeaking();return};playCurrent()}
    func stop(){playing=false;task?.cancel();task=nil;player?.stop();player=nil;synthesizer.stopSpeaking(at:.immediate);currentIndex=0}
    func next(){guard !segments.isEmpty else{return};player?.stop();synthesizer.stopSpeaking(at:.immediate);currentIndex=min(segments.count-1,currentIndex+1);if playing{playCurrent()}}
    func previous(){guard !segments.isEmpty else{return};player?.stop();synthesizer.stopSpeaking(at:.immediate);currentIndex=max(0,currentIndex-1);if playing{playCurrent()}}
    var currentRoleName:String{guard segments.indices.contains(currentIndex),let id=segments[currentIndex].roleId else{return"旁白"};return roles[id]?.name ?? "旁白"}
    var progressLabel:String{segments.isEmpty ? "0 / 0":"\(currentIndex+1) / \(segments.count)"}
    private func playCurrent(){guard playing,segments.indices.contains(currentIndex) else{if currentIndex>=segments.count{playing=false};return};let segment=segments[currentIndex];guard let role=segment.roleId.flatMap({roles[$0]}) else{advance();return};let ns=body as NSString;let start=max(0,min(ns.length,segment.start)),end=max(start,min(ns.length,segment.end));let text=ns.substring(with:NSRange(location:start,length:end-start)).replacingOccurrences(of:"\u{FFFC}",with:" ").trimmingCharacters(in:.whitespacesAndNewlines);if text.isEmpty{advance();return}
        do{try configureAudioSession()}catch{errorText=error.localizedDescription}
        if role.engine == .system{let u=AVSpeechUtterance(string:text);let settings=TTSSettingsStore.shared.settings;u.rate=Float(min(2,max(0.5,settings.systemRate))*Double(AVSpeechUtteranceDefaultSpeechRate));u.pitchMultiplier=Float(min(2,max(0.5,settings.systemPitch)));u.voice=role.voiceId.isEmpty ? (settings.systemVoiceIdentifier.isEmpty ? AVSpeechSynthesisVoice(language:settings.systemLanguageTag.nilIfEmpty ?? Locale.preferredLanguages.first):AVSpeechSynthesisVoice(identifier:settings.systemVoiceIdentifier)):AVSpeechSynthesisVoice(identifier:role.voiceId);synthesizer.speak(u)}else{task?.cancel();task=Task{do{let url:URL;if let path=segment.audioPath,!path.isEmpty,FileManager.default.fileExists(atPath:path){url=URL(fileURLWithPath:path)}else{url=try await CloudSpeechService.shared.cachedSpeech(text:text,voice:role.voiceId.isEmpty ? TTSSettingsStore.shared.settings.aiVoiceId:role.voiceId,bookId:book?.id)};guard !Task.isCancelled,self.playing else{return};let p=try AVAudioPlayer(contentsOf:url);p.delegate=self;self.player=p;p.play()}catch{self.errorText=error.localizedDescription;self.advance()}}}
    }
    private func advance(){guard playing else{return};if currentIndex+1<segments.count{currentIndex += 1;playCurrent()}else{playing=false}}
    private func configureAudioSession()throws{let s=AVAudioSession.sharedInstance();let mix=TTSSettingsStore.shared.settings.allowAudioMixing;try s.setCategory(.playback,mode:.spokenAudio,options:mix ? [.mixWithOthers]:[]);try s.setActive(true)}
    nonisolated func audioPlayerDidFinishPlaying(_ player:AVAudioPlayer,successfully flag:Bool){Task { @MainActor [weak self] in self?.advance() }}
    nonisolated func speechSynthesizer(_ synthesizer:AVSpeechSynthesizer,didFinish utterance:AVSpeechUtterance){Task { @MainActor [weak self] in self?.advance() }}
}
private extension String{var nilIfEmpty:String?{isEmpty ? nil:self}}
