import Foundation
import Compression

/// On-demand MDX/MDD v1/v2 reader. It mirrors Android MoRead's security limits and keeps only
/// block indexes in memory; record blocks are decompressed only for a lookup.
final class MdictReader: @unchecked Sendable {
    private struct KeyBlock { let last:String; let position:UInt64; let compressed:Int; let expanded:Int; let entries:Int }
    private struct RecordBlock { let position:UInt64; let offset:UInt64; let compressed:Int; let expanded:Int }
    private struct Key { let offset:UInt64; let text:String }

    let fileURL: URL
    let resource: Bool
    let title: String
    let declaredTitle: String
    private var version = 2.0
    private var encoding: String.Encoding = .utf8
    private var caseSensitive = false
    private var stripKeys = true
    private var keyBlocks:[KeyBlock]=[]
    private var recordBlocks:[RecordBlock]=[]
    private var totalRecordBytes:UInt64=0
    private let lock=NSLock()

    init(url: URL, resource: Bool? = nil) throws {
        self.fileURL=url
        self.resource = resource ?? (url.pathExtension.lowercased() == "mdd")
        let handle=try FileHandle(forReadingFrom:url); defer{try? handle.close()}
        let headerSize=Int(try handle.readUInt32BE())
        guard headerSize>0 && headerSize<=1_048_576 else{throw Error.invalid("词典文件头无效")}
        let header=try handle.readExactly(headerSize)
        let checksum=UInt32(bigEndian:try handle.readUInt32Native())
        try Self.verify(header,expected:checksum)
        let xml=String(data:header,encoding:.utf16LittleEndian) ?? ""
        let attrs=Self.attributes(xml)
        version=Double(attrs["GeneratedByEngineVersion"] ?? "") ?? 1.2
        guard version < 3 else{throw Error.invalid("暂不支持 MDX 3.0，请导出为 MDX 2.0")}
        let encrypted=(attrs["Encrypted"]=="Yes") ? 1 : (Int(attrs["Encrypted"] ?? "") ?? 0)
        guard encrypted & 1 == 0 else{throw Error.invalid("此词典需要授权密码，暂不支持导入加密授权词典")}
        encoding=Self.encoding(named:attrs["Encoding"],resource:self.resource)
        caseSensitive=(attrs["KeyCaseSensitive"] ?? "").caseInsensitiveCompare("Yes")== .orderedSame
        stripKeys = self.resource ? false : (attrs["StripKey"] ?? "").caseInsensitiveCompare("No") != .orderedSame
        declaredTitle=Self.unescape(attrs["Title"] ?? "")
        title=declaredTitle.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty ? url.deletingPathExtension().lastPathComponent : declaredTitle

        let numericSize=version >= 2 ? 8 : 4
        let headerFields=try handle.readExactly(version >= 2 ? 40 : 16)
        var cursor=DataCursor(headerFields)
        let blocks=try cursor.number(bytes:numericSize).boundedCount()
        _=try cursor.number(bytes:numericSize)
        let expandedIndex=version >= 2 ? try cursor.number(bytes:numericSize).boundedBlock() : 0
        let indexSize=try cursor.number(bytes:numericSize).boundedBlock()
        let keyBlocksSize=try cursor.number(bytes:numericSize)
        if version >= 2 { let expected=try handle.readUInt32BE(); try Self.verify(headerFields,expected:expected) }
        var rawIndex=try handle.readExactly(indexSize)
        if encrypted & 2 != 0 { rawIndex=Self.decodeIndex(rawIndex) }
        let indexBytes = version >= 2 ? try Self.unpack(rawIndex,expected:expandedIndex) : rawIndex
        var idx=DataCursor(indexBytes)
        var keyPosition=try handle.offset()
        for _ in 0..<blocks {
            let count=try idx.number(bytes:numericSize).boundedCount()
            _=try idx.indexText(version:version,encoding:encoding)
            let last=try idx.indexText(version:version,encoding:encoding)
            let compressed=try idx.number(bytes:numericSize).boundedBlock()
            let expanded=try idx.number(bytes:numericSize).boundedBlock()
            keyBlocks.append(.init(last:normalize(last),position:keyPosition,compressed:compressed,expanded:expanded,entries:count))
            keyPosition += UInt64(compressed)
        }
        let current = try handle.offset()
        let fileSizeAfterKeys = try handle.fileSize()
        guard idx.remaining == 0, keyPosition == current + keyBlocksSize, keyPosition <= fileSizeAfterKeys else { throw Error.invalid("词典索引损坏") }
        try handle.seek(toOffset:keyPosition)
        let recordCount=try handle.readNumber(bytes:numericSize).boundedCount()
        _=try handle.readNumber(bytes:numericSize)
        let recordIndexSize=try handle.readNumber(bytes:numericSize)
        let compressedRecords=try handle.readNumber(bytes:numericSize)
        guard recordIndexSize==UInt64(recordCount*numericSize*2) else{throw Error.invalid("词典正文索引损坏")}
        var position=try handle.offset()+recordIndexSize
        for _ in 0..<recordCount {
            let compressed=try handle.readNumber(bytes:numericSize).boundedBlock()
            let expanded=try handle.readNumber(bytes:numericSize).boundedBlock()
            recordBlocks.append(.init(position:position,offset:totalRecordBytes,compressed:compressed,expanded:expanded))
            position += UInt64(compressed); totalRecordBytes += UInt64(expanded)
        }
        let recordIndexEnd = try handle.offset()
        let fullFileSize = try handle.fileSize()
        guard position == recordIndexEnd + compressedRecords, position <= fullFileSize else { throw Error.invalid("词典正文不完整") }
    }

    func lookup(_ word:String)throws->Data?{
        lock.lock();defer{lock.unlock()}
        let target=normalize(word);guard !target.isEmpty else{return nil}
        var lo=0,hi=keyBlocks.count
        while lo<hi{let mid=(lo+hi)>>1;if keyBlocks[mid].last < target{lo=mid+1}else{hi=mid}}
        guard lo<keyBlocks.count else{return nil}
        let h=try FileHandle(forReadingFrom:fileURL);defer{try? h.close()}
        let entries=try readKeys(handle:h,index:lo)
        guard let found=entries.firstIndex(where:{normalize($0.text)==target}) else{return nil}
        let start=entries[found].offset
        var end=entries.dropFirst(found+1).first(where:{$0.offset>start})?.offset
        if end==nil && lo+1<keyBlocks.count{end=try readKeys(handle:h,index:lo+1).first(where:{$0.offset>start})?.offset}
        let finish=end ?? totalRecordBytes
        guard finish>=start,finish<=totalRecordBytes,finish-start<=16*1024*1024 else{throw Error.invalid("词条过大或索引损坏")}
        var result=Data();result.reserveCapacity(Int(finish-start))
        for block in recordBlocks where block.offset < finish && block.offset+UInt64(block.expanded)>start {
            try h.seek(toOffset:block.position)
            let decoded=try Self.unpack(try h.readExactly(block.compressed),expected:block.expanded)
            let from=Int(max(start,block.offset)-block.offset),to=Int(min(finish,block.offset+UInt64(block.expanded))-block.offset)
            result.append(decoded.subdata(in:from..<to))
        }
        return result
    }

    func definition(_ word:String)throws->String?{
        var current=word;var visited=Set<String>()
        for _ in 0..<8 {
            guard visited.insert(normalize(current)).inserted,let data=try lookup(current) else{return nil}
            let value=(String(data:data,encoding:encoding) ?? String(decoding:data,as:UTF8.self)).trimmingCharacters(in:CharacterSet(charactersIn:"\0"))
            if !value.hasPrefix("@@@LINK="){return value}
            current=String(value.dropFirst(8)).trimmingCharacters(in:.whitespacesAndNewlines)
        }
        return nil
    }

    private func readKeys(handle:FileHandle,index:Int)throws->[Key]{
        let block=keyBlocks[index];try handle.seek(toOffset:block.position)
        var cursor=DataCursor(try Self.unpack(try handle.readExactly(block.compressed),expected:block.expanded))
        let numericSize=version>=2 ? 8:4
        var result:[Key]=[];result.reserveCapacity(block.entries)
        for _ in 0..<block.entries {
            let offset=try cursor.number(bytes:numericSize)
            var bytes=Data()
            while true {
                let first=try cursor.byte()
                let second=encoding == .utf16LittleEndian ? try cursor.byte() : 0
                if first==0 && second==0{break}
                bytes.append(first);if encoding == .utf16LittleEndian{bytes.append(second)}
                guard bytes.count<=32768 else{throw Error.invalid("词条名称过长")}
            }
            result.append(.init(offset:offset,text:String(data:bytes,encoding:encoding) ?? ""))
        }
        guard cursor.remaining==0 else{throw Error.invalid("词条索引不完整")}
        return result
    }

    private func normalize(_ value:String)->String{
        var text = resource ? value.replacingOccurrences(of:"/",with:"\\") : value.trimmingCharacters(in:.whitespacesAndNewlines)
        if resource && !text.hasPrefix("\\"){text="\\"+text}
        if stripKeys{text=text.unicodeScalars.filter{!CharacterSet.punctuationCharacters.contains($0) && !CharacterSet.whitespacesAndNewlines.contains($0)}.map(String.init).joined()}
        return caseSensitive ? text : text.lowercased(with:Locale(identifier:"en_US_POSIX"))
    }

    enum Error:LocalizedError{case invalid(String);var errorDescription:String?{if case let .invalid(s)=self{return s};return nil}}
    private static let maxBlock=32*1024*1024
    private static func attributes(_ xml:String)->[String:String]{var out:[String:String]=[:];let regex=try! NSRegularExpression(pattern:#"([A-Za-z]+)=\"([^\"]*)\""#);let ns=xml as NSString;for m in regex.matches(in:xml,range:NSRange(location:0,length:ns.length)){out[ns.substring(with:m.range(at:1))]=ns.substring(with:m.range(at:2))};return out}
    private static func unescape(_ s:String)->String{s.replacingOccurrences(of:"&quot;",with:"\"").replacingOccurrences(of:"&amp;",with:"&").replacingOccurrences(of:"&lt;",with:"<").replacingOccurrences(of:"&gt;",with:">")}
    private static func encoding(named:String?,resource:Bool)->String.Encoding{if resource{return .utf16LittleEndian};let n=(named ?? "UTF-8").replacingOccurrences(of:"-",with:"").uppercased();if n=="UTF16"{return .utf16LittleEndian};if n=="GB18030"||n=="GBK"{return String.Encoding(rawValue:0x80000632)};if n=="BIG5"{return String.Encoding(rawValue:0x80000A03)};return .utf8}
    private static func verify(_ data:Data,expected:UInt32)throws{guard adler32(data)==expected else{throw Error.invalid("词典校验失败，文件可能损坏")}}
    private static func adler32(_ data:Data)->UInt32{var a:UInt32=1,b:UInt32=0;for byte in data{a=(a+UInt32(byte))%65521;b=(b+a)%65521};return (b<<16)|a}
    private static func decodeIndex(_ input:Data)->Data{guard input.count>=8 else{return input};let seed=input.subdata(in:4..<8)+Data([0x95,0x36,0,0]);let key=RIPEMD128.digest(seed);var r=[UInt8](input);var previous=0x36;for i in 8..<r.count{let v=Int(r[i]);r[i]=UInt8(((v>>4)|(v<<4)) ^ previous ^ ((i-8)&255) ^ Int(key[(i-8)%16]));previous=v};return Data(r)}
    private static func unpack(_ block:Data,expected:Int)throws->Data{guard block.count>=8,expected>=0,expected<=maxBlock else{throw Error.invalid("词典分块无效")};let bytes=[UInt8](block);let type=bytes[0];let payload=block.subdata(in:8..<block.count);let output:Data;switch type{case 0:output=payload;case 1:output=try LZO1X.decompress(payload,expected:expected);case 2:output=try zlib(payload,expected:expected);default:throw Error.invalid("不支持的词典压缩格式")};guard output.count==expected else{throw Error.invalid("词典分块大小不符")};let checksum=UInt32(bytes[4])<<24|UInt32(bytes[5])<<16|UInt32(bytes[6])<<8|UInt32(bytes[7]);try verify(output,expected:checksum);return output}
    private static func zlib(_ input:Data,expected:Int)throws->Data{var out=Data(count:expected);let result=out.withUnsafeMutableBytes{dst in input.withUnsafeBytes{src in compression_decode_buffer(dst.bindMemory(to:UInt8.self).baseAddress!,expected,src.bindMemory(to:UInt8.self).baseAddress!,input.count,nil,COMPRESSION_ZLIB)}};guard result==expected else{throw Error.invalid("Zlib 词典解压失败")};return out}
}

private struct DataCursor {
    let data: Data
    var offset = 0

    init(_ data: Data) { self.data = data }
    var remaining: Int { data.count - offset }

    mutating func byte() throws -> UInt8 {
        guard offset < data.count else { throw MdictReader.Error.invalid("词典数据不完整") }
        defer { offset += 1 }
        return data[offset]
    }

    mutating func number(bytes: Int) throws -> UInt64 {
        guard (bytes == 2 || bytes == 4 || bytes == 8), offset + bytes <= data.count else {
            throw MdictReader.Error.invalid("词典数据不完整")
        }
        var value: UInt64 = 0
        for _ in 0..<bytes { value = (value << 8) | UInt64(try byte()) }
        return value
    }

    mutating func indexText(version: Double, encoding: String.Encoding) throws -> String {
        let length: Int
        if version >= 2 { length = Int(try number(bytes: 2)) }
        else { length = Int(try byte()) }
        let unit = encoding == .utf16LittleEndian ? 2 : 1
        let count = length * unit
        guard offset + count <= data.count else { throw MdictReader.Error.invalid("词典索引文字损坏") }
        let bytes = data.subdata(in: offset..<(offset + count))
        offset += count
        if version >= 2 {
            offset += unit
            guard offset <= data.count else { throw MdictReader.Error.invalid("词典索引文字损坏") }
        }
        return String(data: bytes, encoding: encoding) ?? ""
    }
}

private extension UInt64 {
    func boundedCount() throws -> Int {
        guard self <= 1_000_000 else { throw MdictReader.Error.invalid("词典索引过大") }
        return Int(self)
    }
    func boundedBlock() throws -> Int {
        guard self <= 32 * 1024 * 1024 else { throw MdictReader.Error.invalid("词典分块过大") }
        return Int(self)
    }
}

private extension FileHandle {
    func readExactly(_ count: Int) throws -> Data {
        let data = try read(upToCount: count) ?? Data()
        guard data.count == count else { throw MdictReader.Error.invalid("词典数据不完整") }
        return data
    }
    func readUInt32BE() throws -> UInt32 {
        try readExactly(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }
    func readUInt32Native() throws -> UInt32 {
        let data = try readExactly(4)
        return data.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            return UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
        }
    }
    func readNumber(bytes: Int) throws -> UInt64 {
        try readExactly(bytes).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }
    func fileSize() throws -> UInt64 {
        let old = try offset()
        let end = try seekToEnd()
        try seek(toOffset: old)
        return end
    }
}
