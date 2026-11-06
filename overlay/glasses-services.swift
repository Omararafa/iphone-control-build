
// Glasses calls share the serial device queue, including screenshots.
extension DeviceSession {
    func glassesGesture(from: CGPoint, to: CGPoint, duration: UInt64 = 300,
                        before: UInt64 = 0, after: UInt64 = 0, taps: UInt8 = 1) throws {
        func scale(_ v: CGFloat) -> UInt16 { UInt16(max(0, min(1, v)) * 65535) }
        try IdeviceBridge.withTunnelHandles(for: self) { adapter, handshake in
            if let error = probe_glasses_gesture(adapter, handshake, scale(from.x), scale(from.y),
                scale(to.x), scale(to.y), min(duration, 2000), min(before, 2000), min(after, 2000), taps) {
                throw IdeviceBridge.consumeFFIError(error, fallback: "Gesture failed", domain: "glasses")
            }
        }
    }
    func glassesKey(backspace: Bool) throws {
        try IdeviceBridge.withTunnelHandles(for: self) { adapter, handshake in
            if let error = probe_button(adapter, handshake, 0x07, backspace ? 0x2A : 0x28, 60) {
                throw IdeviceBridge.consumeFFIError(error, fallback: "Key failed", domain: "glasses")
            }
        }
    }
}
