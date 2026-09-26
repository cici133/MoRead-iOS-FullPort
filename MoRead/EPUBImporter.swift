import Foundation
import ZIPFoundation

struct EPUBImporter {
    enum EPUBError: LocalizedError {
        case missingContainer, missingOPF, invalidPackage, noReadableSpine
        var errorDescription: String? {
            switch self {
            case .missingContainer: return "EPUB 缺少 META-INF/container.xml"
            case .missingOPF: return "EPUB container.xml 缺少 OPF 包文档"
            case .invalidPackage: return "EPUB 包文档无效"
            case .noReadableSpine: return "EPUB 没有可读取的 spine 正文"
            }
        }
    }

    static func importEPUB(url: URL) throws -> ImportedBook {
        guard let archive = Archive(url: url, accessMode: .read) else { throw EPUBError.invalidPackage }
        guard let containerData = try data("META-INF/container.xml", archive: archive) else { throw EPUBError.missingContainer }
        guard let packagePath = ContainerParser.parse(containerData) else { throw EPUBError.missingOPF }
        guard let packageData = try data(packagePath, archive: archive) else { throw EPUBError.missingOPF }
        let package = PackageParser.parse(packageData)
        guard !package.spine.isEmpty else { throw EPUBError.invalidPackage }

        let packageDir = packagePath.deletingLastPathComponent
        var readingOrder: [(href: String, title: String?, text: String)] = []
        for idref in package.spine {
            guard let manifest = package.manifest[idref] else { continue }
            let href = normalizedResourcePath(manifest.href, relativeTo: packageDir)
            guard let chapterData = try data(href, archive: archive) else { continue }
            let extracted = XHTMLTextExtractor.extract(chapterData, fallbackTitle: nil)
            guard !extracted.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            readingOrder.append((href, extracted.documentTitle, extracted.text))
        }
        guard !readingOrder.isEmpty else { throw EPUBError.noReadableSpine }

        let navigation = try loadNavigation(package: package, packageDir: packageDir, archive: archive)
        let structure = buildStructure(readingOrder: readingOrder, navigation: navigation)
        let title = package.title.nonEmpty ?? url.deletingPathExtension().lastPathComponent
        let coverItem = package.coverID.flatMap { package.manifest[$0] }
            ?? package.manifest.values.first(where: { $0.properties.split(separator: " ").contains("cover-image") })
            ?? package.manifest.values.first(where: { $0.id.lowercased().contains("cover") && $0.mediaType.hasPrefix("image/") })
        let coverData: Data? = try coverItem.flatMap { try data(normalizedResourcePath($0.href, relativeTo: packageDir), archive: archive) }
        let coverExtension: String? = coverItem.map { item in
            let ext = (item.href as NSString).pathExtension.lowercased()
            if !ext.isEmpty { return ext }
            switch item.mediaType { case "image/png": return "png"; case "image/webp": return "webp"; default: return "jpg" }
        }
        return ImportedBook(
            title: title,
            author: package.author,
            sourceType: "EPUB",
            sourceURL: url,
            chapters: structure.chapters,
            toc: structure.toc,
            coverData: coverData,
            coverFileExtension: coverExtension
        )
    }

    // MARK: Archive

    private static func data(_ path: String, archive: Archive) throws -> Data? {
        let normalized = path.removingPercentEncoding ?? path
        let candidates = [normalized, normalized.replacingOccurrences(of: "%20", with: " ")]
        guard let entry = candidates.compactMap({ archive[$0] }).first else { return nil }
        var result = Data()
        _ = try archive.extract(entry, consumer: { result.append($0) })
        return result
    }

    fileprivate static func normalizedResourcePath(_ href: String, relativeTo directory: String) -> String {
        let clean = href.substringBefore("#").substringBefore("?").replacingOccurrences(of: "\\", with: "/")
        let combined = clean.hasPrefix("/") ? String(clean.dropFirst()) : (directory.isEmpty ? clean : "\(directory)/\(clean)")
        var parts: [Substring] = []
        for part in combined.split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." { continue }
            if part == ".." { if !parts.isEmpty { parts.removeLast() }; continue }
            parts.append(part)
        }
        return parts.joined(separator: "/").removingPercentEncoding ?? parts.joined(separator: "/")
    }

    // MARK: Navigation

    private static func loadNavigation(package: PackageParser.Result, packageDir: String, archive: Archive) throws -> [NavigationNode] {
        if let nav = package.manifest.values.first(where: { $0.properties.split(separator: " ").contains("nav") }) {
            let path = normalizedResourcePath(nav.href, relativeTo: packageDir)
            if let d = try data(path, archive: archive) { return NavigationParser.parseEPUB3(d, basePath: path) }
        }
        if let ncxID = package.spineTOC, let ncx = package.manifest[ncxID] {
            let path = normalizedResourcePath(ncx.href, relativeTo: packageDir)
            if let d = try data(path, archive: archive) { return NavigationParser.parseNCX(d, basePath: path) }
        }
        if let ncx = package.manifest.values.first(where: { $0.mediaType == "application/x-dtbncx+xml" }) {
            let path = normalizedResourcePath(ncx.href, relativeTo: packageDir)
            if let d = try data(path, archive: archive) { return NavigationParser.parseNCX(d, basePath: path) }
        }
        return []
    }

    private struct BuiltStructure { var chapters: [ImportedChapter]; var toc: [ImportedTOCEntry] }
    private static func buildStructure(readingOrder: [(href: String, title: String?, text: String)], navigation: [NavigationNode]) -> BuiltStructure {
        let flat = flatten(navigation)
        let chapterByHref = Dictionary(uniqueKeysWithValues: readingOrder.enumerated().map { (normalizeHref($0.element.href), $0.offset) })
        let tocByHref = Dictionary(grouping: flat.filter { !$0.normalizedHref.isEmpty }, by: \.normalizedHref)
        let titleCounts = Dictionary(grouping: readingOrder.compactMap { meaningfulTitle($0.title) }, by: { $0 }).mapValues(\.count)
        var inherited: String?
        var chapters: [ImportedChapter] = []
        for (index, item) in readingOrder.enumerated() {
            let tocTitle = tocByHref[normalizeHref(item.href)]?.filter { !$0.title.isEmpty }.max {
                if $0.depth != $1.depth { return $0.depth < $1.depth }
                if $0.hasChildren != $1.hasChildren { return $0.hasChildren && !$1.hasChildren }
                return $0.orderIndex < $1.orderIndex
            }?.title
            let doc = meaningfulTitle(item.title).flatMap { (titleCounts[$0] ?? 0) <= 2 ? $0 : nil }
            let title = tocTitle ?? contentsPageTitle(item.text) ?? doc ?? structuralTitle(item.href) ?? (flat.isEmpty ? nil : inherited) ?? (flat.isEmpty ? "第 \(index + 1) 章" : "卷首")
            if let tocTitle { inherited = tocTitle }
            chapters.append(.init(title: title, href: item.href, text: item.text))
        }
        let toc: [ImportedTOCEntry]
        if flat.isEmpty {
            toc = chapters.enumerated().map { .init(orderIndex: $0.offset, title: $0.element.title, href: $0.element.href, depth: 0, parentOrderIndex: nil, chapterIndex: $0.offset, hasChildren: false) }
        } else {
            toc = flat.map { node in
                .init(orderIndex: node.orderIndex, title: node.title.isEmpty ? (chapterByHref[node.normalizedHref].map { chapters[$0].title } ?? "未命名目录") : node.title, href: node.href, depth: node.depth, parentOrderIndex: node.parentOrderIndex, chapterIndex: chapterByHref[node.normalizedHref], hasChildren: node.hasChildren)
            }
        }
        return .init(chapters: chapters, toc: toc)
    }

    private struct FlatNode { var orderIndex:Int; var title:String; var href:String; var normalizedHref:String; var depth:Int; var parentOrderIndex:Int?; var hasChildren:Bool }
    private static func flatten(_ roots: [NavigationNode]) -> [FlatNode] {
        var result: [FlatNode] = []
        func append(_ nodes: [NavigationNode], depth: Int, parent: Int?) {
            for n in nodes {
                let index = result.count
                result.append(.init(orderIndex:index,title:n.title.trimmingCharacters(in:.whitespacesAndNewlines),href:n.href,normalizedHref:normalizeHref(n.href),depth:depth,parentOrderIndex:parent,hasChildren:!n.children.isEmpty))
                append(n.children, depth: depth + 1, parent: index)
            }
        }
        append(roots, depth: 0, parent: nil)
        return result
    }

    private static func normalizeHref(_ value: String) -> String { value.substringBefore("#").replacingOccurrences(of:"\\",with:"/").replacingOccurrences(of:"./",with:"") }
    private static func meaningfulTitle(_ value: String?) -> String? {
        guard let t=value?.trimmingCharacters(in:.whitespacesAndNewlines),!t.isEmpty,!Set(["未知","unknown","untitled","无标题"]).contains(t.lowercased()) else{return nil};return t
    }
    private static func contentsPageTitle(_ text:String)->String?{let t=text.trimmingCharacters(in:.whitespacesAndNewlines).replacingOccurrences(of:#"\s+"#,with:" ",options:.regularExpression);return t.range(of:#"^(?:未知\s*)?目录(?:\s|$)"#,options:[.regularExpression,.caseInsensitive]) != nil ? "目录":nil}
    private static func structuralTitle(_ href:String)->String?{let n=normalizeHref(href).split(separator:"/").last.map(String.init)?.split(separator:".").dropLast().joined(separator:".").lowercased() ?? "";if n.contains("cover"){return "封面"};if n.contains("title"){return "扉页"};if n.contains("copyright")||n.contains("colophon"){return "版权页"};if n=="toc"||n.hasPrefix("toc_")||n.hasPrefix("toc-")||n.contains("contents")||n.contains("navigation")||n=="nav"{return "目录"};return nil}
}

private extension String {
    var nonEmpty: String? { let t=trimmingCharacters(in:.whitespacesAndNewlines); return t.isEmpty ? nil:t }
    var deletingLastPathComponent: String { (self as NSString).deletingLastPathComponent }
    func substringBefore(_ marker: Character) -> String { split(separator: marker, maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? self }
    func substringBefore(_ marker: String) -> String { components(separatedBy: marker).first ?? self }
}

// MARK: - container.xml
private final class ContainerParser: NSObject, XMLParserDelegate {
    private var path: String?
    static func parse(_ data:Data)->String?{let d=ContainerParser();let p=XMLParser(data:data);p.delegate=d;p.shouldProcessNamespaces=true;return p.parse() ? d.path:nil}
    func parser(_ parser:XMLParser,didStartElement elementName:String,namespaceURI:String?,qualifiedName qName:String?,attributes:[String:String]){if elementName.lowercased().hasSuffix("rootfile"),path==nil{path=attributes["full-path"]}}
}

// MARK: - OPF
private final class PackageParser: NSObject, XMLParserDelegate {
    struct ManifestItem { var id:String;var href:String;var mediaType:String;var properties:String }
    struct Result { var title="";var author="";var manifest:[String:ManifestItem]=[:];var spine:[String]=[];var spineTOC:String?;var coverID:String? }
    private var result=Result();private var text="";private var capture:String?
    static func parse(_ data:Data)->Result{let d=PackageParser();let p=XMLParser(data:data);p.delegate=d;p.shouldProcessNamespaces=true;_ = p.parse();return d.result}
    func parser(_ parser:XMLParser,didStartElement elementName:String,namespaceURI:String?,qualifiedName qName:String?,attributes:[String:String]){
        let e=elementName.lowercased();if e.hasSuffix("title"){capture="title";text=""}else if e.hasSuffix("creator"){capture="creator";text=""}
        else if e.hasSuffix("item"),let id=attributes["id"],let href=attributes["href"]{result.manifest[id] = .init(id:id,href:href,mediaType:attributes["media-type"]?.lowercased() ?? "",properties:attributes["properties"] ?? "")}
        else if e.hasSuffix("meta"), attributes["name"]?.lowercased() == "cover", let id = attributes["content"] { result.coverID = id }
        else if e.hasSuffix("spine"){result.spineTOC = attributes["toc"]}
        else if e.hasSuffix("itemref"),let id=attributes["idref"]{result.spine.append(id)}
    }
    func parser(_ parser:XMLParser,foundCharacters string:String){if capture != nil{text += string}}
    func parser(_ parser:XMLParser,didEndElement elementName:String,namespaceURI:String?,qualifiedName qName:String?){let e=elementName.lowercased();if capture=="title",e.hasSuffix("title"),result.title.isEmpty{result.title=text.trimmingCharacters(in:.whitespacesAndNewlines);capture=nil};if capture=="creator",e.hasSuffix("creator"),result.author.isEmpty{result.author=text.trimmingCharacters(in:.whitespacesAndNewlines);capture=nil}}
}

// MARK: - XHTML -> canonical text.mz text
private enum XHTMLTextExtractor {
    struct Result { var text:String;var documentTitle:String? }
    static func extract(_ data:Data,fallbackTitle:String?)->Result{
        let delegate=XHTMLDelegate();let p=XMLParser(data:data);p.delegate=delegate;p.shouldProcessNamespaces=true;p.shouldResolveExternalEntities=false
        if p.parse(){return .init(text:delegate.finish(),documentTitle:delegate.title.nonEmpty ?? fallbackTitle)}
        let raw=String(data:data,encoding:.utf8) ?? String(decoding:data,as:UTF8.self)
        return .init(text:legacyFallback(raw),documentTitle:fallbackTitle)
    }
    private static func legacyFallback(_ html:String)->String{
        var s=html.replacingOccurrences(of:#"(?is)<(script|style|title|rt|rp)[^>]*>.*?</\1>"#,with:"",options:.regularExpression)
        s=s.replacingOccurrences(of:#"(?is)<(?:img|image|object)\b[^>]*>"#,with:"\n［图片］\n",options:.regularExpression)
        s=s.replacingOccurrences(of:#"(?i)<br\s*/?>"#,with:"\n",options:.regularExpression)
        s=s.replacingOccurrences(of:#"(?i)</(?:p|div|section|article|blockquote|li|tr|td|th|h[1-6]|pre|figcaption|dd|dt)>"#,with:"\n",options:.regularExpression)
        s=s.replacingOccurrences(of:#"<[^>]+>"#,with:"",options:.regularExpression)
        for (k,v) in ["&nbsp;":" ","&amp;":"&","&lt;":"<","&gt;":">","&quot;":"\"","&#39;":"'"]{s=s.replacingOccurrences(of:k,with:v)}
        return normalizeBlocks(s)
    }
    fileprivate static func normalizeBlocks(_ s:String)->String{s.components(separatedBy:.newlines).map(collapse).filter{!$0.isEmpty}.joined(separator:"\n")}
    fileprivate static func collapse(_ s:String)->String{var out="",pending=false;for ch in s{if ch.isWhitespace{if !out.isEmpty{pending=true}}else{if pending{out.append(" ");pending=false};out.append(ch)}};return out}
    fileprivate static let blockTags: Set<String> = ["p","div","section","article","blockquote","li","tr","td","th","h1","h2","h3","h4","h5","h6","pre","figcaption","dd","dt"]
}
private final class XHTMLDelegate:NSObject,XMLParserDelegate{
    var blocks:[String]=[];var current="";var droppedDepth=0;var title="";private var titleDepth=0
    func parser(_ parser:XMLParser,didStartElement elementName:String,namespaceURI:String?,qualifiedName qName:String?,attributes:[String:String]){let e=elementName.lowercased();if e=="title"{titleDepth += 1;return};if ["script","style","rt","rp"].contains(e)||((attributes["style"] ?? "").replacingOccurrences(of:" ",with:"").lowercased().contains("display:none")){droppedDepth += 1;return};if droppedDepth>0{return};if e=="br"{flush()};if ["img","image","object"].contains(e){flush();blocks.append("［图片］")}}
    func parser(_ parser:XMLParser,foundCharacters string:String){if titleDepth>0{title += string;return};if droppedDepth==0{current += string}}
    func parser(_ parser:XMLParser,didEndElement elementName:String,namespaceURI:String?,qualifiedName qName:String?){let e=elementName.lowercased();if e=="title"{titleDepth=max(0,titleDepth-1);return};if droppedDepth>0{if ["script","style","rt","rp"].contains(e){droppedDepth=max(0,droppedDepth-1)};return};if XHTMLTextExtractor.blockTags.contains(e){flush()}}
    func finish()->String{flush();return blocks.joined(separator:"\n")}
    private func flush(){let t=XHTMLTextExtractor.collapse(current);if !t.isEmpty{blocks.append(t)};current=""}
}

// MARK: - Navigation
private struct NavigationNode { var title:String;var href:String;var children:[NavigationNode] }
private enum NavigationParser {
    static func parseNCX(_ data:Data,basePath:String)->[NavigationNode]{let d=NCXDelegate(basePath:basePath);let p=XMLParser(data:data);p.delegate=d;p.shouldProcessNamespaces=true;_ = p.parse();return d.roots}
    static func parseEPUB3(_ data:Data,basePath:String)->[NavigationNode]{let d=NavDelegate(basePath:basePath);let p=XMLParser(data:data);p.delegate=d;p.shouldProcessNamespaces=true;_ = p.parse();return d.roots}
    static func resolve(_ href:String,basePath:String)->String{let dir=(basePath as NSString).deletingLastPathComponent;return EPUBImporter.normalizedResourcePath(href,relativeTo:dir)}
}
private final class NCXDelegate:NSObject,XMLParserDelegate{
    var roots:[NavigationNode]=[];private var stack:[NavigationNode]=[];private var text="";private var inLabel=false;private let basePath:String
    init(basePath:String){self.basePath=basePath}
    func parser(_ parser:XMLParser,didStartElement e:String,namespaceURI:String?,qualifiedName:String?,attributes:[String:String]){let n=e.lowercased();if n.hasSuffix("navpoint"){stack.append(.init(title:"",href:"",children:[]))};if n.hasSuffix("text"){inLabel=true;text=""};if n.hasSuffix("content"),let src=attributes["src"],!stack.isEmpty{stack[stack.count-1].href=NavigationParser.resolve(src,basePath:basePath)}}
    func parser(_ parser:XMLParser,foundCharacters s:String){if inLabel{text += s}}
    func parser(_ parser:XMLParser,didEndElement e:String,namespaceURI:String?,qualifiedName:String?){let n=e.lowercased();if n.hasSuffix("text"),inLabel,!stack.isEmpty{stack[stack.count-1].title=text.trimmingCharacters(in:.whitespacesAndNewlines);inLabel=false};if n.hasSuffix("navpoint"),let node=stack.popLast(){if stack.isEmpty{roots.append(node)}else{stack[stack.count-1].children.append(node)}}}
}
private final class NavDelegate:NSObject,XMLParserDelegate{
    var roots:[NavigationNode]=[];private var inTOCNav=false;private var olDepth=0;private var stack:[NavigationNode]=[];private var linkText="";private var linkHref:String?;private let basePath:String
    init(basePath:String){self.basePath=basePath}
    func parser(_ parser:XMLParser,didStartElement e:String,namespaceURI:String?,qualifiedName:String?,attributes:[String:String]){let n=e.lowercased();if n=="nav"{let marker=(attributes["epub:type"] ?? attributes["type"] ?? "").lowercased();inTOCNav=marker.contains("toc") || !inTOCNav};guard inTOCNav else{return};if n=="ol"{olDepth += 1};if n=="li"{stack.append(.init(title:"",href:"",children:[]))};if n=="a"{linkText="";linkHref=attributes["href"]}}
    func parser(_ parser:XMLParser,foundCharacters s:String){if linkHref != nil{linkText += s}}
    func parser(_ parser:XMLParser,didEndElement e:String,namespaceURI:String?,qualifiedName:String?){let n=e.lowercased();guard inTOCNav else{return};if n=="a",!stack.isEmpty{stack[stack.count-1].title=linkText.trimmingCharacters(in:.whitespacesAndNewlines);if let h=linkHref{stack[stack.count-1].href=NavigationParser.resolve(h,basePath:basePath)};linkHref=nil};if n=="li",let node=stack.popLast(){if stack.isEmpty{roots.append(node)}else{stack[stack.count-1].children.append(node)}};if n=="ol"{olDepth=max(0,olDepth-1)};if n=="nav"{inTOCNav=false}}
}
