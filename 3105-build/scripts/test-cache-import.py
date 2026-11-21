#!/usr/bin/env python3
import pathlib, subprocess, tempfile
root = pathlib.Path(__file__).resolve().parents[1]
models = (root / "ThreeOneOSFive/helpers/PatchProjectModels.swift").read_text()
codec = (root / "ThreeOneOSFive/helpers/PatchPackageCodec.swift").read_text()
content = (root / "ThreeOneOSFive/ContentView.swift").read_text()
cache = content[content.index("struct BigVipCacheFile: Codable"):]
visual_source = (root / "ThreeOneOSFive/BigVipVisualImport.swift").read_text()
visual = visual_source[visual_source.index("struct BigVipVisualFile: Codable"):visual_source.index("struct BigVipVisualImportView: View")]
checks = r'''
let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: dir) }
let bytes = Data([0, 2, 255, 14])
let file = dir.appendingPathComponent("cache_custom")
try bytes.write(to: file)
let read = try BigVipCacheFile.readSource(file)
precondition(read.data == bytes && read.filename == "cache_custom")
let second = dir.appendingPathComponent("other.cache")
try Data([10, 20]).write(to: second)
precondition(try! BigVipCacheFile.readSource(second).data == Data([10, 20]))
func reject(_ file: URL) {
    do { _ = try BigVipCacheFile.readSource(file); fatalError("Invalid cache accepted") } catch { }
}
let wrong = dir.appendingPathComponent("not-a-cache.txt")
try bytes.write(to: wrong)
reject(wrong)
let empty = dir.appendingPathComponent("cache_empty")
try Data().write(to: empty)
reject(empty)
let renamed = dir.appendingPathComponent("cache_fake")
try Data("3105PATCH\0contents".utf8).write(to: renamed)
reject(renamed)
let link = dir.appendingPathComponent("cache_link")
try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
reject(link)
let project = PatchProject(name: "test", bundleIdentifiers: ["com.example.game"],
    rules: [PatchRule(bundleID: "com.example.game", relativePath: "Library/cache",
                     replacementFilename: read.filename, replacementData: read.data)])
for encoded in [
    try PatchPackageCodec.encodeLegacyV1(project: project, password: nil),
    try PatchPackageCodec.encodeLegacyV2(project: project, password: nil),
    try PatchPackageCodec.encodeNew(project: project, password: nil)
] {
    let decoded = try PatchPackageCodec.decode(encoded.data, password: nil)
    precondition(decoded.project == project)
}
let encoded = try PatchPackageCodec.encodeNew(project: project, password: "test-only-password")
precondition(try! PatchPackageCodec.decode(encoded.data, password: "test-only-password").project == project)
do { _ = try PatchPackageCodec.decode(encoded.data, password: "wrong"); fatalError("Wrong password accepted") } catch {}
var plist = try PropertyListSerialization.propertyList(from: encoded.data.dropFirst(10), format: nil) as! [String:Any]
plist["schemaVersion"] = 99
var future = Data("3105PATCH\0".utf8)
future.append(try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0))
do { _ = try PatchPackageCodec.inspect(future); fatalError("Future schema accepted without decoder") }
catch { precondition(error as? PatchPackageError == .unsupportedSchema(99)) }
let espSource = dir.appendingPathComponent("custom.esp")
try bytes.write(to: espSource)
let chamsSource = dir.appendingPathComponent("custom.chams")
try Data([55, 99]).write(to: chamsSource)
let esp = try BigVipVisualFile.readSource(espSource)
let chams = try BigVipVisualFile.readSource(chamsSource)
let gameA = "com.example.test" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
let gameB = "com.example.test" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
try esp.save(bundleID: gameA, kind: "esp")
try chams.save(bundleID: gameA, kind: "chams")
try chams.save(bundleID: gameB, kind: "esp")
defer {
    for (game, kind) in [(gameA, "esp"), (gameA, "chams"), (gameB, "esp")] {
        if let url = try? BigVipVisualFile.location(bundleID: game, kind: kind) { try? FileManager.default.removeItem(at: url) }
    }
}
precondition(BigVipVisualFile.load(bundleID: gameA, kind: "esp")?.data == bytes)
precondition(BigVipVisualFile.load(bundleID: gameA, kind: "chams")?.data == chams.data)
precondition(BigVipVisualFile.load(bundleID: gameB, kind: "esp")?.data == chams.data)
do { _ = try BigVipVisualFile.readSource(renamed); fatalError(".3105 cannot be imported as ESP") } catch {}
print("PASS: ESP/Chams import, persistent file slots, isolation between games, package rejection")
print("PASS: custom cache bytes, alternate cache, invalid inputs, .3105 schemas 1/2/3, password verification, precise future-schema error")
'''
with tempfile.TemporaryDirectory(prefix="bigvip-cache-tests-") as temp:
    p = pathlib.Path(temp) / "CacheTests.swift"
    p.write_text(models + "\n" + codec + "\n" + cache + "\n" + visual + "\n" + checks)
    subprocess.run(["swift", str(p)], check=True, timeout=180)
