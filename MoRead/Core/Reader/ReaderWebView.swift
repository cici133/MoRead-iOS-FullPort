import SwiftUI
import WebKit

struct ReaderWebDocument {
    var fileURL: URL?
    var readAccessURL: URL?
    var plainText: String?
    var chapterIndex: Int
    var chapterTitle: String
    var enhancements: ReaderEnhancementSettings
    /// Canonical text.mz UTF-16 offset.
    var initialUTF16Offset: Int
    var annotations: [ReaderAnnotation]
    var preferences: ReaderPreferences
    /// Present whenever the rendered text is a canonical/plain-text representation. EPUB source
    /// XHTML without conversion deliberately leaves this nil and falls back to text anchors.
    var textMapping: ReaderTextMapping?
    /// Canonical source excerpt around the initial position. Used to resolve EPUB DOM positions
    /// without assuming DOM text offsets equal text.mz UTF-16 offsets.
    var initialAnchorText: String = ""
    var initialAnchorRelativeOffset: Int = 0
}

struct ReaderSelection: Equatable, Sendable {
    var text: String
    /// Canonical text.mz coordinate when a mapping exists; otherwise DOM approximation.
    var approximateUTF16Offset: Int
    var canonicalStart: Int? = nil
    var canonicalEnd: Int? = nil
}

@MainActor
final class ReaderWebController: ObservableObject {
    weak var webView: WKWebView?
    var textMapping: ReaderTextMapping?
    /// Canonical chapter text from text.mz. Even when WebKit renders the publisher XHTML,
    /// all durable coordinates stay in this source text and DOM ranges are resolved by anchors.
    var canonicalText: String = ""
    @Published var pageIndex = 0
    @Published var pageCount = 1
    @Published var visibleUTF16Offset = 0
    @Published var visibleUTF16End = 0
    @Published var visibleAnchorText = ""
    @Published var selection: ReaderSelection?

    func nextPage() { evaluate("window.moReadNextPage && window.moReadNextPage()") }
    func previousPage() { evaluate("window.moReadPreviousPage && window.moReadPreviousPage()") }
    func scrollTo(offset: Int, anchor: String = "", anchorRelativeOffset: Int = 0) {
        if textMapping == nil, !anchor.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let baseApproximation = max(0, offset - max(0, anchorRelativeOffset))
            evaluate("window.moReadScrollToAnchor && window.moReadScrollToAnchor(\(Self.jsString(anchor)),\(baseApproximation),\(max(0, anchorRelativeOffset)))")
        } else {
            let display = textMapping?.displayOffset(forSourceOffset: max(0, offset)) ?? max(0, offset)
            evaluate("window.moReadScrollToOffset && window.moReadScrollToOffset(\(display))")
        }
    }
    func setAutoRead(active: Bool, settings: AutoReadSettings) {
        let value = settings.normalized()
        evaluate("window.moReadSetAutoRead && window.moReadSetAutoRead(\(active ? "true":"false"),'\(value.mode.rawValue)',\(value.scrollDpPerSecond),\(value.pageIntervalSeconds))")
    }
    func search(_ query: String) { evaluate("window.moReadSearch && window.moReadSearch(\(Self.jsString(query)))") }
    func clearSearch() { evaluate("window.moReadClearSearch && window.moReadClearSearch()") }
    func scrollToFragment(_ fragment: String) {
        let clean = fragment.removingPercentEncoding ?? fragment
        guard !clean.isEmpty else { return }
        evaluate("window.moReadScrollToFragment && window.moReadScrollToFragment(\(Self.jsString(clean)))")
    }
    func setSpeechHighlight(_ range: NSRange?) {
        guard let range else {
            evaluate("window.moReadSpeechHighlight && window.moReadSpeechHighlight(-1,-1)")
            return
        }
        if textMapping == nil, !canonicalText.isEmpty {
            let anchor = BookTextSearch.anchor(around: range.location, in: canonicalText)
            let baseApproximation = max(0, range.location - anchor.relative)
            evaluate("window.moReadSpeechHighlightSource && window.moReadSpeechHighlightSource(\(Self.jsString(anchor.text)),\(baseApproximation),\(anchor.relative),\(range.length))")
        } else {
            let start = textMapping?.displayOffset(forSourceOffset: range.location) ?? range.location
            let end = textMapping?.displayOffset(forSourceOffset: range.location + range.length) ?? range.location + range.length
            evaluate("window.moReadSpeechHighlight && window.moReadSpeechHighlight(\(start),\(end))")
        }
    }
    func reloadAnnotations(_ annotations: [ReaderAnnotation]) {
        let data = annotations.map { row -> [String: Any] in
            let start = textMapping?.displayOffset(forSourceOffset: row.startCharOffset) ?? row.startCharOffset
            let end = textMapping?.displayOffset(forSourceOffset: row.endCharOffset) ?? row.endCharOffset
            var item: [String: Any] = ["id": String(row.id), "start": start, "end": end, "quote": row.selectedText, "color": row.colorTag, "style": row.style]
            if textMapping == nil, !canonicalText.isEmpty {
                let anchor = BookTextSearch.anchor(around: row.startCharOffset, in: canonicalText)
                item["anchor"] = anchor.text
                item["anchorApprox"] = max(0, row.startCharOffset - anchor.relative)
                item["anchorRelative"] = anchor.relative
                item["sourceLength"] = max(0, row.endCharOffset - row.startCharOffset)
            }
            return item
        }
        guard let raw = try? JSONSerialization.data(withJSONObject: data), let json = String(data: raw, encoding: .utf8) else { return }
        evaluate("window.moReadApplyAnnotations && window.moReadApplyAnnotations(\(json))")
    }
    func setTranslations(_ rows: [ParagraphTranslationRecord], visible: Bool) {
        let data = rows.filter { !$0.isHidden }.map { row -> [String: Any] in
            let start = textMapping?.displayOffset(forSourceOffset: row.start) ?? row.start
            let end = textMapping?.displayOffset(forSourceOffset: row.end) ?? row.end
            var item: [String: Any] = ["start": start, "end": end, "text": row.translatedText]
            if textMapping == nil, !canonicalText.isEmpty {
                let anchor = BookTextSearch.anchor(around: row.end, in: canonicalText)
                item["anchor"] = anchor.text
                item["anchorApprox"] = max(0, row.end - anchor.relative)
                item["anchorRelative"] = anchor.relative
            }
            return item
        }
        guard let raw = try? JSONSerialization.data(withJSONObject: data), let json = String(data: raw, encoding: .utf8) else { return }
        evaluate("window.moReadApplyTranslations && window.moReadApplyTranslations(\(json),\(visible ? "true":"false"))")
    }
    func setBionicReading(_ enabled: Bool) {
        evaluate("window.moReadSetBionic && window.moReadSetBionic(\(enabled ? "true" : "false"))")
    }
    func setWordGlosses(_ rows: [VocabularyEntry], visible: Bool) {
        let data = rows.compactMap { row -> [String: Any]? in
            guard let offset = row.charOffset, !row.shortGloss.isEmpty || !row.phonetic.isEmpty else { return nil }
            let wordLength = (row.word as NSString).length
            let start = textMapping?.displayOffset(forSourceOffset: offset) ?? offset
            let end = textMapping?.displayOffset(forSourceOffset: offset + wordLength) ?? offset + wordLength
            var item: [String: Any] = ["start": start, "end": end, "word": row.word, "phonetic": row.phonetic, "gloss": row.shortGloss]
            if textMapping == nil, !canonicalText.isEmpty {
                let anchor = BookTextSearch.anchor(around: offset, in: canonicalText)
                item["anchor"] = anchor.text
                item["anchorApprox"] = max(0, offset - anchor.relative)
                item["anchorRelative"] = anchor.relative
                item["sourceLength"] = wordLength
            }
            return item
        }
        guard let raw = try? JSONSerialization.data(withJSONObject: data), let json = String(data: raw, encoding: .utf8) else { return }
        evaluate("window.moReadApplyWordGlosses && window.moReadApplyWordGlosses(\(json),\(visible ? "true":"false"))")
    }
    private func evaluate(_ js: String) { webView?.evaluateJavaScript(js) }
    private static func jsString(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [value]), let json = String(data: data, encoding: .utf8) else { return "\"\"" }
        return String(json.dropFirst().dropLast())
    }
}

struct ReaderWebView: UIViewRepresentable {
    let document: ReaderWebDocument
    @ObservedObject var controller: ReaderWebController
    var onTapAction: (ReaderTapAction) -> Void
    var onSelection: (ReaderSelection?) -> Void
    var onImageLongPress: (URL?) -> Void
    var onLink: (URL) -> Void
    var onBoundary: (Int) -> Void
    var onQuickBookmark: () -> Void
    var onReady: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> WKWebView {
        let content = WKUserContentController()
        content.add(context.coordinator, name: "moread")
        content.addUserScript(.init(source: Self.script(document: document), injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        let config = WKWebViewConfiguration()
        config.userContentController = content
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        web.scrollView.contentInsetAdjustmentBehavior = .never
        web.isOpaque = false
        web.backgroundColor = .clear
        controller.webView = web
        controller.textMapping = document.textMapping
        controller.canonicalText = document.plainText ?? ""
        load(web)
        return web
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
        controller.webView = webView
        controller.textMapping = document.textMapping
        controller.canonicalText = document.plainText ?? ""
    }

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: "moread")
        uiView.stopLoading()
    }

    private func load(_ web: WKWebView) {
        if let file = document.fileURL, let root = document.readAccessURL {
            web.loadFileURL(file, allowingReadAccessTo: root)
            return
        }
        // Keep literal newlines inside one canonical text tree. Replacing them with <br> loses one
        // UTF-16 unit per paragraph and causes notes/TTS/search offsets to drift.
        let escaped = Self.htmlEscape(document.plainText ?? "")
        let title = Self.htmlEscape(document.chapterTitle)
        let html = """
        <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no"><meta charset="utf-8"></head><body><header id="moread-title" class="moread-ui">\(title)</header><main id="moread-text">\(escaped)</main></body></html>
        """
        web.loadHTMLString(html, baseURL: nil)
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var parent: ReaderWebView
        init(parent: ReaderWebView) { self.parent = parent }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { parent.controller.webView = webView }
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "moread", let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
            Task { @MainActor in
                switch type {
                case "ready":
                    parent.controller.pageCount = max(1, (body["pageCount"] as? NSNumber)?.intValue ?? 1)
                    parent.controller.pageIndex = max(0, (body["pageIndex"] as? NSNumber)?.intValue ?? 0)
                    parent.onReady()
                case "position":
                    let raw = max(0, (body["offset"] as? NSNumber)?.intValue ?? 0)
                    let rawEnd = max(raw, (body["endOffset"] as? NSNumber)?.intValue ?? raw)
                    parent.controller.visibleUTF16Offset = parent.document.textMapping?.sourceOffset(forDisplayOffset: raw) ?? raw
                    parent.controller.visibleUTF16End = parent.document.textMapping?.sourceOffset(forDisplayOffset: rawEnd) ?? rawEnd
                    parent.controller.visibleAnchorText = body["anchor"] as? String ?? ""
                    parent.controller.pageCount = max(1, (body["pageCount"] as? NSNumber)?.intValue ?? parent.controller.pageCount)
                    parent.controller.pageIndex = max(0, (body["pageIndex"] as? NSNumber)?.intValue ?? parent.controller.pageIndex)
                case "tap":
                    let x = (body["x"] as? NSNumber)?.doubleValue ?? 0, y = (body["y"] as? NSNumber)?.doubleValue ?? 0
                    let w = (body["w"] as? NSNumber)?.doubleValue ?? 1, h = (body["h"] as? NSNumber)?.doubleValue ?? 1
                    parent.onTapAction(parent.document.preferences.tapZones.actionAt(x: x, y: y, width: w, height: h))
                case "selection":
                    let text = body["text"] as? String ?? ""
                    let rawStart = max(0, (body["offset"] as? NSNumber)?.intValue ?? 0)
                    let rawEnd = max(rawStart, (body["endOffset"] as? NSNumber)?.intValue ?? rawStart)
                    let mapped = parent.document.textMapping?.sourceRange(displayStart: rawStart, displayEnd: rawEnd)
                    let start = mapped?.location ?? rawStart
                    let value = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : ReaderSelection(
                        text: text,
                        approximateUTF16Offset: start,
                        canonicalStart: mapped?.location,
                        canonicalEnd: mapped.map { $0.location + $0.length }
                    )
                    parent.controller.selection = value; parent.onSelection(value)
                case "imageLongPress":
                    parent.onImageLongPress((body["src"] as? String).flatMap(URL.init(string:)))
                case "link":
                    if let raw = body["href"] as? String, let url = URL(string: raw) { parent.onLink(url) }
                case "boundary": parent.onBoundary((body["direction"] as? NSNumber)?.intValue ?? 0)
                case "quickBookmark": parent.onQuickBookmark()
                default: break
                }
            }
        }
    }

    private static func htmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func script(document d: ReaderWebDocument) -> String {
        let p = d.preferences
        let mapping = d.textMapping
        let annotationJSON: String = {
            let values = d.annotations.map { row -> [String: Any] in
                let start = mapping?.displayOffset(forSourceOffset: row.startCharOffset) ?? row.startCharOffset
                let end = mapping?.displayOffset(forSourceOffset: row.endCharOffset) ?? row.endCharOffset
                var item: [String: Any] = ["id": String(row.id), "start": start, "end": end, "quote": row.selectedText, "color": row.colorTag, "style": row.style]
                if mapping == nil, let source = d.plainText, !source.isEmpty {
                    let anchor = BookTextSearch.anchor(around: row.startCharOffset, in: source)
                    item["anchor"] = anchor.text
                    item["anchorApprox"] = max(0, row.startCharOffset - anchor.relative)
                    item["anchorRelative"] = anchor.relative
                    item["sourceLength"] = max(0, row.endCharOffset - row.startCharOffset)
                }
                return item
            }
            guard let data = try? JSONSerialization.data(withJSONObject: values), let s = String(data: data, encoding: .utf8) else { return "[]" }
            return s
        }()
        let initialOffset = mapping?.displayOffset(forSourceOffset: d.initialUTF16Offset) ?? d.initialUTF16Offset
        let custom = jsString(p.customCSS)
        let title = d.enhancements.titleStyle
        let titleImage: String = {
            guard let path = title.backgroundImagePath, let data = try? Data(contentsOf: URL(fileURLWithPath: path)), data.count <= 8 * 1024 * 1024 else { return "" }
            let ext = URL(fileURLWithPath: path).pathExtension.lowercased(); let mime = ext == "png" ? "image/png" : (ext == "webp" ? "image/webp" : "image/jpeg")
            return "data:\(mime);base64,\(data.base64EncodedString())"
        }()
        let titleCSS = title.enabled ? "#moread-title{font-family:\(title.fontFamily);font-size:\(title.fontSizeEm)em;color:\(title.colorHex.isEmpty ? p.theme.foregroundHex:title.colorHex);background-color:\(title.backgroundHex.isEmpty ? "transparent":title.backgroundHex);background-image:url('\(titleImage)');background-size:cover;background-position:center;text-align:\(title.alignment);margin:\(title.marginTopEm)em 0 \(title.marginBottomEm)em 0;padding:\(title.paddingEm)em;border:\(title.borderWidthEm)em solid \(title.borderColorHex.isEmpty ? "transparent":title.borderColorHex);border-radius:\(title.borderRadiusEm)em;font-weight:700;}" : "#moread-title{display:none;}"
        let syntaxValues = d.enhancements.syntaxRules.filter { $0.enabled && !$0.pattern.isEmpty }.prefix(32).map { ["id":$0.id,"pattern":$0.pattern,"ignoreCase":$0.ignoreCase,"color":$0.colorHex,"background":$0.backgroundHex,"bold":$0.bold,"italic":$0.italic,"underline":$0.underline] as [String:Any] }
        let syntaxJSON = (try? JSONSerialization.data(withJSONObject: syntaxValues)).flatMap { String(data:$0,encoding:.utf8) } ?? "[]"
        let backgroundImage: String = {
            guard let path=p.theme.backgroundImagePath,let data=try? Data(contentsOf:URL(fileURLWithPath:path)),data.count<=8*1024*1024 else{return ""}
            let ext=URL(fileURLWithPath:path).pathExtension.lowercased();let mime=ext=="png" ? "image/png":(ext=="webp" ? "image/webp":"image/jpeg")
            return "data:\(mime);base64,\(data.base64EncodedString())"
        }()
        let publisherCSS: String = {
            switch p.publisherStyleMode {
            case .original:
                return ":where(html,body){padding:0;margin:0;background:${cfg.bg};color:${cfg.fg};}:where(body){box-sizing:border-box;font-family:${cfg.font};font-size:${cfg.size}px;line-height:${cfg.line};padding:${cfg.vm}px ${cfg.hm}px;text-rendering:optimizeLegibility;-webkit-text-size-adjust:none;background-image:url('\(backgroundImage)');background-size:cover;background-position:center;background-attachment:fixed;}:where(#moread-text){white-space:pre-wrap;overflow-wrap:anywhere;}:where(p){margin-top:0;margin-bottom:${cfg.para}em;text-indent:${cfg.indent}em;}"
            case .smart:
                return "html,body{padding:0;margin:0;background:${cfg.bg};color:${cfg.fg};} body{box-sizing:border-box;font-family:${cfg.font};font-size:${cfg.size}px;line-height:${cfg.line};padding:${cfg.vm}px ${cfg.hm}px;text-rendering:optimizeLegibility;-webkit-text-size-adjust:none;background-image:url('\(backgroundImage)');background-size:cover;background-position:center;background-attachment:fixed;} #moread-text{white-space:pre-wrap;overflow-wrap:anywhere;} :where(p){margin-top:0;margin-bottom:${cfg.para}em;text-indent:${cfg.indent}em;}"
            case .takeover:
                return "html,body{padding:0!important;margin:0!important;background:${cfg.bg}!important;color:${cfg.fg}!important;} body{box-sizing:border-box!important;font-family:${cfg.font}!important;font-size:${cfg.size}px!important;line-height:${cfg.line}!important;padding:${cfg.vm}px ${cfg.hm}px!important;text-rendering:optimizeLegibility;-webkit-text-size-adjust:none;background-image:url('\(backgroundImage)')!important;background-size:cover!important;background-position:center!important;background-attachment:fixed!important;} #moread-text{white-space:pre-wrap!important;overflow-wrap:anywhere!important;} p{margin-top:0!important;margin-bottom:${cfg.para}em!important;text-indent:${cfg.indent}em!important;}"
            }
        }()
        return #"""
        (() => {
          const bridge = (o) => { try { window.webkit.messageHandlers.moread.postMessage(o); } catch (_) {} };
          const cfg = { paged: \#(p.layoutMode == .paged ? "true":"false"), vertical: \#(p.writingMode == .vertical ? "true":"false"), two: \#(p.twoPageSpread ? "true":"false"), anim: '\#(p.pageAnimation.rawValue)', publisher: '\#(p.publisherStyleMode.rawValue)', size: \#(p.fontSize), line: \#(p.lineHeight), para: \#(p.paragraphSpacing), indent: \#(p.paragraphIndentEM), hm: \#(p.horizontalMargin), vm: \#(p.verticalMargin), fg: '\#(p.theme.foregroundHex)', bg: '\#(p.theme.backgroundHex)', font: \#(jsString(p.fontFamily)), custom: \#(custom) };
          const style = document.createElement('style'); style.id='moread-style';
          style.textContent = `\#(publisherCSS) img,svg,video{max-width:100%;height:auto;} .moread-ui.moread-translation{display:block;white-space:pre-wrap;margin:.3em 0 ${cfg.para}em 0;padding:.3em .55em;border-left:2px solid color-mix(in srgb,${cfg.fg} 35%,transparent);opacity:.72;font-size:.88em;text-indent:0;} mark.moread-search{background:#ff9;color:inherit;} \#(titleCSS) ${cfg.custom}`.replace('\u0007','');
          document.head.appendChild(style);
          function applyLayout(){
            if(cfg.vertical){ document.documentElement.style.writingMode='vertical-rl'; document.body.style.writingMode='vertical-rl'; }
            if(cfg.paged){ document.documentElement.style.overflow='hidden'; document.body.style.height=`calc(100vh - ${cfg.vm*2}px)`; document.body.style.columnGap=`${cfg.hm*2}px`; document.body.style.columnWidth=cfg.two ? `calc((100vw - ${cfg.hm*4}px)/2)` : `calc(100vw - ${cfg.hm*2}px)`; document.body.style.overflow='visible'; }
            else { document.documentElement.style.overflow='auto'; document.body.style.minHeight='100vh'; }
          }
          applyLayout();
          const walkerNodes=()=>{const w=document.createTreeWalker(document.body,NodeFilter.SHOW_TEXT,{acceptNode:n=>n.parentElement && !n.parentElement.closest('.moread-ui') && !['SCRIPT','STYLE','NOSCRIPT'].includes(n.parentElement.tagName)?NodeFilter.FILTER_ACCEPT:NodeFilter.FILTER_REJECT});let a=[],n;while(n=w.nextNode())a.push(n);return a;};
          window.moReadSetBionic=(enabled)=>{for(const b of Array.from(document.querySelectorAll('b.moread-bionic'))){b.replaceWith(document.createTextNode(b.textContent||''));}document.body.normalize();if(!enabled)return;const nodes=walkerNodes().filter(n=>!n.parentElement.closest('b.moread-bionic'));const re=/[A-Za-z][A-Za-z'’-]{2,}/g;for(const node of nodes){const text=node.nodeValue||'';let matches=[],m;while((m=re.exec(text)))matches.push({i:m.index,w:m[0]});if(!matches.length)continue;const frag=document.createDocumentFragment();let cursor=0;for(const hit of matches){if(hit.i>cursor)frag.appendChild(document.createTextNode(text.slice(cursor,hit.i)));const cut=Math.max(1,Math.ceil(hit.w.length/2));const bold=document.createElement('b');bold.className='moread-bionic';bold.textContent=hit.w.slice(0,cut);frag.appendChild(bold);frag.appendChild(document.createTextNode(hit.w.slice(cut)));cursor=hit.i+hit.w.length;}if(cursor<text.length)frag.appendChild(document.createTextNode(text.slice(cursor)));node.replaceWith(frag);}};
          function offsetFor(node,local){let total=0;for(const n of walkerNodes()){if(n===node)return total+local;total+=n.nodeValue.length;}return total;}
          function pointForOffset(offset){let left=Math.max(0,offset);for(const n of walkerNodes()){if(left<=n.nodeValue.length)return [n,left];left-=n.nodeValue.length;}const a=walkerNodes();return a.length?[a[a.length-1],a[a.length-1].nodeValue.length]:[document.body,0];}
          function domText(){return walkerNodes().map(n=>n.nodeValue).join('');}
          function anchorOffset(needle,approx){const q=(needle||'').trim();if(!q)return Math.max(0,approx||0);const text=domText();let from=0,best=-1,bestDistance=Number.MAX_SAFE_INTEGER;while(from<=text.length-q.length){const hit=text.indexOf(q,from);if(hit<0)break;const distance=Math.abs(hit-Math.max(0,approx||0));if(distance<bestDistance){best=hit;bestDistance=distance;}from=hit+Math.max(1,q.length);}return best>=0?best:Math.max(0,approx||0);}
          function rangeForAnchor(needle,approxStart,approxEnd){const start=anchorOffset(needle,approxStart),length=Math.max(0,(needle||'').length),end=length?start+length:Math.max(start,approxEnd||start);const s=pointForOffset(start),e=pointForOffset(end),r=document.createRange();r.setStart(s[0],s[1]);r.setEnd(e[0],e[1]);return r;}
          function pointForSourceAnchor(anchor,approxBase,relative){const base=anchorOffset(anchor,Math.max(0,approxBase||0));return pointForOffset(Math.max(0,base+Math.max(0,relative||0)));}
          function rangeForSourceAnchor(anchor,approxBase,relative,length){const base=anchorOffset(anchor,Math.max(0,approxBase||0)),start=Math.max(0,base+Math.max(0,relative||0)),end=Math.max(start,start+Math.max(0,length||0));const s=pointForOffset(start),e=pointForOffset(end),r=document.createRange();r.setStart(s[0],s[1]);r.setEnd(e[0],e[1]);return r;}
          function applySyntaxRules(){if(!window.CSS||!CSS.highlights||typeof Highlight==='undefined')return;const rules=\#(syntaxJSON);const text=walkerNodes().map(n=>n.nodeValue).join('');let sheet=document.getElementById('moread-syntax-css');if(!sheet){sheet=document.createElement('style');sheet.id='moread-syntax-css';document.head.appendChild(sheet);}let css='';for(const rule of rules){try{const flags='gu'+(rule.ignoreCase?'i':'');const re=new RegExp(rule.pattern,flags);let ranges=[],m,count=0;while((m=re.exec(text))&&count<1000){if(!m[0].length){re.lastIndex++;continue;}const s=pointForOffset(m.index),e=pointForOffset(m.index+m[0].length),r=document.createRange();r.setStart(s[0],s[1]);r.setEnd(e[0],e[1]);ranges.push(r);count++;}if(ranges.length){const name='moread-syntax-'+rule.id.replace(/[^a-zA-Z0-9_-]/g,'');CSS.highlights.set(name,new Highlight(...ranges));let decl=`color:${rule.color};background:${rule.background};`;if(rule.bold)decl+='font-weight:700;';if(rule.italic)decl+='font-style:italic;';if(rule.underline)decl+='text-decoration:underline;';css+=`::highlight(${name}){${decl}}`;}}catch(_){}}sheet.textContent=css;}
          applySyntaxRules();
          function reportPosition(){let x=window.innerWidth/2,y=Math.max(8,Math.min(window.innerHeight-8,cfg.vm+8));let y2=Math.max(8,Math.min(window.innerHeight-8,window.innerHeight-cfg.vm-8));let r=document.caretRangeFromPoint?document.caretRangeFromPoint(x,y):null;let r2=document.caretRangeFromPoint?document.caretRangeFromPoint(x,y2):null;let off=r?offsetFor(r.startContainer,r.startOffset):0;let endOff=r2?offsetFor(r2.startContainer,r2.startOffset):off;if(endOff<off){let t=off;off=endOff;endOff=t;}let axis=cfg.vertical||cfg.paged?document.documentElement.scrollLeft||document.body.scrollLeft:document.documentElement.scrollTop||document.body.scrollTop;let extent=cfg.vertical||cfg.paged?Math.max(document.documentElement.scrollWidth,document.body.scrollWidth):Math.max(document.documentElement.scrollHeight,document.body.scrollHeight);let viewport=cfg.vertical||cfg.paged?window.innerWidth:window.innerHeight;let count=cfg.paged?Math.max(1,Math.ceil(extent/viewport)):1;let idx=cfg.paged?Math.max(0,Math.round(Math.abs(axis)/viewport)):0;let anchor=r&&r.startContainer&&r.startContainer.nodeType===Node.TEXT_NODE?r.startContainer.nodeValue.substring(Math.max(0,r.startOffset-12),Math.min(r.startContainer.nodeValue.length,r.startOffset+36)):'';bridge({type:'position',offset:off,endOffset:endOff,anchor:anchor,pageCount:count,pageIndex:idx});}
          let posTimer=null;window.addEventListener('scroll',()=>{clearTimeout(posTimer);posTimer=setTimeout(reportPosition,60)},{passive:true});
          document.addEventListener('click',e=>{const a=e.target&&e.target.closest?e.target.closest('a[href]'):null;if(a){e.preventDefault();e.stopPropagation();bridge({type:'link',href:a.href||a.getAttribute('href')||''});return;}if(window.getSelection().toString().trim())return;bridge({type:'tap',x:e.clientX,y:e.clientY,w:window.innerWidth,h:window.innerHeight});});
          let selTimer=null;document.addEventListener('selectionchange',()=>{clearTimeout(selTimer);selTimer=setTimeout(()=>{const s=window.getSelection();if(!s||s.rangeCount===0||s.isCollapsed){bridge({type:'selection',text:'',offset:0,endOffset:0});return;}const r=s.getRangeAt(0);bridge({type:'selection',text:s.toString(),offset:offsetFor(r.startContainer,r.startOffset),endOffset:offsetFor(r.endContainer,r.endOffset)});},100);});
          let pressTimer=null,pullStart=null,pullArmed=false;document.addEventListener('touchstart',e=>{const img=e.target.closest&&e.target.closest('img');if(img)pressTimer=setTimeout(()=>bridge({type:'imageLongPress',src:img.src}),550);if(cfg.paged&&e.touches.length===1){pullStart=e.touches[0].clientY;pullArmed=false;}},{passive:true});document.addEventListener('touchmove',e=>{clearTimeout(pressTimer);if(cfg.paged&&pullStart!=null&&e.touches.length===1&&e.touches[0].clientY-pullStart>76)pullArmed=true;},{passive:true});document.addEventListener('touchend',()=>{clearTimeout(pressTimer);if(pullArmed)bridge({type:'quickBookmark'});pullStart=null;pullArmed=false;},{passive:true});
          function axisState(){const horizontal=cfg.vertical||cfg.paged;const pos=horizontal?Math.abs(document.documentElement.scrollLeft||document.body.scrollLeft):(document.documentElement.scrollTop||document.body.scrollTop);const extent=horizontal?Math.max(document.documentElement.scrollWidth,document.body.scrollWidth):Math.max(document.documentElement.scrollHeight,document.body.scrollHeight);const viewport=horizontal?window.innerWidth:window.innerHeight;return {pos,extent,viewport};}
          let turning=false;
          function oldPageOverlay(){
            const previous=document.getElementById('moread-turn-layer');if(previous)previous.remove();
            const layer=document.createElement('div');layer.id='moread-turn-layer';layer.className='moread-ui';layer.style.cssText='position:fixed;inset:0;overflow:hidden;z-index:2147483000;pointer-events:none;transform-style:preserve-3d;perspective:1400px;background:'+getComputedStyle(document.body).backgroundColor+';';
            const clone=document.body.cloneNode(true);clone.querySelectorAll('#moread-turn-layer,script,.moread-ui').forEach(n=>n.remove());
            const rect=document.body.getBoundingClientRect();clone.style.position='absolute';clone.style.left='0';clone.style.top='0';clone.style.width=Math.max(document.body.scrollWidth,window.innerWidth)+'px';clone.style.minHeight=Math.max(document.body.scrollHeight,window.innerHeight)+'px';clone.style.margin='0';clone.style.pointerEvents='none';clone.style.transform=`translate(${rect.left}px,${rect.top}px)`;clone.style.transformOrigin='0 0';
            layer.appendChild(clone);document.documentElement.appendChild(layer);return {layer,clone};
          }
          function pageMotion(direction){
            if(turning)return;turning=true;
            const distance=window.innerWidth*(cfg.two?2:1),dx=cfg.vertical?-direction*distance:direction*distance,dy=cfg.vertical?0:(cfg.paged?0:direction*window.innerHeight*.85);
            if(!cfg.paged){window.scrollBy({left:dx,top:dy,behavior:cfg.anim==='none'?'auto':'smooth'});turning=false;setTimeout(reportPosition,360);return;}
            if(cfg.anim==='none'){window.scrollBy({left:dx,top:dy,behavior:'auto'});turning=false;setTimeout(reportPosition,40);return;}
            const shot=oldPageOverlay();
            // Move the real document first; the fixed overlay keeps the old page visible while it leaves.
            window.scrollBy({left:dx,top:dy,behavior:'auto'});
            const finish=()=>{shot.layer.remove();turning=false;reportPosition();};
            if(cfg.anim==='slide'){
              const sign=direction>0?-1:1;
              const oldAnim=shot.layer.animate([{transform:'translateX(0)'},{transform:`translateX(${sign*100}vw)`}],{duration:310,easing:'cubic-bezier(.2,.75,.25,1)',fill:'forwards'});
              const newAnim=document.body.animate([{transform:`translateX(${-sign*100}vw)`},{transform:'translateX(0)'}],{duration:310,easing:'cubic-bezier(.2,.75,.25,1)'});
              Promise.allSettled([oldAnim.finished,newAnim.finished]).then(finish);return;
            }
            if(cfg.anim==='cover'){
              const sign=direction>0?1:-1;
              shot.layer.style.zIndex='2147482999';
              const anim=document.body.animate([{transform:`translateX(${sign*100}vw)`,boxShadow:`${-sign*18}px 0 34px rgba(0,0,0,.26)`},{transform:'translateX(0)',boxShadow:'0 0 0 rgba(0,0,0,0)'}],{duration:330,easing:'cubic-bezier(.22,.72,.2,1)'});
              anim.finished.then(finish).catch(finish);return;
            }
            if(cfg.anim==='classicCurl'){
              const forward=direction>0,origin=forward?'left center':'right center',angle=forward?-88:88;
              shot.clone.style.transformOrigin=origin;shot.clone.style.backfaceVisibility='hidden';shot.clone.style.boxShadow=forward?'12px 0 26px rgba(0,0,0,.28)':'-12px 0 26px rgba(0,0,0,.28)';
              const anim=shot.clone.animate([
                {transform:`${shot.clone.style.transform} rotateY(0deg)`,filter:'brightness(1)'},
                {offset:.55,transform:`${shot.clone.style.transform} rotateY(${angle*.55}deg)`,filter:'brightness(.9)'},
                {transform:`${shot.clone.style.transform} rotateY(${angle}deg)`,filter:'brightness(.72)'}
              ],{duration:470,easing:'cubic-bezier(.18,.68,.2,1)',fill:'forwards'});
              anim.finished.then(finish).catch(finish);return;
            }
            // Modern curl: diagonal fold, rounded paper edge and a moving back-side highlight.
            const forward=direction>0,origin=forward?'left bottom':'right bottom',angle=forward?-74:74,skew=forward?-5:5;
            shot.clone.style.transformOrigin=origin;shot.clone.style.backfaceVisibility='hidden';shot.clone.style.borderRadius=forward?'0 22px 22px 0':'22px 0 0 22px';shot.clone.style.boxShadow=forward?'18px -4px 38px rgba(0,0,0,.32)':'-18px -4px 38px rgba(0,0,0,.32)';
            const sheen=document.createElement('div');sheen.style.cssText=`position:absolute;inset:0;pointer-events:none;background:linear-gradient(${forward?115:65}deg,transparent 55%,rgba(255,255,255,.28) 72%,rgba(0,0,0,.13) 100%);mix-blend-mode:soft-light;`;shot.layer.appendChild(sheen);
            const paper=shot.clone.animate([
              {transform:`${shot.clone.style.transform} perspective(1500px) rotateY(0deg) skewY(0deg)`,clipPath:'polygon(0 0,100% 0,100% 100%,0 100%)',filter:'brightness(1)'},
              {offset:.58,transform:`${shot.clone.style.transform} perspective(1500px) rotateY(${angle*.48}deg) skewY(${skew*.55}deg)`,clipPath:forward?'polygon(0 0,93% 3%,86% 96%,0 100%)':'polygon(7% 3%,100% 0,100% 100%,14% 96%)',filter:'brightness(.96)'},
              {transform:`${shot.clone.style.transform} perspective(1500px) rotateY(${angle}deg) skewY(${skew}deg)`,clipPath:forward?'polygon(0 0,72% 8%,58% 91%,0 100%)':'polygon(28% 8%,100% 0,100% 100%,42% 91%)',filter:'brightness(.78)'}
            ],{duration:390,easing:'cubic-bezier(.16,.72,.2,1)',fill:'forwards'});
            const light=sheen.animate([{opacity:.15,transform:'translateX(0)'},{opacity:.85,transform:`translateX(${forward?-16:16}px)`},{opacity:0}],{duration:390,easing:'ease-out'});
            Promise.allSettled([paper.finished,light.finished]).then(finish);
          }
          window.moReadNextPage=()=>{const a=axisState();if(a.pos+a.viewport>=a.extent-3){bridge({type:'boundary',direction:1});return;}pageMotion(1);};
          window.moReadPreviousPage=()=>{const a=axisState();if(a.pos<=3){bridge({type:'boundary',direction:-1});return;}pageMotion(-1);};
          window.moReadScrollToOffset=(offset)=>{const [n,o]=pointForOffset(offset);const r=document.createRange();r.setStart(n,o);r.collapse(true);const rect=r.getBoundingClientRect();window.scrollBy({left:rect.left-window.innerWidth/2,top:rect.top-window.innerHeight/4,behavior:'auto'});setTimeout(reportPosition,80);};
          window.moReadScrollToFragment=(fragment)=>{try{const id=(fragment||'').replace(/^#/,'');let el=document.getElementById(id);if(!el){for(const node of document.getElementsByName(id)){el=node;break;}}if(!el)return false;el.scrollIntoView({block:'start',inline:'start',behavior:'auto'});setTimeout(reportPosition,40);return true;}catch(_){return false;}};
          window.moReadScrollToAnchor=(anchor,approx,relative)=>{const base=anchorOffset(anchor,approx);const target=Math.max(0,base+Math.max(0,relative||0));window.moReadScrollToOffset(target);};
          let autoId=null,autoTimer=null,last=0;window.moReadSetAutoRead=(active,mode,speed,interval)=>{if(autoId){cancelAnimationFrame(autoId);autoId=null;}if(autoTimer){clearInterval(autoTimer);autoTimer=null;}if(!active)return;if(mode==='PAGE'){autoTimer=setInterval(()=>window.moReadNextPage(),Math.max(3,interval)*1000);return;}last=performance.now();const tick=t=>{let dt=(t-last)/1000;last=t;if(cfg.vertical)window.scrollBy(-speed*dt,0);else window.scrollBy(0,speed*dt);const a=axisState();if(a.pos+a.viewport>=a.extent-2){cancelAnimationFrame(autoId);autoId=null;bridge({type:'boundary',direction:1});return;}autoId=requestAnimationFrame(tick);};autoId=requestAnimationFrame(tick);};
          window.moReadSpeechHighlight=(start,end)=>{if(!window.CSS||!CSS.highlights||typeof Highlight==='undefined')return;CSS.highlights.delete('moread-speech');if(start<0||end<=start)return;try{const s=pointForOffset(start),e=pointForOffset(end),r=document.createRange();r.setStart(s[0],s[1]);r.setEnd(e[0],e[1]);CSS.highlights.set('moread-speech',new Highlight(r));let sheet=document.getElementById('moread-speech-css');if(!sheet){sheet=document.createElement('style');sheet.id='moread-speech-css';document.head.appendChild(sheet);}sheet.textContent='::highlight(moread-speech){background:rgba(100,180,255,.28);text-decoration:underline;text-decoration-thickness:2px;}';}catch(_){}};
          window.moReadSpeechHighlightSource=(anchor,approxBase,relative,length)=>{if(!window.CSS||!CSS.highlights||typeof Highlight==='undefined')return;CSS.highlights.delete('moread-speech');if(!anchor||length<=0)return;try{const r=rangeForSourceAnchor(anchor,approxBase,relative,length);CSS.highlights.set('moread-speech',new Highlight(r));let sheet=document.getElementById('moread-speech-css');if(!sheet){sheet=document.createElement('style');sheet.id='moread-speech-css';document.head.appendChild(sheet);}sheet.textContent='::highlight(moread-speech){background:rgba(100,180,255,.28);text-decoration:underline;text-decoration-thickness:2px;}';}catch(_){}};
          window.moReadClearSearch=()=>document.querySelectorAll('mark.moread-search').forEach(m=>m.replaceWith(document.createTextNode(m.textContent)));
          window.moReadSearch=(q)=>{window.moReadClearSearch();if(!q)return 0;let count=0;for(const n of walkerNodes()){let text=n.nodeValue,idx=text.toLowerCase().indexOf(q.toLowerCase());if(idx>=0){const r=document.createRange();r.setStart(n,idx);r.setEnd(n,idx+q.length);const m=document.createElement('mark');m.className='moread-search';r.surroundContents(m);count++;}}return count;};
          window.moReadApplyAnnotations=(items)=>{if(!window.CSS||!CSS.highlights||typeof Highlight==='undefined')return;for(const name of Array.from(CSS.highlights.keys())){if(name.startsWith('moread-ann-'))CSS.highlights.delete(name);}let sheet=document.getElementById('moread-ann-css');if(!sheet){sheet=document.createElement('style');sheet.id='moread-ann-css';document.head.appendChild(sheet);}let css='';for(const item of items){try{const r=item.anchor?rangeForSourceAnchor(item.anchor,item.anchorApprox,item.anchorRelative,item.sourceLength):(item.quote?rangeForAnchor(item.quote,Math.max(0,item.start||0),Math.max(0,item.end||0)):(()=>{const s=pointForOffset(Math.max(0,item.start||0)),e=pointForOffset(Math.max(0,item.end||0)),x=document.createRange();x.setStart(s[0],s[1]);x.setEnd(e[0],e[1]);return x;})());const name='moread-ann-'+item.id;CSS.highlights.set(name,new Highlight(r));let c='rgba(255,220,80,.45)';if(item.color==='blue')c='rgba(90,170,255,.35)';else if(item.color==='green')c='rgba(80,210,130,.33)';else if(item.color==='pink')c='rgba(255,120,180,.32)';let rule=`background:${c};`;if(item.style==='WAVY')rule+=`text-decoration:underline wavy ${c};`;else if(item.style==='UNDERLINE')rule+=`text-decoration:underline 2px ${c};`;css+=`::highlight(${name}){${rule}}`;}catch(_){}}sheet.textContent=css;};
          window.moReadApplyTranslations=(items,visible)=>{document.querySelectorAll('.moread-translation').forEach(n=>n.remove());if(!visible)return;for(const item of items){try{const p=item.anchor?pointForSourceAnchor(item.anchor,item.anchorApprox,item.anchorRelative):pointForOffset(Math.max(0,item.end||0)),r=document.createRange();r.setStart(p[0],p[1]);r.collapse(true);const span=document.createElement('span');span.className='moread-ui moread-translation';span.textContent=item.text||'';r.insertNode(span);}catch(_){}}};
          window.moReadApplyWordGlosses=(items,visible)=>{document.querySelectorAll('.moread-word-gloss').forEach(n=>n.remove());if(!visible)return;for(const item of items){try{const r=item.anchor?rangeForSourceAnchor(item.anchor,item.anchorApprox,item.anchorRelative,item.sourceLength):(()=>{const s=pointForOffset(Math.max(0,item.start||0)),e=pointForOffset(Math.max(0,item.end||0)),x=document.createRange();x.setStart(s[0],s[1]);x.setEnd(e[0],e[1]);return x;})();const rect=r.getBoundingClientRect();if(!rect||(!rect.width&&!rect.height))continue;const span=document.createElement('span');span.className='moread-ui moread-word-gloss';const line=[item.phonetic||'',item.gloss||''].filter(Boolean).join(' · ');if(!line)continue;span.textContent=line;span.style.cssText=`position:absolute;z-index:20;pointer-events:none;left:${rect.left+window.scrollX}px;top:${rect.bottom+window.scrollY+1}px;max-width:${Math.max(70,Math.min(220,rect.width*2.2))}px;font-size:10px;line-height:1.15;color:${getComputedStyle(document.body).color};opacity:.72;background:color-mix(in srgb, ${getComputedStyle(document.body).backgroundColor} 72%, transparent);padding:1px 3px;border-radius:4px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;`;document.body.appendChild(span);}catch(_){}}};
          window.moReadApplyAnnotations(\#(annotationJSON));
          window.addEventListener('load',()=>setTimeout(()=>{if(\#(jsString(d.initialAnchorText)).trim())window.moReadScrollToAnchor(\#(jsString(d.initialAnchorText)),\#(max(0,initialOffset-d.initialAnchorRelativeOffset)),\#(max(0,d.initialAnchorRelativeOffset)));else window.moReadScrollToOffset(\#(max(0,initialOffset)));reportPosition();bridge({type:'ready',pageCount:1,pageIndex:0});},80));
          setTimeout(()=>{if(\#(jsString(d.initialAnchorText)).trim())window.moReadScrollToAnchor(\#(jsString(d.initialAnchorText)),\#(max(0,initialOffset-d.initialAnchorRelativeOffset)),\#(max(0,d.initialAnchorRelativeOffset)));else window.moReadScrollToOffset(\#(max(0,initialOffset)));reportPosition();bridge({type:'ready',pageCount:1,pageIndex:0});},120);
        })();
        """#
    }
    private static func jsString(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [value]), let json = String(data: data, encoding: .utf8) else { return "\"\"" }
        return String(json.dropFirst().dropLast())
    }
}
