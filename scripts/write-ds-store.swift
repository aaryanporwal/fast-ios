import Foundation

// write-ds-store.swift <mounted-volume>
//
// Writes the DMG window layout (.DS_Store) without scripting Finder: window
// size, no toolbar, 112 pt icons, the app at (160, 205), Applications at
// (480, 205), and .background/background.tiff as the window background.
// The volume must be the mounted read-write image, because the background is
// stored as an alias that names the file's catalog id and the volume's date.
//
// Format: a "Bud1" buddy-allocator file holding one B-tree ("DSDB") with one
// leaf node; layout as in the ds_store and mac_alias Python packages
// (dmgbuild), which document Finder's format.

let volume = URL(fileURLWithPath: CommandLine.arguments[1])
let volumeName = volume.lastPathComponent
let background = volume.appendingPathComponent(".background/background.tiff")

// MARK: Big-endian writer

struct BE {
    var data = Data()
    mutating func u8(_ v: UInt8) { data.append(v) }
    mutating func u16(_ v: UInt16) { data.append(contentsOf: [UInt8(v >> 8), UInt8(v & 0xff)]) }
    mutating func i16(_ v: Int16) { u16(UInt16(bitPattern: v)) }
    mutating func u32(_ v: UInt32) { for s in [24, 16, 8, 0] { data.append(UInt8((v >> UInt32(s)) & 0xff)) } }
    mutating func bytes(_ d: Data) { data.append(d) }
    mutating func fourCC(_ s: String) { data.append(contentsOf: Array(s.utf8.prefix(4))) }
    mutating func pascal(_ s: String, size: Int) {
        let b = Array(s.utf8.prefix(size - 1))
        u8(UInt8(b.count)); data.append(contentsOf: b)
        data.append(contentsOf: [UInt8](repeating: 0, count: size - 1 - b.count))
    }
    mutating func utf16(_ s: String) { for c in s.utf16 { u16(c) } }
    mutating func pad(to n: Int) { if data.count < n { data.append(contentsOf: [UInt8](repeating: 0, count: n - data.count)) } }
}

// MARK: Alias record (version 2) for the background picture

func hfsDate(_ d: Date) -> UInt32 { UInt32(max(0, d.timeIntervalSince1970 + 2_082_844_800)) }

func catalogID(_ url: URL) -> UInt32 {
    var st = stat()
    guard stat(url.path, &st) == 0 else { fatalError("cannot stat \(url.path)") }
    return UInt32(truncatingIfNeeded: st.st_ino)
}

func alias() -> Data {
    let fm = FileManager.default
    let volDate = (try? fm.attributesOfItem(atPath: volume.path)[.creationDate] as? Date) ?? Date()
    let fileDate = (try? fm.attributesOfItem(atPath: background.path)[.creationDate] as? Date) ?? Date()
    let folder = background.deletingLastPathComponent()
    var body = BE()
    body.i16(0)                                  // kind: file
    body.pascal(volumeName, size: 28)
    body.u32(hfsDate(volDate))
    body.data.append(contentsOf: Array("H+".utf8)) // filesystem type, 2 bytes
    body.i16(5)                                  // disk type: ejectable
    body.u32(catalogID(folder))
    body.pascal(background.lastPathComponent, size: 64)
    body.u32(catalogID(background))
    body.u32(hfsDate(fileDate))
    body.u32(0); body.u32(0)                     // type and creator
    body.i16(-1); body.i16(-1)                   // levels from, to
    body.u32(0)                                  // volume attributes
    body.u16(0)                                  // volume fs id
    body.pad(to: body.data.count + 10)           // reserved
    func tag(_ t: Int16, _ d: Data) {
        body.i16(t); body.u16(UInt16(d.count)); body.bytes(d)
        if d.count % 2 == 1 { body.u8(0) }
    }
    func u16String(_ s: String) -> Data { var b = BE(); b.u16(UInt16(s.utf16.count)); b.utf16(s); return b.data }
    tag(0, Data(folder.lastPathComponent.utf8))
    var cnids = BE(); cnids.u32(catalogID(folder)); tag(1, cnids.data)
    tag(2, Data("\(volumeName):\(folder.lastPathComponent):\(background.lastPathComponent)".utf8))
    tag(14, u16String(background.lastPathComponent))
    tag(15, u16String(volumeName))
    tag(18, Data("/\(folder.lastPathComponent)/\(background.lastPathComponent)".utf8))
    tag(19, Data(volume.path.utf8))
    body.i16(-1); body.u16(0)
    var out = BE()
    out.u32(0)                                   // app info
    out.u16(UInt16(8 + body.data.count))         // record length
    out.u16(2)                                   // version
    out.bytes(body.data)
    return out.data
}

// MARK: Records

func bplist(_ object: Any) -> Data {
    try! PropertyListSerialization.data(fromPropertyList: object, format: .binary, options: 0)
}

struct Record {
    let name: String
    let code: String
    let type: String
    let value: Data
}

func blob(_ d: Data) -> Data { var b = BE(); b.u32(UInt32(d.count)); b.bytes(d); return b.data }
func iloc(_ x: UInt32, _ y: UInt32) -> Data {
    var b = BE(); b.u32(x); b.u32(y); b.u32(0xFFFF_FFFF); b.u32(0xFFFF_0000); return blob(b.data)
}

let windowSettings: [String: Any] = [
    "ContainerShowSidebar": false, "ShowPathbar": false, "ShowSidebar": false, "ShowStatusBar": false,
    "ShowTabView": false, "ShowToolbar": false, "SidebarWidth": 0,
    "WindowBounds": "{{200, 120}, {640, 428}}",
]
let iconView: [String: Any] = [
    "arrangeBy": "none", "backgroundColorBlue": 1.0, "backgroundColorGreen": 1.0, "backgroundColorRed": 1.0,
    "backgroundImageAlias": alias(), "backgroundType": 2, "gridOffsetX": 0.0, "gridOffsetY": 0.0,
    "gridSpacing": 100.0, "iconSize": 112.0, "labelOnBottom": true, "showIconPreview": true,
    "showItemInfo": false, "textSize": 13.0, "viewOptionsVersion": 1,
]
var vSrn = BE(); vSrn.u32(1)

var records = [
    Record(name: ".", code: "bwsp", type: "blob", value: blob(bplist(windowSettings))),
    Record(name: ".", code: "icvp", type: "blob", value: blob(bplist(iconView))),
    Record(name: ".", code: "vSrn", type: "long", value: vSrn.data),
    Record(name: "Applications", code: "Iloc", type: "blob", value: iloc(480, 205)),
    Record(name: "fast-ios.app", code: "Iloc", type: "blob", value: iloc(160, 205)),
]
// Finder expects records sorted by name (case-insensitive), then code.
records.sort { ($0.name.lowercased(), $0.code) < ($1.name.lowercased(), $1.code) }

// MARK: Buddy allocator file

// Blocks (offsets are relative to file offset 4; each block is aligned to its
// power-of-two size): header 0..32, DSDB 32..64, info 2048..4096, leaf node
// 4096..8192. Everything else is on the free lists.
var node = BE()
node.u32(0)                                       // leaf
node.u32(UInt32(records.count))
for r in records {
    node.u32(UInt32(r.name.utf16.count)); node.utf16(r.name)
    node.fourCC(r.code); node.fourCC(r.type); node.bytes(r.value)
}
precondition(node.data.count <= 4096, "leaf node too large")

var dsdb = BE()
dsdb.u32(2)                                       // root node: block 2
dsdb.u32(0)                                       // levels below the root
dsdb.u32(UInt32(records.count))
dsdb.u32(1)                                       // nodes
dsdb.u32(0x1000)                                  // page size

func address(_ offset: UInt32, log2 size: UInt32) -> UInt32 { offset | size }

var info = BE()
info.u32(3)                                       // block count
info.u32(0)
let blocks = [address(2048, log2: 11), address(32, log2: 5), address(4096, log2: 12)]
for i in 0..<256 { info.u32(i < blocks.count ? blocks[i] : 0) }
info.u32(1)                                       // table of contents: one entry
info.u8(4); info.fourCC("DSDB"); info.u32(1)
// Free lists, one per size 2^0 ... 2^31.
var free = [[UInt32]](repeating: [], count: 32)
for log2 in 6...10 { free[log2] = [UInt32(1) << UInt32(log2)] }   // 64 ... 1024
for log2 in 13...30 { free[log2] = [UInt32(1) << UInt32(log2)] }  // 8192 ... 2^30
for list in free { info.u32(UInt32(list.count)); for o in list { info.u32(o) } }
precondition(info.data.count <= 2048, "info block too large")

var arena = BE()
arena.pad(to: 8192)
func place(_ d: Data, at offset: Int) { arena.data.replaceSubrange(offset..<(offset + d.count), with: d) }
var header = BE()
header.fourCC("Bud1")
header.u32(2048); header.u32(2048); header.u32(2048)
header.u32(0x100C); header.u32(0x0000_0087); header.u32(0x0000_200B); header.u32(0)
place(header.data, at: 0)
place(dsdb.data, at: 32)
place(info.data, at: 2048)
place(node.data, at: 4096)

var file = BE()
file.u32(1)
file.bytes(arena.data)
try! file.data.write(to: volume.appendingPathComponent(".DS_Store"))
print("wrote \(volume.path)/.DS_Store (\(records.count) records)")
