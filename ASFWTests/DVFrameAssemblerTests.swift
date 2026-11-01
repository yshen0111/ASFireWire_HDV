import Foundation
import Testing
@testable import ASFW

struct DVFrameAssemblerTests {
    private func makeFrame(pal: Bool, marker: UInt8) -> Data {
        let sequences = pal ? 12 : 10
        var frame = Data(repeating: marker,
                         count: sequences * 150 * 80)

        for sequence in 0..<sequences {
            func setID(_ position: Int, section: UInt8, block: UInt8) {
                let offset = (sequence * 150 + position) * 80
                frame[offset] = section << 5
                frame[offset + 1] = UInt8(sequence << 4)
                frame[offset + 2] = block
            }

            setID(0, section: 0, block: 0)
            for block in 0..<2 {
                setID(1 + block, section: 1, block: UInt8(block))
            }
            for block in 0..<3 {
                setID(3 + block, section: 2, block: UInt8(block))
            }
            for block in 0..<9 {
                setID(6 + block * 16, section: 3, block: UInt8(block))
            }
            for block in 0..<135 {
                setID(7 + (block / 15) + block,
                      section: 4,
                      block: UInt8(block))
            }
        }
        frame[3] = pal ? 0x80 : 0x00
        return frame
    }

    private func ingest(_ data: Data,
                        into assembler: inout DVFrameAssembler)
        -> DVFrameAssemblyResult {
        data.withUnsafeBytes { assembler.ingest($0) }
    }

    @Test func reassemblesNTSCFrameByDifIdentity() {
        let frame = makeFrame(pal: false, marker: 0xA5)
        let next = makeFrame(pal: false, marker: 0x5A)
        var assembler = DVFrameAssembler()

        for offset in stride(from: 0, to: frame.count, by: 480) {
            _ = ingest(frame.subdata(in: offset..<(offset + 480)),
                       into: &assembler)
        }
        let result = ingest(next.subdata(in: 0..<480), into: &assembler)

        #expect(result.droppedFrame == false)
        #expect(result.completedFrame == frame)
        #expect(assembler.isPAL == false)
    }

    @Test func reassemblesPALFrameWhenPacketsArriveOutOfOrder() {
        let frame = makeFrame(pal: true, marker: 0x3C)
        let next = makeFrame(pal: true, marker: 0xC3)
        var packets: [Data] = []
        for offset in stride(from: 0, to: frame.count, by: 480) {
            packets.append(frame.subdata(in: offset..<(offset + 480)))
        }
        packets.swapAt(10, 11)

        var assembler = DVFrameAssembler()
        for packet in packets {
            _ = ingest(packet, into: &assembler)
        }
        let result = ingest(next.subdata(in: 0..<480), into: &assembler)

        #expect(result.completedFrame == frame)
        #expect(assembler.isPAL == true)
    }

    @Test func duplicateCannotHideMissingPacket() {
        let frame = makeFrame(pal: false, marker: 0x11)
        let next = makeFrame(pal: false, marker: 0x22)
        var packets: [Data] = []
        for offset in stride(from: 0, to: frame.count, by: 480) {
            packets.append(frame.subdata(in: offset..<(offset + 480)))
        }

        var assembler = DVFrameAssembler()
        for (index, packet) in packets.enumerated() where index != 12 {
            _ = ingest(packet, into: &assembler)
            if index == 13 {
                let duplicate = ingest(packet, into: &assembler)
                #expect(duplicate.duplicateBlocks == 6)
            }
        }
        let result = ingest(next.subdata(in: 0..<480), into: &assembler)

        #expect(result.completedFrame == nil)
        #expect(result.droppedFrame)
    }
}

struct TransportStreamDropoutDetectorTests {
    // PIDs and PCR PID taken from an HVR-Z1U HDV capture.
    private let videoPID: UInt16 = 0x810
    private let audioPID: UInt16 = 0x814
    private let pcrPID: UInt16 = 0x134

    private func makePacket(pid: UInt16,
                            counter: UInt8,
                            payload: Bool = true,
                            pcrSeconds: Double? = nil) -> Data {
        var packet = Data(repeating: 0xFF, count: 188)
        packet[0] = 0x47
        packet[1] = UInt8(pid >> 8) & 0x1F
        packet[2] = UInt8(pid & 0xFF)
        let adaptation: UInt8 = pcrSeconds == nil ? 0 : 0x20
        packet[3] = adaptation | (payload ? 0x10 : 0) | (counter & 0x0F)
        if let pcrSeconds {
            let base = UInt64((pcrSeconds * 90_000).rounded())
            packet[4] = payload ? 7 : 183
            packet[5] = 0x10
            packet[6] = UInt8(truncatingIfNeeded: base >> 25)
            packet[7] = UInt8(truncatingIfNeeded: base >> 17)
            packet[8] = UInt8(truncatingIfNeeded: base >> 9)
            packet[9] = UInt8(truncatingIfNeeded: base >> 1)
            packet[10] = UInt8(truncatingIfNeeded: base << 7) | 0x7E
            packet[11] = 0
        }
        return packet
    }

    private func ingest(_ packet: Data,
                        into detector: inout TransportStreamDropoutDetector) -> Double? {
        packet.withUnsafeBytes { detector.ingest($0) }
    }

    @Test func continuousStreamHasNoDropouts() {
        var detector = TransportStreamDropoutDetector()
        var found: [Double] = []
        for step in 0..<40 {
            let counter = UInt8(step & 0x0F)
            for packet in [makePacket(pid: videoPID, counter: counter),
                           makePacket(pid: audioPID, counter: counter)] {
                if let seconds = ingest(packet, into: &detector) { found.append(seconds) }
            }
        }
        // One repeated packet is allowed, as are packets without a payload
        // (their counter does not advance) and null packets.
        let extras = [makePacket(pid: videoPID, counter: 7),
                      makePacket(pid: videoPID, counter: 3, payload: false),
                      makePacket(pid: videoPID, counter: 8),
                      makePacket(pid: 0x1FFF, counter: 9),
                      makePacket(pid: 0x1FFF, counter: 2)]
        for packet in extras {
            if let seconds = ingest(packet, into: &detector) { found.append(seconds) }
        }
        #expect(found.isEmpty)
    }

    @Test func breakOnEveryPIDCountsAsOneDropoutAtItsStreamTime() {
        var detector = TransportStreamDropoutDetector()
        var found: [Double] = []
        func feed(_ packet: Data) {
            if let seconds = ingest(packet, into: &detector) { found.append(seconds) }
        }

        feed(makePacket(pid: pcrPID, counter: 0, pcrSeconds: 1000.0))
        feed(makePacket(pid: videoPID, counter: 0))
        feed(makePacket(pid: audioPID, counter: 0))
        feed(makePacket(pid: pcrPID, counter: 1, pcrSeconds: 1001.5))
        // The camcorder skips 0.6 s of tape: every PID's counter jumps and
        // the PCR moves ahead by the skipped time.
        feed(makePacket(pid: videoPID, counter: 8))
        feed(makePacket(pid: pcrPID, counter: 9, pcrSeconds: 1002.1))
        feed(makePacket(pid: audioPID, counter: 14))

        #expect(found.count == 1)
        #expect(abs((found.first ?? 0) - 1.5) < 0.001)
    }

    @Test func dropoutsFarApartCountSeparately() {
        var detector = TransportStreamDropoutDetector()
        var found = 0
        var counter: UInt8 = 0
        func feedVideo(jump: Bool = false) {
            counter = (counter &+ (jump ? 5 : 1)) & 0x0F
            if ingest(makePacket(pid: videoPID, counter: counter), into: &detector) != nil {
                found += 1
            }
        }

        feedVideo()
        feedVideo(jump: true)
        for _ in 0..<TransportStreamDropoutDetector.mergeWindowPackets {
            feedVideo()
        }
        feedVideo(jump: true)
        #expect(found == 2)
    }

    @Test func streamTimeIgnoresBackwardAndLargePCRSteps() {
        var detector = TransportStreamDropoutDetector()
        var found: [Double] = []
        func feed(_ packet: Data) {
            if let seconds = ingest(packet, into: &detector) { found.append(seconds) }
        }

        feed(makePacket(pid: pcrPID, counter: 0, pcrSeconds: 50.0))
        feed(makePacket(pid: pcrPID, counter: 1, pcrSeconds: 51.0))
        feed(makePacket(pid: pcrPID, counter: 2, pcrSeconds: 10.0))   // backward
        feed(makePacket(pid: pcrPID, counter: 3, pcrSeconds: 10.5))
        feed(makePacket(pid: pcrPID, counter: 4, pcrSeconds: 500.0))  // far ahead
        feed(makePacket(pid: pcrPID, counter: 5, pcrSeconds: 501.0))
        feed(makePacket(pid: videoPID, counter: 0))
        feed(makePacket(pid: videoPID, counter: 6))

        #expect(found.count == 1)
        #expect(abs((found.first ?? 0) - 2.5) < 0.001)
    }
}
