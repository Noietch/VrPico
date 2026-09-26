import Foundation

/// Turns native EVA-VR controller poses 180° inside the relay.
///
/// The APK ships raw XR poses as JSON text frames and the server applies
/// `base_from_xr_rotation`. When the robot ends up mirrored against the
/// controllers, the client-side place to counter-rotate is the byte stream
/// itself — doing it here means a server config reset cannot silently undo
/// the correction.
///
/// This is a pure state machine — bytes in, bytes out, no networking — so the
/// whole codec is testable without sockets.
public struct WebSocketPoseRewriter {

    /// Read once per complete frame, so a live toggle from the menu bar takes
    /// effect on the very next controller frame without reconnecting.
    public var flip: () -> Bool

    public init(flip: @escaping () -> Bool) {
        self.flip = flip
    }

    private enum Stage {
        /// HTTP Upgrade request passes through untouched until the header
        /// terminator arrives; nothing after it can be headers.
        case handshake
        case frames
        /// Something on the wire was not plain uncompressed WebSocket. Stop
        /// touching anything: forwarding raw bytes can never wedge teleop,
        /// it only means the flip stops applying.
        case passthrough
    }

    private var stage: Stage = .handshake
    private var buffer: [UInt8] = []
    private var fragments: [UInt8] = []
    private var fragmentOpcode: UInt8 = 0

    /// Handshake headers never exceed a few KB; past that the stream is not
    /// an HTTP Upgrade and waiting for `\r\n\r\n` would stall it forever.
    private static let maxHandshakeBytes = 64 * 1024
    /// Pose frames are under 1 KB. Anything MB-sized means the parser has
    /// desynced, so bail to passthrough instead of buffering unboundedly.
    private static let maxFrameBytes = 16 * 1024 * 1024

    /// Consume client→server bytes and return what may go upstream. The
    /// result is empty while a partial header or frame is being buffered.
    public mutating func process(_ incoming: Data) -> Data {
        switch stage {
        case .passthrough:
            return incoming
        case .handshake:
            buffer.append(contentsOf: incoming)
            guard let headerEnd = Self.headerTerminatorEnd(in: buffer) else {
                if buffer.count > Self.maxHandshakeBytes {
                    return drainIntoPassthrough()
                }
                return Data()
            }
            var output = Data(buffer[0..<headerEnd])
            buffer.removeFirst(headerEnd)
            stage = .frames
            output.append(processFrames())
            return output
        case .frames:
            buffer.append(contentsOf: incoming)
            return processFrames()
        }
    }

    // MARK: - 帧处理

    private mutating func processFrames() -> Data {
        var output = Data()
        while true {
            switch Self.nextFrame(from: buffer) {
            case .incomplete:
                return output
            case .corrupt:
                output.append(drainIntoPassthrough())
                return output
            case .frame(let frame, let consumed):
                buffer.removeFirst(consumed)
                output.append(handle(frame))
            }
        }
    }

    /// All buffered bytes flush out raw and every later byte passes through.
    private mutating func drainIntoPassthrough() -> Data {
        let rest = Data(buffer)
        buffer.removeAll(keepingCapacity: false)
        fragments.removeAll(keepingCapacity: false)
        stage = .passthrough
        return rest
    }

    private mutating func handle(_ frame: Frame) -> Data {
        switch frame.opcode {
        case 0x1, 0x2:  // text / binary
            if frame.fin {
                return Self.encode(opcode: frame.opcode, payload: processMessage(opcode: frame.opcode, payload: frame.payload))
            }
            fragmentOpcode = frame.opcode
            fragments = frame.payload
            return Data()
        case 0x0:  // continuation
            fragments.append(contentsOf: frame.payload)
            guard frame.fin else { return Data() }
            let opcode = fragmentOpcode
            let message = fragments
            fragments.removeAll(keepingCapacity: false)
            return Self.encode(opcode: opcode, payload: processMessage(opcode: opcode, payload: message))
        default:  // 0x8 close / 0x9 ping / 0xA pong: forward untouched
            return Self.encode(opcode: frame.opcode, payload: frame.payload)
        }
    }

    private func processMessage(opcode: UInt8, payload: [UInt8]) -> [UInt8] {
        guard opcode == 0x1, flip() else { return payload }
        return NativePoseFlip.rewriteFramePayload(payload)
    }

    // MARK: - 编解码

    private struct Frame {
        var fin: Bool
        var opcode: UInt8
        var payload: [UInt8]
    }

    private enum ParseResult {
        case incomplete
        case corrupt
        case frame(Frame, consumed: Int)
    }

    private static func nextFrame(from bytes: [UInt8]) -> ParseResult {
        guard bytes.count >= 2 else { return .incomplete }

        let fin = bytes[0] & 0x80 != 0
        let rsv = bytes[0] & 0x70
        let opcode = bytes[0] & 0x0F
        // RSV bits mean a negotiated extension (compression). The APK's OkHttp
        // client never offers one, and rewriting compressed payloads would be
        // garbage — treat it as "not ours" and pass through.
        guard rsv == 0 else { return .corrupt }
        guard opcode == 0x0 || opcode == 0x1 || opcode == 0x2
                || opcode == 0x8 || opcode == 0x9 || opcode == 0xA else { return .corrupt }

        let masked = bytes[1] & 0x80 != 0
        let length7 = bytes[1] & 0x7F
        var offset = 2
        let length: Int
        switch length7 {
        case 126:
            guard bytes.count >= offset + 2 else { return .incomplete }
            length = Int(bytes[offset]) << 8 | Int(bytes[offset + 1])
            offset += 2
        case 127:
            guard bytes.count >= offset + 8 else { return .incomplete }
            var value: UInt64 = 0
            for index in 0..<8 { value = value << 8 | UInt64(bytes[offset + index]) }
            guard value <= UInt64(maxFrameBytes) else { return .corrupt }
            length = Int(value)
            offset += 8
        default:
            length = Int(length7)
        }
        guard length <= maxFrameBytes else { return .corrupt }

        var mask: [UInt8] = []
        if masked {
            guard bytes.count >= offset + 4 else { return .incomplete }
            mask = Array(bytes[offset..<offset + 4])
            offset += 4
        }

        guard bytes.count >= offset + length else { return .incomplete }
        var payload = Array(bytes[offset..<offset + length])
        if masked {
            for index in payload.indices { payload[index] ^= mask[index & 3] }
        }
        return .frame(Frame(fin: fin, opcode: opcode, payload: payload), consumed: offset + length)
    }

    /// Re-emit one complete frame. Client→server frames must stay masked or
    /// strict servers (python `websockets` among them) drop the connection.
    private static func encode(opcode: UInt8, payload: [UInt8]) -> Data {
        var output: [UInt8] = [0x80 | opcode]
        switch payload.count {
        case 0..<126:
            output.append(0x80 | UInt8(payload.count))
        case 126...0xFFFF:
            output.append(0x80 | 126)
            output.append(UInt8(payload.count >> 8))
            output.append(UInt8(payload.count & 0xFF))
        default:
            output.append(0x80 | 127)
            let count = UInt64(payload.count)
            for shift in stride(from: 56, through: 0, by: -8) {
                output.append(UInt8(count >> UInt64(shift) & 0xFF))
            }
        }
        let mask: [UInt8] = (0..<4).map { _ in UInt8.random(in: 0...255) }
        output.append(contentsOf: mask)
        output.append(contentsOf: payload.enumerated().map { $0.element ^ mask[$0.offset & 3] })
        return Data(output)
    }

    private static func headerTerminatorEnd(in bytes: [UInt8]) -> Int? {
        guard bytes.count >= 4 else { return nil }
        for index in 0...(bytes.count - 4) {
            if bytes[index] == 0x0D, bytes[index + 1] == 0x0A,
               bytes[index + 2] == 0x0D, bytes[index + 3] == 0x0A {
                return index + 4
            }
        }
        return nil
    }
}

/// The 180° turn itself, applied to one decoded `type:"frame"` JSON payload.
///
/// A 180° rotation about the XR up axis (Y), matching the effect of the
/// server-side `[[0,0,1],[1,0,0],[0,1,0]]` override: position `(x,y,z)`
/// becomes `(-x,y,-z)` and the orientation quaternion `(x,y,z,w)` is
/// pre-multiplied by the 180°-Y quaternion `(0,1,0,0)`, giving `(z,w,-x,-y)`.
/// Anything that does not look exactly like a pose frame is returned
/// byte-for-byte unchanged.
public enum NativePoseFlip {

    public static func rewriteFramePayload(_ payload: [UInt8]) -> [UInt8] {
        guard let data = try? JSONSerialization.jsonObject(with: Data(payload)),
              var root = data as? [String: Any],
              root["type"] as? String == "frame",
              let controllers = root["controllers"] as? [String: Any] else {
            return payload
        }

        var changed = false
        var updated = controllers
        for (hand, value) in controllers {
            guard var controller = value as? [String: Any] else { continue }
            if let position = controller["position"] as? [Any], position.count == 3,
               let x = number(position[0]), let z = number(position[2]) {
                controller["position"] = [-x, position[1], -z]
                changed = true
            }
            if let q = controller["orientation_xyzw"] as? [Any], q.count == 4,
               let x = number(q[0]), let y = number(q[1]),
               let z = number(q[2]), let w = number(q[3]) {
                controller["orientation_xyzw"] = [z, w, -x, -y]
                changed = true
            }
            updated[hand] = controller
        }
        guard changed else { return payload }
        root["controllers"] = updated
        guard let rewritten = try? JSONSerialization.data(withJSONObject: root) else {
            return payload
        }
        return [UInt8](rewritten)
    }

    private static func number(_ value: Any) -> Double? {
        switch value {
        case let number as NSNumber: return number.doubleValue
        default: return nil
        }
    }
}
