import PulseFloatCore
import XCTest

final class SampleRingBufferTests: XCTestCase {
    private func latest(_ ring: SampleRingBuffer, _ count: Int) -> (samples: [Float], copied: Int) {
        var output = [Float](repeating: -1, count: count)
        let copied = output.withUnsafeMutableBufferPointer { buffer in
            ring.copyLatest(into: buffer.baseAddress!, count: count)
        }
        return (output, copied)
    }

    func testCapacityRoundsUpToPowerOfTwoWithMinimum() {
        XCTAssertEqual(SampleRingBuffer(capacity: 10).capacity, 1024)
        XCTAssertEqual(SampleRingBuffer(capacity: 5000).capacity, 8192)
        XCTAssertEqual(SampleRingBuffer().capacity, 16_384)
    }

    func testEmptyBufferCopiesZerosAndReportsNothing() {
        let (samples, copied) = latest(SampleRingBuffer(), 8)
        XCTAssertEqual(copied, 0)
        XCTAssertEqual(samples, [Float](repeating: 0, count: 8))
    }

    func testFewerSamplesThanRequestedAreRightAlignedWithZeroPadding() {
        let ring = SampleRingBuffer()
        let input: [Float] = [1, 2, 3]
        input.withUnsafeBufferPointer { ring.write($0.baseAddress!, count: 3) }
        let (samples, copied) = latest(ring, 5)
        XCTAssertEqual(copied, 3)
        XCTAssertEqual(samples, [0, 0, 1, 2, 3])
        XCTAssertEqual(ring.totalWritten, 3)
    }

    func testWrapAroundKeepsNewestSamplesInOrder() {
        let ring = SampleRingBuffer(capacity: 1024)
        let input = (0..<1500).map(Float.init)
        // 分兩次寫入，第二次會繞過結尾。
        input.withUnsafeBufferPointer { buffer in
            ring.write(buffer.baseAddress!, count: 1000)
            ring.write(buffer.baseAddress! + 1000, count: 500)
        }
        let (samples, copied) = latest(ring, 256)
        XCTAssertEqual(copied, 256)
        XCTAssertEqual(samples, Array(input[1244..<1500]))
    }

    func testOversizedWriteKeepsOnlyTheNewestCapacity() {
        let ring = SampleRingBuffer(capacity: 1024)
        let input = (0..<3000).map(Float.init)
        input.withUnsafeBufferPointer { ring.write($0.baseAddress!, count: 3000) }
        XCTAssertEqual(ring.totalWritten, 1024, "超過 capacity 的舊樣本不計入")
        let (samples, copied) = latest(ring, 512)
        XCTAssertEqual(copied, 512)
        XCTAssertEqual(samples, Array(input[2488..<3000]))
    }

    func testReadsAreLimitedToThreeQuartersOfCapacityAndZeroPadded() {
        // 保留 capacity/4 給寫入者「寫到一半、尚未發布」的區塊，所以最多讀 768 個（capacity 1024）。
        let ring = SampleRingBuffer(capacity: 1024)
        let input = (0..<2000).map(Float.init)
        input.withUnsafeBufferPointer { ring.write($0.baseAddress!, count: 2000) }
        let (samples, copied) = latest(ring, 1100)
        XCTAssertEqual(copied, 768)
        XCTAssertEqual(Array(samples[0..<332]), [Float](repeating: 0, count: 332))
        XCTAssertEqual(Array(samples[332...]), Array(input[1232..<2000]))
    }

    func testInterleavedStereoIsAveragedToMono() {
        let ring = SampleRingBuffer()
        let interleaved: [Float] = [1, 3, -2, 2, 0.5, 0.5]
        interleaved.withUnsafeBufferPointer { ring.writeInterleaved($0.baseAddress!, frameCount: 3, channelCount: 2) }
        XCTAssertEqual(latest(ring, 3).samples, [2, 0, 0.5])
    }

    func testDeinterleavedStereoIsAveragedAndMonoPassesThrough() {
        let ring = SampleRingBuffer()
        let left: [Float] = [1, 0, -1]
        let right: [Float] = [3, 0.5, 1]
        left.withUnsafeBufferPointer { l in
            right.withUnsafeBufferPointer { r in
                ring.writeDeinterleaved(left: l.baseAddress!, right: r.baseAddress!, frameCount: 3)
                ring.writeDeinterleaved(left: l.baseAddress!, right: nil, frameCount: 3)
            }
        }
        XCTAssertEqual(latest(ring, 6).samples, [2, 0.25, 0, 1, 0, -1])
    }

    func testZeroOrNegativeCountsAreIgnored() {
        let ring = SampleRingBuffer()
        let input: [Float] = [1]
        input.withUnsafeBufferPointer { buffer in
            ring.write(buffer.baseAddress!, count: 0)
            ring.writeInterleaved(buffer.baseAddress!, frameCount: -1, channelCount: 2)
            ring.writeInterleaved(buffer.baseAddress!, frameCount: 1, channelCount: 0)
            ring.writeDeinterleaved(left: buffer.baseAddress!, right: nil, frameCount: 0)
        }
        XCTAssertEqual(ring.totalWritten, 0)
        var scratch: [Float] = [7]
        let copied = scratch.withUnsafeMutableBufferPointer { ring.copyLatest(into: $0.baseAddress!, count: 0) }
        XCTAssertEqual(copied, 0)
        XCTAssertEqual(scratch, [7])
    }

    func testConcurrentWriterAndReaderNeverSeeTornWindows() {
        // 寫入端送遞增數列；讀取端拿到的真實樣本必須是連續遞增（不撕裂、不亂序）。
        let ring = SampleRingBuffer(capacity: 4096)
        let done = expectation(description: "writer finished")
        DispatchQueue.global(qos: .userInteractive).async {
            var chunk = [Float](repeating: 0, count: 512)
            var next: Float = 1
            for _ in 0..<2000 {
                for index in chunk.indices {
                    chunk[index] = next
                    next += 1
                }
                chunk.withUnsafeBufferPointer { ring.write($0.baseAddress!, count: 512) }
            }
            done.fulfill()
        }
        var output = [Float](repeating: 0, count: 2048)
        var checks = 0
        while checks < 2000 {
            let copied = output.withUnsafeMutableBufferPointer { ring.copyLatest(into: $0.baseAddress!, count: 2048) }
            let real = output.suffix(copied)
            for (previous, current) in zip(real, real.dropFirst()) where current != previous + 1 {
                XCTFail("torn window: \(previous) → \(current)")
                return
            }
            checks += 1
        }
        wait(for: [done], timeout: 10)
    }
}
