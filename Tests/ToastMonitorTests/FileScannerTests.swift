import XCTest
@testable import ToastMonitor

final class FileScannerTests: XCTestCase {
    private var path: String!

    override func setUp() {
        super.setUp()
        path = NSTemporaryDirectory() + "tm-jsonl-\(UUID().uuidString).jsonl"
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: path)
        super.tearDown()
    }

    func testMalformedUTF8DoesNotShiftCursor() throws {
        let valid = Data("{\"type\":\"valid\"}\n".utf8)
        var bytes = Data([0xff, 0xfe, 0x0a])
        bytes.append(valid)
        try bytes.write(to: URL(fileURLWithPath: path))

        let result = FileScanner.readNewJSONLines(path: path, fromOffset: 0)
        XCTAssertEqual(result.objects.count, 1)
        XCTAssertEqual(result.objects.first?.obj["type"] as? String, "valid")
        XCTAssertEqual(result.newOffset, Int64(3 + valid.count))
    }

    func testPartialTrailingLineIsReplayable() throws {
        let prefix = Data("{\"type\":\"partial\"".utf8)
        try prefix.write(to: URL(fileURLWithPath: path))
        let first = FileScanner.readNewJSONLines(path: path, fromOffset: 0)
        XCTAssertTrue(first.objects.isEmpty)
        XCTAssertEqual(first.newOffset, 0)

        var completed = prefix
        completed.append(Data("}\n".utf8))
        try completed.write(to: URL(fileURLWithPath: path))
        let second = FileScanner.readNewJSONLines(path: path, fromOffset: first.newOffset)
        XCTAssertEqual(second.objects.count, 1)
        XCTAssertEqual(second.objects.first?.obj["type"] as? String, "partial")
        XCTAssertEqual(second.newOffset, Int64(prefix.count + 2))
    }
}
