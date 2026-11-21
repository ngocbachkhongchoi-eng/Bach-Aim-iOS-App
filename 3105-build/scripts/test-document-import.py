#!/usr/bin/env python3
"""Run the actual document staging helper against local files on the macOS builder."""
import pathlib, subprocess, tempfile
root = pathlib.Path(__file__).resolve().parents[1]
source = (root / "ThreeOneOSFive/views/FileBrowserView.swift").read_text()
start = source.index("        private static func stageDocument")
end = source.index("        func documentPickerWasCancelled", start)
helper = source[start:end].replace("private static func", "static func", 1)
test = r'''
let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: root) }
let bytes = Data([0, 1, 255, 42])
let source = root.appendingPathComponent("cache dữ liệu.unknown")
try bytes.write(to: source)
let a = try ImportUnderTest.stageDocument(source)
let b = try ImportUnderTest.stageDocument(source)
defer {
    try? FileManager.default.removeItem(at: a.deletingLastPathComponent())
    try? FileManager.default.removeItem(at: b.deletingLastPathComponent())
}
precondition(a != b, "Copies must not collide")
precondition(a.lastPathComponent == source.lastPathComponent, "Keep original filename")
precondition(try! Data(contentsOf: a) == bytes, "Preserve binary data")
try FileManager.default.removeItem(at: source)
precondition(try! Data(contentsOf: b) == bytes, "Staged file survives source disappearance")
func mustReject(_ url: URL) {
    do { _ = try ImportUnderTest.stageDocument(url); fatalError("Must reject invalid source") }
    catch { }
}
mustReject(source)
mustReject(root)
let real = root.appendingPathComponent("original")
try bytes.write(to: real)
let link = root.appendingPathComponent("link")
try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
mustReject(link)
print("PASS: bytes, Unicode name, unique copies, source lifetime, missing file, folder, symlink")
'''
with tempfile.TemporaryDirectory(prefix="bigvip-tests-") as temp:
    program = pathlib.Path(temp) / "ImportTests.swift"
    program.write_text("import Foundation\nenum ImportUnderTest {\n" + helper + "\n}\n" + test)
    subprocess.run(["swift", str(program)], check=True, timeout=180)
