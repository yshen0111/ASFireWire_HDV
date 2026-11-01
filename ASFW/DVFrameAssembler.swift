import Foundation

struct DVFrameAssemblyResult: Sendable {
    var completedFrame: Data?
    var droppedFrame = false
    var duplicateBlocks = 0
    var invalidBlocks = 0
}

/// Reassembles SD-DV DIF blocks by their on-wire identifiers. The placement
/// follows the behavioral mapping in libiec61883's DV frame receiver; a bitmap
/// additionally prevents a duplicate block from hiding a missing block.
struct DVFrameAssembler {
    static let sourcePacketBytes = 480
    static let difBlockBytes = 80
    static let blocksPerSequence = 150

    private(set) var isPAL: Bool?
    private var frame = Data()
    private var received: [Bool] = []
    private var receivedCount = 0
    private var active = false

    mutating func reset() {
        isPAL = nil
        frame.removeAll(keepingCapacity: false)
        received.removeAll(keepingCapacity: false)
        receivedCount = 0
        active = false
    }

    mutating func ingest(_ chunk: UnsafeRawBufferPointer) -> DVFrameAssemblyResult {
        var result = DVFrameAssemblyResult()
        guard chunk.count == Self.sourcePacketBytes else {
            result.invalidBlocks = 1
            return result
        }

        if isFrameStart(chunk) {
            result = finishCurrentFrame()
            let pal = (chunk[3] & 0x80) != 0
            beginFrame(pal: pal)
        }

        guard active else { return result }

        for offset in stride(from: 0,
                             to: Self.sourcePacketBytes,
                             by: Self.difBlockBytes) {
            guard let index = frameBlockIndex(chunk: chunk, offset: offset),
                  index < received.count else {
                result.invalidBlocks += 1
                continue
            }

            if received[index] {
                result.duplicateBlocks += 1
                continue
            }

            let destination = index * Self.difBlockBytes
            frame.replaceSubrange(destination..<(destination + Self.difBlockBytes),
                                  with: chunk[offset..<(offset + Self.difBlockBytes)])
            received[index] = true
            receivedCount += 1
        }

        return result
    }

    mutating func finish() -> DVFrameAssemblyResult {
        let result = finishCurrentFrame()
        reset()
        return result
    }

    private mutating func beginFrame(pal: Bool) {
        isPAL = pal
        let sequences = pal ? 12 : 10
        let blockCount = sequences * Self.blocksPerSequence
        frame = Data(repeating: 0,
                     count: blockCount * Self.difBlockBytes)
        received = [Bool](repeating: false, count: blockCount)
        receivedCount = 0
        active = true
    }

    private mutating func finishCurrentFrame() -> DVFrameAssemblyResult {
        guard active else { return DVFrameAssemblyResult() }
        let complete = receivedCount == received.count &&
                       received.allSatisfy { $0 }
        let result = DVFrameAssemblyResult(
            completedFrame: complete ? frame : nil,
            droppedFrame: !complete)
        active = false
        return result
    }

    private func isFrameStart(_ chunk: UnsafeRawBufferPointer) -> Bool {
        guard chunk.count >= 4 else { return false }
        return (chunk[0] >> 5) == 0 &&
               (chunk[1] >> 4) == 0 &&
               chunk[2] == 0
    }

    private func frameBlockIndex(chunk: UnsafeRawBufferPointer,
                                 offset: Int) -> Int? {
        let section = Int(chunk[offset] >> 5)
        let sequence = Int(chunk[offset + 1] >> 4)
        let block = Int(chunk[offset + 2])
        let sequenceCount = isPAL == true ? 12 : 10
        guard sequence < sequenceCount else { return nil }

        let withinSequence: Int
        switch section {
        case 0 where block == 0:
            withinSequence = 0
        case 1 where block < 2:
            withinSequence = 1 + block
        case 2 where block < 3:
            withinSequence = 3 + block
        case 3 where block < 9:
            withinSequence = 6 + block * 16
        case 4 where block < 135:
            withinSequence = 7 + (block / 15) + block
        default:
            return nil
        }

        guard withinSequence < Self.blocksPerSequence else { return nil }
        return sequence * Self.blocksPerSequence + withinSequence
    }
}

/// Finds tape dropouts in an HDV capture (MPEG-2 transport stream,
/// ISO/IEC 13818-1). The camcorder skips what it cannot read from tape and
/// keeps sending, so a dropout shows only inside the stream: the continuity
/// counter of every PID jumps at the same point. On an HVR-Z1U a 0.6 s
/// dropout broke all seven PIDs within 41 packets, so breaks closer together
/// than `mergeWindowPackets` are one dropout. Whether a recording start/stop
/// point on the tape also breaks the counters has not been checked.
struct TransportStreamDropoutDetector {
    static let packetBytes = 188
    static let syncByte: UInt8 = 0x47
    static let nullPID: UInt16 = 0x1FFF
    /// About 0.25 s of 25 Mbit/s HDV.
    static let mergeWindowPackets = 4096
    /// A larger PCR step (or a backward one) is not playback time, so the
    /// stream clock does not advance across it.
    static let maxPCRStepSeconds = 2.0

    private var continuity: [UInt16: UInt8] = [:]
    private var pcrPID: UInt16?
    private var lastPCRSeconds: Double?
    private var streamSeconds = 0.0
    private var packetIndex = 0
    private var lastBreakPacket: Int?

    mutating func reset() {
        self = TransportStreamDropoutDetector()
    }

    /// Returns the stream time in seconds (from the PCR, counted from the
    /// first PCR seen) when this packet starts a new dropout.
    mutating func ingest(_ packet: UnsafeRawBufferPointer) -> Double? {
        defer { packetIndex += 1 }
        guard packet.count == Self.packetBytes, packet[0] == Self.syncByte else {
            return nil
        }

        let pid = UInt16(packet[1] & 0x1F) << 8 | UInt16(packet[2])
        let hasAdaptationField = packet[3] & 0x20 != 0
        let hasPayload = packet[3] & 0x10 != 0
        let counter = packet[3] & 0x0F

        if hasAdaptationField {
            readPCR(packet, pid: pid)
        }

        // The counter only advances on packets with a payload; one repeat of
        // a packet (same counter) is allowed. ISO/IEC 13818-1 2.4.3.3.
        guard hasPayload, pid != Self.nullPID,
              let previous = continuity.updateValue(counter, forKey: pid),
              counter != (previous &+ 1) & 0x0F,
              counter != previous else {
            return nil
        }

        defer { lastBreakPacket = packetIndex }
        if let lastBreakPacket,
           packetIndex - lastBreakPacket <= Self.mergeWindowPackets {
            return nil
        }
        return streamSeconds
    }

    private mutating func readPCR(_ packet: UnsafeRawBufferPointer, pid: UInt16) {
        // Adaptation field: length at byte 4, flags at 5 (0x10 = PCR present),
        // then the 33-bit PCR base in 90 kHz units. The 27 MHz extension adds
        // under a millisecond and is ignored.
        guard packet[4] >= 7, packet[5] & 0x10 != 0 else { return }
        if pcrPID == nil { pcrPID = pid }
        guard pid == pcrPID else { return }

        let base = UInt64(packet[6]) << 25 | UInt64(packet[7]) << 17 |
                   UInt64(packet[8]) << 9 | UInt64(packet[9]) << 1 |
                   UInt64(packet[10] >> 7)
        let seconds = Double(base) / 90_000
        if let lastPCRSeconds {
            let step = seconds - lastPCRSeconds
            if step >= 0, step <= Self.maxPCRStepSeconds {
                streamSeconds += step
            }
        }
        lastPCRSeconds = seconds
    }
}
