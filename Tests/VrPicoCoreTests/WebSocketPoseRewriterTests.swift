import Foundation
import XCTest
@testable import VrPicoCore

final class WebSocketPoseRewriterTests: XCTestCase {

    private let handshake = Data(
        "GET /ws?token=eva HTTP/1.1\r\nHost: 127.0.0.1:8417\r\nUpgrade: websocket\r\n\r\n".utf8
    )

    /// 和 APK 组帧格式一致的测试帧。
    private func poseFrameJSON(x: Double = 0.1, y: Double = 0.2, z: Double = 0.3,
                               qx: Double = 0.1, qy: Double = 0.2, qz: Double = 0.3, qw: Double = 0.9) -> Data {
        Data("""
        {"type":"frame","version":1,"seq":1,"client_time_ms":1,"reference_space":"local-floor","controllers":{"left":{"valid":true,"position":[\(x),\(y),\(z)],"orientation_xyzw":[\(qx),\(qy),\(qz),\(qw)],"profiles":["pico-4-ultra"],"mapping":"pico-4-ultra","buttons":[],"axes":[0,0]},"right":{"valid":true,"position":[\(x),\(y),\(z)],"orientation_xyzw":[\(qx),\(qy),\(qz),\(qw)],"profiles":["pico-4-ultra"],"mapping":"pico-4-ultra","buttons":[],"axes":[0,0]}}}
        """.utf8)
    }

    private func maskedClientFrame(opcode: UInt8 = 0x1, payload: Data, fin: Bool = true) -> Data {
        var out: [UInt8] = [(fin ? 0x80 : 0) | opcode]
        let mask: [UInt8] = [1, 2, 3, 4]
        let count = payload.count
        switch count {
        case 0..<126:
            out.append(0x80 | UInt8(count))
        default:
            out.append(0x80 | 126)
            out.append(UInt8(count >> 8)); out.append(UInt8(count & 0xFF))
        }
        out.append(contentsOf: mask)
        out.append(contentsOf: payload.enumerated().map { $0.element ^ mask[$0.offset & 3] })
        return Data(out)
    }

    /// 解码改写器产出：应当恰好是 expectedCount 个带掩码的合法帧。
    private func decodeEmitted(_ data: Data, expectedCount: Int = 1) throws -> [(opcode: UInt8, payload: Data)] {
        var rewriter = WebSocketPoseRewriter(flip: { false })
        // 借改写器的解析器验证自己产出的帧能再被解析。
        var frames: [(UInt8, Data)] = []
        var flipCapture = false
        _ = flipCapture
        // 直接手工解析。
        var bytes = [UInt8](data)
        while !bytes.isEmpty {
            XCTAssertGreaterThanOrEqual(bytes.count, 2)
            let opcode = bytes[0] & 0x0F
            XCTAssertTrue(bytes[0] & 0x80 != 0, "FIN must be set on re-emitted frames")
            XCTAssertTrue(bytes[1] & 0x80 != 0, "client frames must stay masked")
            var length = Int(bytes[1] & 0x7F)
            var offset = 2
            if length == 126 {
                length = Int(bytes[2]) << 8 | Int(bytes[3]); offset = 4
            } else if length == 127 {
                var value: UInt64 = 0
                for i in 0..<8 { value = value << 8 | UInt64(bytes[2 + i]) }
                length = Int(value); offset = 10
            }
            let mask = Array(bytes[offset..<offset + 4]); offset += 4
            var payload = Array(bytes[offset..<offset + length])
            for i in payload.indices { payload[i] ^= mask[i & 3] }
            frames.append((opcode, Data(payload)))
            bytes.removeFirst(offset + length)
        }
        XCTAssertEqual(frames.count, expectedCount)
        return frames
    }

    private func controllers(in payload: Data) throws -> [String: [String: Any]] {
        let root = try JSONSerialization.jsonObject(with: payload) as? [String: Any]
        return root?["controllers"] as? [String: [String: Any]] ?? [:]
    }

    // MARK: - 握手

    func testHandshakePassesThroughByteIdentical() {
        var rewriter = WebSocketPoseRewriter(flip: { true })
        XCTAssertEqual(rewriter.process(handshake), handshake)
    }

    func testSplitHandshakeIsBufferedThenForwarded() {
        var rewriter = WebSocketPoseRewriter(flip: { true })
        let part = handshake.prefix(20)
        XCTAssertEqual(rewriter.process(Data(part)), Data())
        // 前半被暂存，所以第二次要连本带利吐出完整握手。
        XCTAssertEqual(rewriter.process(handshake.dropFirst(20)), handshake)
    }

    // MARK: - 反转

    func testPoseFrameIsFlippedWhenEnabled() throws {
        var rewriter = WebSocketPoseRewriter(flip: { true })
        _ = rewriter.process(handshake)
        let output = rewriter.process(maskedClientFrame(payload: poseFrameJSON()))

        let frames = try decodeEmitted(output)
        let controllers = try controllers(in: frames[0].payload)
        let left = controllers["left"]
        XCTAssertEqual(left?["position"] as? [Double], [-0.1, 0.2, -0.3])
        XCTAssertEqual(left?["orientation_xyzw"] as? [Double], [0.3, 0.9, -0.1, -0.2])
    }

    func testPoseFramePayloadIsUnchangedWhenDisabled() throws {
        var rewriter = WebSocketPoseRewriter(flip: { false })
        _ = rewriter.process(handshake)
        let original = poseFrameJSON()
        let output = rewriter.process(maskedClientFrame(payload: original))

        let frames = try decodeEmitted(output)
        // 关闭时不重写：payload 逐字节一致。
        XCTAssertEqual(frames[0].payload, original)
    }

    func testToggleAppliesToTheVeryNextFrame() throws {
        var flip = false
        var rewriter = WebSocketPoseRewriter(flip: { flip })
        _ = rewriter.process(handshake)

        let before = rewriter.process(maskedClientFrame(payload: poseFrameJSON()))
        flip = true
        let after = rewriter.process(maskedClientFrame(payload: poseFrameJSON()))

        let beforePayload = try decodeEmitted(before)[0].payload
        let afterPayload = try decodeEmitted(after)[0].payload
        XCTAssertEqual(beforePayload, poseFrameJSON())
        let controllers = try controllers(in: afterPayload)
        XCTAssertEqual(controllers["right"]?["position"] as? [Double], [-0.1, 0.2, -0.3])
    }

    // MARK: - 健壮性

    func testFrameSplitAcrossChunksStillParses() throws {
        var rewriter = WebSocketPoseRewriter(flip: { true })
        _ = rewriter.process(handshake)
        let wire = maskedClientFrame(payload: poseFrameJSON())

        var output = Data()
        output.append(rewriter.process(wire.prefix(3)))
        output.append(rewriter.process(wire.dropFirst(3).prefix(10)))
        output.append(rewriter.process(wire.dropFirst(13)))

        let frames = try decodeEmitted(output)
        let controllers = try controllers(in: frames[0].payload)
        XCTAssertEqual(controllers["left"]?["position"] as? [Double], [-0.1, 0.2, -0.3])
    }

    func testPingAndPongPassThrough() throws {
        var rewriter = WebSocketPoseRewriter(flip: { true })
        _ = rewriter.process(handshake)
        let ping = maskedClientFrame(opcode: 0x9, payload: Data("hb".utf8))

        let frames = try decodeEmitted(rewriter.process(ping))
        XCTAssertEqual(frames[0].opcode, 0x9)
        XCTAssertEqual(frames[0].payload, Data("hb".utf8))
    }

    func testBinaryAndNonFrameTextAreNotTouched() throws {
        var rewriter = WebSocketPoseRewriter(flip: { true })
        _ = rewriter.process(handshake)

        let binary = maskedClientFrame(opcode: 0x2, payload: poseFrameJSON())
        let event = maskedClientFrame(opcode: 0x1, payload: Data("{\"type\":\"event\"}".utf8))

        XCTAssertEqual(try decodeEmitted(rewriter.process(binary))[0].payload, poseFrameJSON())
        XCTAssertEqual(try decodeEmitted(rewriter.process(event))[0].payload, Data("{\"type\":\"event\"}".utf8))
    }

    func testFragmentedMessageIsReassembledAndFlipped() throws {
        var rewriter = WebSocketPoseRewriter(flip: { true })
        _ = rewriter.process(handshake)
        let payload = poseFrameJSON()
        let half = payload.count / 2
        var wire = Data()
        wire.append(maskedClientFrame(opcode: 0x1, payload: payload.prefix(half), fin: false))
        wire.append(maskedClientFrame(opcode: 0x0, payload: payload.dropFirst(half), fin: true))

        let frames = try decodeEmitted(rewriter.process(wire))
        let controllers = try controllers(in: frames[0].payload)
        XCTAssertEqual(controllers["left"]?["orientation_xyzw"] as? [Double], [0.3, 0.9, -0.1, -0.2])
    }

    func testGarbageAfterHandshakeFallsBackToRawForwarding() {
        var rewriter = WebSocketPoseRewriter(flip: { true })
        _ = rewriter.process(handshake)
        let garbage = Data([0xFF, 0xFF, 0x01, 0x02])
        let output = rewriter.process(garbage)
        XCTAssertEqual(output, garbage, "解析失败必须原样放行，不能吃掉数据")
        // 之后的字节也原样通过。
        let more = Data([0x01, 0x02, 0x03])
        XCTAssertEqual(rewriter.process(more), more)
    }

    func testExtendedLengthFrameWorks() throws {
        var rewriter = WebSocketPoseRewriter(flip: { false })
        _ = rewriter.process(handshake)
        let big = Data(repeating: 0x61, count: 300)
        let frames = try decodeEmitted(rewriter.process(maskedClientFrame(payload: big)))
        XCTAssertEqual(frames[0].payload, big)
    }
}
