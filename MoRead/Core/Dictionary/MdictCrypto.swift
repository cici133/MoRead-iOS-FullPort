import Foundation

// MDict v2 encrypts the key-block info using RIPEMD-128-derived bytes. This implementation is
// intentionally local so the iOS port does not need an extra crypto framework for one legacy format.
enum RIPEMD128 {
    static func digest(_ data: Data) -> [UInt8] {
        var message = [UInt8](data)
        let bitLength = UInt64(message.count) * 8
        message.append(0x80)
        while message.count % 64 != 56 { message.append(0) }
        for i in 0..<8 { message.append(UInt8((bitLength >> UInt64(i * 8)) & 0xff)) }

        var h0: UInt32 = 0x67452301, h1: UInt32 = 0xefcdab89
        var h2: UInt32 = 0x98badcfe, h3: UInt32 = 0x10325476
        for base in stride(from: 0, to: message.count, by: 64) {
            var x = [UInt32](repeating: 0, count: 16)
            for i in 0..<16 {
                let j = base + i * 4
                x[i] = UInt32(message[j]) | UInt32(message[j+1]) << 8 | UInt32(message[j+2]) << 16 | UInt32(message[j+3]) << 24
            }
            var a=h0,b=h1,c=h2,d=h3, aa=h0,bb=h1,cc=h2,dd=h3
            for j in 0..<64 {
                let t = rol(a &+ f(j,b,c,d) &+ x[r[j]] &+ k(j), s[j])
                a=d; d=c; c=b; b=t
                let tt = rol(aa &+ fp(j,bb,cc,dd) &+ x[rp[j]] &+ kp(j), sp[j])
                aa=dd; dd=cc; cc=bb; bb=tt
            }
            let t = h1 &+ c &+ dd
            h1 = h2 &+ d &+ aa
            h2 = h3 &+ a &+ bb
            h3 = h0 &+ b &+ cc
            h0 = t
        }
        var digest: [UInt8] = []
        digest.reserveCapacity(16)
        for value in [h0, h1, h2, h3] {
            digest.append(UInt8(value & 0xff))
            digest.append(UInt8((value >> 8) & 0xff))
            digest.append(UInt8((value >> 16) & 0xff))
            digest.append(UInt8((value >> 24) & 0xff))
        }
        return digest
    }
    private static func rol(_ x: UInt32,_ n:Int)->UInt32{ (x << UInt32(n)) | (x >> UInt32(32-n)) }
    private static func f(_ j:Int,_ x:UInt32,_ y:UInt32,_ z:UInt32)->UInt32 {
        switch j { case 0..<16:return x^y^z; case 16..<32:return (x & y) | (~x & z); case 32..<48:return (x | ~y) ^ z; default:return (x & z) | (y & ~z) }
    }
    private static func fp(_ j:Int,_ x:UInt32,_ y:UInt32,_ z:UInt32)->UInt32 {
        switch j { case 0..<16:return (x & z) | (y & ~z); case 16..<32:return (x | ~y) ^ z; case 32..<48:return (x & y) | (~x & z); default:return x^y^z }
    }
    private static func k(_ j:Int)->UInt32 { switch j { case 0..<16:0; case 16..<32:0x5a827999; case 32..<48:0x6ed9eba1; default:0x8f1bbcdc } }
    private static func kp(_ j:Int)->UInt32 { switch j { case 0..<16:0x50a28be6; case 16..<32:0x5c4dd124; case 32..<48:0x6d703ef3; default:0 } }
    private static let r=[0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,7,4,13,1,10,6,15,3,12,0,9,5,2,14,11,8,3,10,14,4,9,15,8,1,2,7,0,6,13,11,5,12,1,9,11,10,0,8,12,4,13,3,7,15,14,5,6,2]
    private static let rp=[5,14,7,0,9,2,11,4,13,6,15,8,1,10,3,12,6,11,3,7,0,13,5,10,14,15,8,12,4,9,1,2,15,5,1,3,7,14,6,9,11,8,12,2,10,0,4,13,8,6,4,1,3,11,15,0,5,12,2,13,9,7,10,14]
    private static let s=[11,14,15,12,5,8,7,9,11,13,14,15,6,7,9,8,7,6,8,13,11,9,7,15,7,12,15,9,11,7,13,12,11,13,6,7,14,9,13,15,14,8,13,6,5,12,7,5,11,12,14,15,14,15,9,8,9,14,5,6,8,6,5,12]
    private static let sp=[8,9,9,11,13,15,15,5,7,7,8,11,14,14,12,6,9,13,15,7,12,8,9,11,7,7,12,7,6,15,13,11,9,7,15,11,8,6,6,14,12,13,5,14,13,13,7,5,15,5,8,11,14,14,6,14,6,9,12,9,12,5,15,8]
}

// LZO1X decoder for MDict blocks. The stream format is the standard miniLZO 1X layout.
enum LZO1X {
    enum Error: Swift.Error { case malformed, outputOverflow }

    static func decompress(_ source: Data, expected: Int) throws -> Data {
        let input = [UInt8](source)
        var ip = 0, op = 0
        var out = [UInt8](repeating: 0, count: expected)
        guard !input.isEmpty else { throw Error.malformed }
        func byte() throws -> Int { guard ip < input.count else { throw Error.malformed }; defer { ip += 1 }; return Int(input[ip]) }
        func copyLiterals(_ n: Int) throws {
            guard n >= 0, ip + n <= input.count, op + n <= out.count else { throw Error.outputOverflow }
            if n > 0 { for i in 0..<n { out[op+i]=input[ip+i] }; ip += n; op += n }
        }
        func copyMatch(distance: Int, length: Int) throws {
            guard distance > 0, length > 0, op - distance >= 0, op + length <= out.count else { throw Error.malformed }
            var m = op - distance
            for _ in 0..<length { out[op] = out[m]; op += 1; m += 1 }
        }
        func extendedLength(_ base: Int) throws -> Int {
            var value = 0
            while ip < input.count && input[ip] == 0 { value += 255; ip += 1 }
            value += try byte()
            return value + base
        }

        var t = try byte()
        if t > 17 {
            t -= 17
            if t < 4 { try copyLiterals(t) }
            else { try copyLiterals(t); t = try byte() }
        }
        while true {
            if t < 16 {
                if t == 0 { t = try extendedLength(15) }
                try copyLiterals(t + 3)
                t = try byte()
                if t < 16 {
                    let b = try byte()
                    let distance = 0x0801 + (t >> 2) + (b << 2)
                    try copyMatch(distance: distance, length: 3)
                    t &= 3
                    if t == 0 { t = try byte(); continue }
                    try copyLiterals(t)
                    t = try byte()
                }
            }
            while true {
                var length: Int, distance: Int
                if t >= 64 {
                    let b = try byte()
                    distance = 1 + ((t >> 2) & 7) + (b << 3)
                    length = (t >> 5) + 1
                } else if t >= 32 {
                    length = t & 31
                    if length == 0 { length = try extendedLength(31) }
                    let b1 = try byte(), b2 = try byte()
                    distance = 1 + ((b1 | (b2 << 8)) >> 2)
                    length += 2
                } else if t >= 16 {
                    length = t & 7
                    if length == 0 { length = try extendedLength(7) }
                    let b1 = try byte(), b2 = try byte()
                    let raw = (b1 | (b2 << 8)) >> 2
                    distance = 0x4000 + 1 + raw + ((t & 8) << 11)
                    if raw == 0 && (t & 8) == 0 { // end marker
                        guard op == expected else { throw Error.malformed }
                        return Data(out)
                    }
                    length += 2
                } else {
                    let b = try byte()
                    distance = 1 + (t >> 2) + (b << 2)
                    length = 2
                }
                try copyMatch(distance: distance, length: length)
                t &= 3
                if t == 0 { t = try byte(); break }
                try copyLiterals(t)
                t = try byte()
                if t < 16 { break }
            }
            if op == expected { return Data(out) }
        }
    }
}
