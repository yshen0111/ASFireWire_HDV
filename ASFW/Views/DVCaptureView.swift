//
//  DVCaptureView.swift
//  ASFW
//
//  Capture DV or HDV video from a tape camcorder to a raw file.
//
//  Flow: AV/C tape transport (PLAY) via raw FCP → driver receives the isoch
//  stream, detects DV or MPEG-2 TS (HDV) and fills the shared ring → this view
//  drains the ring and writes the stream. DV is reassembled into whole frames
//  for a .dv file (QuickTime, iMovie, FFmpeg, DaVinci Resolve, etc.). HDV is
//  written as a 188-byte-packet MPEG-2 transport stream for a .m2t file (VLC,
//  FFmpeg, DaVinci Resolve, etc.).
//

import SwiftUI
import AppKit
import Combine

// MARK: - Capture Controller

@MainActor
final class DVCaptureController: ObservableObject {
    @Published var isCapturing = false
    @Published var bytesWritten: UInt64 = 0
    @Published var framesSeen: Int = 0
    @Published var transportStreamPackets: Int = 0
    @Published var droppedFrames: Int = 0
    @Published var duplicateBlocks: Int = 0
    @Published var invalidBlocks: Int = 0
    @Published var stats = DVCaptureStats()
    @Published var systemLabel = "—"
    @Published var lastError: String?
    @Published var outputFileName: String?
    /// Stream time (seconds) of each HDV tape dropout.
    @Published var tapeDropouts: [Double] = []

    private var ring: DVCaptureRing?
    private var fileWriter: DVFileWriter?
    private var captureTask: Task<Void, Never>?
    private var assembler = DVFrameAssembler()
    private var dropoutDetector = TransportStreamDropoutDetector()
    private var accountedBusLoss: UInt64 = 0
    /// Drains left in which a break is put down to a new bus loss.
    private var busLossDrainsLeft = 0
    private var outputFolder: URL?
    private var captureStarted = Date()

    func start(connector: ASFWDriverConnector,
               deviceGUID: UInt64,
               folder: URL) {
        guard !isCapturing else { return }
        lastError = nil

        guard connector.startDVCapture(deviceGUID: deviceGUID) else {
            lastError = connector.lastError ?? "startDVCapture failed (is audio receive running?)"
            return
        }

        guard let mappedRing = connector.mapDVCaptureRing() else {
            lastError = "Failed to map DV ring"
            _ = connector.stopDVCapture()
            return
        }

        // The file is created once the driver reports DV or HDV, so its
        // extension matches the stream (see openFileIfNeeded).
        outputFolder = folder
        captureStarted = Date()
        outputFileName = nil
        ring = mappedRing
        bytesWritten = 0
        framesSeen = 0
        transportStreamPackets = 0
        tapeDropouts = []
        droppedFrames = 0
        duplicateBlocks = 0
        invalidBlocks = 0
        assembler.reset()
        dropoutDetector.reset()
        accountedBusLoss = 0
        busLossDrainsLeft = 0
        systemLabel = "—"
        isCapturing = true

        captureTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.tick(connector: connector)
                try? await Task.sleep(nanoseconds: 33_000_000) // ~30 Hz
            }
        }
    }

    func stop(connector: ASFWDriverConnector) async {
        guard isCapturing else { return }

        captureTask?.cancel()
        captureTask = nil

        // Stop the driver before the final drain, so nothing is published
        // after it; draining first lost the last ~0.01 s of HDV. The ring
        // stays readable because this mapping holds its own reference.
        let driverStopped = connector.stopDVCapture()
        await tick(connector: connector)
        await apply(assembler.finish(), connector: connector)
        if fileWriter == nil, lastError == nil {
            lastError = "No video arrived, so no file was written. Start capture, then press Play."
        }
        await shutdown(connector: connector, stopDriver: !driverStopped)
    }

    func reportError(_ message: String) {
        lastError = message
    }

    private func tick(connector: ASFWDriverConnector) async {
        guard let ring else { return }

        // Nothing is published before the driver locks the format.
        let format = ring.streamFormat
        if format != .unknown, !openFileIfNeeded(for: format) {
            await shutdown(connector: connector)
            return
        }
        switch format {
        case .mpegTS:
            await drainTransportStream(ring, connector: connector)
        case .dv:
            await drainDV(ring, connector: connector)
        case .unknown:
            break
        }
        stats = ring.stats
        if DVCaptureSessionState(rawValue: stats.sessionState) == .busReset {
            lastError = "Capture stopped because the FireWire bus reset. Select the camcorder again and restart capture."
            await shutdown(connector: connector)
        }
    }

    // The chosen folder is granted as a whole by the sandbox, so the file can
    // be named here, e.g. capture-2026-11-01-135615.m2t. An existing file is
    // never overwritten; a numeric suffix is added instead.
    private func openFileIfNeeded(for format: DVStreamFormat) -> Bool {
        guard fileWriter == nil else { return true }
        guard let outputFolder else { return false }

        let stamp = Self.fileStampFormatter.string(from: captureStarted)
        let ext = format == .mpegTS ? "m2t" : "dv"
        var url = outputFolder.appendingPathComponent("capture-\(stamp).\(ext)")
        var suffix = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = outputFolder.appendingPathComponent("capture-\(stamp)-\(suffix).\(ext)")
            suffix += 1
        }

        do {
            fileWriter = try DVFileWriter(url: url)
            outputFileName = url.lastPathComponent
            return true
        } catch {
            lastError = "Could not create \(url.lastPathComponent): \(error.localizedDescription)"
            return false
        }
    }

    private static let fileStampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter
    }()

    private func drainDV(_ ring: DVCaptureRing,
                         connector: ASFWDriverConnector) async {
        var completedFrames: [Data] = []
        var dropped = 0
        var duplicates = 0
        var invalid = 0
        ring.drain { chunk in
            let result = assembler.ingest(chunk)
            if let frame = result.completedFrame { completedFrames.append(frame) }
            if result.droppedFrame { dropped += 1 }
            duplicates += result.duplicateBlocks
            invalid += result.invalidBlocks
        }

        droppedFrames += dropped
        duplicateBlocks += duplicates
        invalidBlocks += invalid
        if systemLabel == "—", let isPAL = assembler.isPAL {
            systemLabel = isPAL ? "DV PAL (625/50)" : "DV NTSC (525/60)"
        }
        if !completedFrames.isEmpty,
           await write(completedFrames, connector: connector) {
            framesSeen += completedFrames.count
        }
    }

    // HDV: the driver has already checked each 188-byte packet's sync byte;
    // they are written back to back as an MPEG-2 transport stream.
    private func drainTransportStream(_ ring: DVCaptureRing,
                                      connector: ASFWDriverConnector) async {
        var stream = Data()
        var packets = 0
        var breaks: [Double] = []
        ring.drain { chunk in
            guard let bytes = chunk.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return
            }
            stream.append(bytes, count: chunk.count)
            packets += 1
            if let seconds = dropoutDetector.ingest(chunk) {
                breaks.append(seconds)
            }
        }

        // Packets lost on the bus or in the ring also break the stream; those
        // are counted by the driver, so the next break after a new loss is
        // not a tape dropout. The driver counts a loss before it publishes
        // the packets after it, but this drain may stop short of them, so the
        // loss also covers the next drain.
        let latest = ring.stats
        let busLoss = UInt64(latest.dbcDiscontinuities) +
                      UInt64(latest.droppedFragments) +
                      UInt64(latest.overruns) +
                      UInt64(latest.invalidSourcePackets)
        if busLoss > accountedBusLoss {
            accountedBusLoss = busLoss
            busLossDrainsLeft = 2
        }
        for seconds in breaks {
            if busLossDrainsLeft > 0 {
                busLossDrainsLeft = 0
            } else {
                tapeDropouts.append(seconds)
            }
        }
        if packets > 0, busLossDrainsLeft > 0 {
            busLossDrainsLeft -= 1
        }

        systemLabel = "HDV (MPEG-2 TS)"
        if packets > 0, await write([stream], connector: connector) {
            transportStreamPackets += packets
        }
    }

    private func apply(_ result: DVFrameAssemblyResult,
                       connector: ASFWDriverConnector) async {
        if result.droppedFrame { droppedFrames += 1 }
        duplicateBlocks += result.duplicateBlocks
        invalidBlocks += result.invalidBlocks
        if let frame = result.completedFrame,
           await write([frame], connector: connector) {
            framesSeen += 1
        }
    }

    private func write(_ chunks: [Data],
                       connector: ASFWDriverConnector) async -> Bool {
        guard let fileWriter else { return false }
        do {
            bytesWritten += try await fileWriter.write(chunks)
            return true
        } catch {
            lastError = "Capture file write failed: \(error.localizedDescription)"
            await shutdown(connector: connector)
            return false
        }
    }

    private func shutdown(connector: ASFWDriverConnector,
                          stopDriver: Bool = true) async {
        captureTask?.cancel()
        captureTask = nil
        if stopDriver {
            _ = connector.stopDVCapture()
        }
        ring?.unmap()
        ring = nil
        if let fileWriter {
            do {
                try await fileWriter.close()
            } catch where lastError == nil {
                lastError = "Could not finalize DV file: \(error.localizedDescription)"
            } catch { }
        }
        self.fileWriter = nil
        isCapturing = false
    }
}

// MARK: - View

struct DVCaptureView: View {
    @ObservedObject var viewModel: DebugViewModel
    @StateObject private var controller = DVCaptureController()

    @State private var avcUnits: [ASFWDriverConnector.AVCUnitInfo] = []
    @State private var selectedUnitGUID: UInt64?
    @State private var outputFolder: URL?
    @State private var transportBusy = false
    @State private var transportStatus: String?

    var body: some View {
        Form {
            statusSection
            camcorderSection
            captureSection
        }
        .formStyle(.grouped)
        .navigationTitle("DV / HDV Capture")
        .onAppear { refreshUnits() }
        .onDisappear {
            Task { await controller.stop(connector: viewModel.connector) }
        }
    }

    // MARK: Sections

    private var statusSection: some View {
        Section("Status") {
            if viewModel.isConnected {
                Label("Connected to driver", systemImage: "checkmark.circle.fill")
                    .foregroundColor(.green)
            } else {
                Label("Driver not connected", systemImage: "xmark.circle.fill")
                    .foregroundColor(.red)
            }
            if let error = controller.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundColor(.red)
            }
        }
    }

    private var camcorderSection: some View {
        Section("Camcorder Transport (AV/C Tape Subunit)") {
            if avcUnits.isEmpty {
                HStack {
                    Text("No AV/C units found")
                        .foregroundColor(.secondary)
                    Button("Refresh") { refreshUnits() }
                }
            } else {
                Picker("Unit", selection: $selectedUnitGUID) {
                    ForEach(avcUnits) { unit in
                        Text("GUID: \(unit.guidHex) (Node: \(unit.nodeIDHex))")
                            .tag(unit.guid as UInt64?)
                    }
                }
            }

            HStack(spacing: 12) {
                Button {
                    sendTransport(opcode: 0xC4, operand: 0x65, label: "Rewind")
                } label: {
                    Label("Rewind", systemImage: "backward.fill")
                }

                Button {
                    sendTransport(opcode: 0xC3, operand: 0x75, label: "Play")
                } label: {
                    Label("Play", systemImage: "play.fill")
                }

                Button {
                    sendTransport(opcode: 0xC4, operand: 0x60, label: "Stop")
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
            }
            .disabled(transportBusy || selectedUnitGUID == nil || !viewModel.isConnected)

            if let status = transportStatus {
                Text(status)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    private var captureSection: some View {
        Section("Capture") {
            HStack {
                Button("Choose Output Folder…") { chooseOutputFolder() }
                    .disabled(controller.isCapturing)
                Text(outputFolder?.lastPathComponent ?? "No folder selected")
                    .foregroundColor(.secondary)
            }
            Text("Each capture gets its own file, named .dv or .m2t to match what the camcorder sends.")
                .font(.caption)
                .foregroundColor(.secondary)
            if let name = controller.outputFileName {
                LabeledContent("File", value: name)
            }

            if controller.isCapturing {
                Button {
                    Task { await controller.stop(connector: viewModel.connector) }
                } label: {
                    Label("Stop Capture", systemImage: "stop.circle.fill")
                }
                .tint(.red)
            } else {
                Button {
                    startCapture()
                } label: {
                    Label("Start Capture", systemImage: "record.circle")
                }
                .disabled(!viewModel.isConnected || outputFolder == nil || selectedUnitGUID == nil)
            }

            captureStats
        }
    }

    private var captureStats: some View {
        Group {
            LabeledContent("System", value: controller.systemLabel)
            LabeledContent("Isoch channel",
                           value: controller.stats.channel <= 63
                               ? "\(controller.stats.channel)"
                               : "—")
            LabeledContent("Connection",
                           value: connectionModeLabel(controller.stats.connectionMode))
            if controller.stats.streamFormat == .mpegTS {
                LabeledContent("TS packets", value: "\(controller.transportStreamPackets)")
                LabeledContent("Tape dropouts", value: dropoutSummary)
                    .foregroundColor(controller.tapeDropouts.isEmpty ? .primary : .orange)
                    .help("Places where the camcorder skipped part of the tape it could not read, timed from the start of the capture. Packets lost on the FireWire bus are counted separately.")
            } else {
                LabeledContent("Frames", value: "\(controller.framesSeen)")
                LabeledContent("Dropped frames", value: "\(controller.droppedFrames)")
                    .foregroundColor(controller.droppedFrames > 0 ? .orange : .primary)
            }
            LabeledContent("Written", value: formatBytes(controller.bytesWritten))
            LabeledContent("Isoch packets seen", value: "\(controller.stats.packetsSeen)")
            LabeledContent("Source packets", value: "\(controller.stats.sourcePackets)")
            LabeledContent("Rejected packets", value: "\(controller.stats.rejectedPackets)")
            LabeledContent("Ring overruns", value: "\(controller.stats.overruns)")
                .foregroundColor(controller.stats.overruns > 0 ? .orange : .primary)
            LabeledContent("DBC discontinuities", value: "\(controller.stats.dbcDiscontinuities)")
            if controller.stats.streamFormat == .mpegTS {
                LabeledContent("Bad TS sync bytes",
                               value: "\(controller.stats.invalidSourcePackets)")
                LabeledContent("Dropped TS fragments",
                               value: "\(controller.stats.droppedFragments)")
            } else {
                LabeledContent("Invalid DIF chunks",
                               value: "\(controller.stats.invalidSourcePackets)")
                LabeledContent("Duplicate DIF blocks", value: "\(controller.duplicateBlocks)")
            }
            if controller.stats.rejectedPackets > 0 {
                LabeledContent("Last rejected",
                               value: String(format: "len=%u q0=%08X q1=%08X",
                                             controller.stats.lastRejectLen,
                                             controller.stats.lastRejectQ0,
                                             controller.stats.lastRejectQ1))
                    .foregroundColor(.orange)
                LabeledContent("Last xferStatus",
                               value: String(format: "%04X (evt=0x%02X)",
                                             controller.stats.lastXferStatus,
                                             controller.stats.lastXferStatus & 0x1F))
                    .foregroundColor(.orange)
            }
        }
        .font(.callout)
    }

    // MARK: Actions

    private func refreshUnits() {
        guard viewModel.isConnected else { return }

        DispatchQueue.global(qos: .userInitiated).async {
            let units = (viewModel.connector.getAVCUnits() ?? []).sorted {
                let lhsTape = $0.subunits.contains { $0.type == 0x04 }
                let rhsTape = $1.subunits.contains { $0.type == 0x04 }
                return lhsTape && !rhsTape
            }
            DispatchQueue.main.async {
                self.avcUnits = units
                if !units.contains(where: { $0.guid == self.selectedUnitGUID }) {
                    self.selectedUnitGUID = units.first?.guid
                }
            }
        }
    }

    private func sendTransport(opcode: UInt8, operand: UInt8, label: String) {
        guard let guid = selectedUnitGUID else { return }

        // CONTROL, tape subunit (type 0x04, id 0), opcode, operand.
        // Exactly 4 bytes - transport opcodes take a single operand and some
        // camcorders reject frames with extra padding operands.
        let frame = Data([0x00, 0x20, opcode, operand])

        transportBusy = true
        transportStatus = "Sending \(label)…"

        DispatchQueue.global(qos: .userInitiated).async {
            let response = viewModel.connector.sendRawFCPCommand(guid: guid, frame: frame)
            DispatchQueue.main.async {
                self.transportBusy = false
                if let response, response.count >= 1 {
                    let code = response[0]
                    // AV/C response codes: 0x09 ACCEPTED, 0x08 NOT IMPLEMENTED, 0x0A REJECTED
                    let codeLabel: String
                    switch code {
                    case 0x09: codeLabel = "ACCEPTED"
                    case 0x0A: codeLabel = "REJECTED"
                    case 0x08: codeLabel = "NOT IMPLEMENTED"
                    case 0x0C: codeLabel = "IMPLEMENTED/STABLE"
                    default: codeLabel = String(format: "0x%02X", code)
                    }
                    self.transportStatus = "\(label): \(codeLabel)"
                } else {
                    // Timeout is common (some camcorders act on the command but
                    // the response path misses it) - check if the tape moved.
                    self.transportStatus = "\(label): no FCP response (command may still have worked)"
                }
            }
        }
    }

    private func chooseOutputFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Choose a folder for captures. Files are named automatically."
        if panel.runModal() == .OK {
            outputFolder = panel.url
        }
    }

    private func startCapture() {
        guard let folder = outputFolder, let guid = selectedUnitGUID else { return }
        controller.start(connector: viewModel.connector,
                         deviceGUID: guid,
                         folder: folder)
    }

    private func connectionModeLabel(_ rawValue: UInt8) -> String {
        switch rawValue {
        case 1: return "Broadcast"
        case 2: return "CMP overlay"
        case 3: return "CMP point-to-point"
        case 4: return "Broadcast fallback"
        default: return "—"
        }
    }

    private var dropoutSummary: String {
        let dropouts = controller.tapeDropouts
        guard !dropouts.isEmpty else { return "0" }
        let shown = dropouts.prefix(5).map(formatStreamTime).joined(separator: ", ")
        let more = dropouts.count > 5 ? ", …" : ""
        return "\(dropouts.count) (at \(shown)\(more))"
    }

    private func formatStreamTime(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let (hours, minutes, secs) = (total / 3600, total / 60 % 60, total % 60)
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }

    private func formatBytes(_ bytes: UInt64) -> String {
        if bytes < 1_000_000 {
            return String(format: "%.0f KB", Double(bytes) / 1000)
        }
        return String(format: "%.1f MB", Double(bytes) / 1_000_000)
    }
}
