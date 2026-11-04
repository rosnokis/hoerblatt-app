import Foundation

// Reads the project ZIP of an update (UpdateCheck.swift). tools/publish-app.sh writes it without compression
// ("stored"), so no unpacking library is needed; every file is checked against its CRC-32. Only plain Foundation:
// tested under Linux (tools/linuxtest).

enum ZipReadError: Error {
    case notZip, compressed, damaged, badPath
}

/// The files of a stored ZIP: path inside the archive → contents. Directories are left out. Paths that could reach
/// outside the target folder ("..", "/…") are refused.
func zipReadStored(_ data: Data) throws -> [String: Data] {
    let b = [UInt8](data)
    func u16(_ i: Int) -> Int { return Int(b[i]) | Int(b[i + 1]) << 8 }
    func u32(_ i: Int) -> Int { return u16(i) | u16(i + 2) << 16 }
    // end of central directory: the last record with its signature (a comment may follow it)
    guard b.count >= 22 else { throw ZipReadError.notZip }
    var end = -1
    var i = b.count - 22
    let lowest = max(0, b.count - 22 - 65_535)
    while i >= lowest {
        if b[i] == 0x50 && b[i + 1] == 0x4b && b[i + 2] == 0x05 && b[i + 3] == 0x06 {
            end = i
            break
        }
        i -= 1
    }
    guard end >= 0 else { throw ZipReadError.notZip }
    let count = u16(end + 10)
    var p = u32(end + 16)
    var files: [String: Data] = [:]
    for _ in 0..<count {
        guard p + 46 <= b.count, u32(p) == 0x0201_4b50 else { throw ZipReadError.damaged }
        let method = u16(p + 10)
        let crc = UInt32(truncatingIfNeeded: u32(p + 16))
        let packed = u32(p + 20)
        let size = u32(p + 24)
        let nameLen = u16(p + 28), extraLen = u16(p + 30), commentLen = u16(p + 32)
        let local = u32(p + 42)
        guard p + 46 + nameLen <= b.count else { throw ZipReadError.damaged }
        let name = String(decoding: b[(p + 46)..<(p + 46 + nameLen)], as: UTF8.self)
        p += 46 + nameLen + extraLen + commentLen
        if name.hasSuffix("/") { continue }
        guard zipSafePath(name) else { throw ZipReadError.badPath }
        guard method == 0 else { throw ZipReadError.compressed }
        guard packed == size, local + 30 <= b.count, u32(local) == 0x0403_4b50 else { throw ZipReadError.damaged }
        let start = local + 30 + u16(local + 26) + u16(local + 28)
        guard start + size <= b.count else { throw ZipReadError.damaged }
        let content = Data(b[start..<(start + size)])
        guard zipCRC32(content) == crc else { throw ZipReadError.damaged }
        files[name] = content
    }
    return files
}

/// A relative path that stays inside the folder it is written to.
func zipSafePath(_ name: String) -> Bool {
    if name.isEmpty || name.hasPrefix("/") || name.contains("\\") { return false }
    for part in name.split(separator: "/", omittingEmptySubsequences: false) {
        if part.isEmpty || part == "." || part == ".." { return false }
    }
    return true
}

func zipCRC32(_ data: Data) -> UInt32 {
    var crc: UInt32 = 0xFFFF_FFFF
    for byte in data {
        crc = zipCRCTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
    }
    return crc ^ 0xFFFF_FFFF
}

private let zipCRCTable: [UInt32] = (0..<256).map { n -> UInt32 in
    var c = UInt32(n)
    for _ in 0..<8 {
        c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1
    }
    return c
}
