//
//  ControlWindowView.swift
//  RealityKitPresenter spike
//
//  The window: open/close the space, the switches, the numbers, the colour-ramp reference
//  and the SharePlay controls.
//

import SwiftUI

struct ControlWindowView: View {
    @Bindable var model: SpikeModel
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                switches
                numbers
                rampReference
                sharePlay
                log
            }
            .padding(24)
        }
        .task {
            model.session.startSessionObserver()
            if model.opensSpaceAtLaunch, !model.spaceOpen {
                await openSpace()
                if model.hidesWindowAtLaunch {
                    dismissWindow(id: "control")
                }
            }
        }
        .onChange(of: model.session.groupImmersionActive) { _, active in
            guard let active else { return }
            Task {
                if active, !model.spaceOpen {
                    await openSpace()
                } else if !active, model.spaceOpen {
                    await dismissImmersiveSpace()
                }
            }
        }
    }

    // MARK: Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("RealityKit Presenter Spike")
                .font(.largeTitle.bold())
            Text("Two LowLevelMesh grids, one per eye, textured by a Metal pass of our own through LowLevelTextures; the material picks the eye with the Camera Index Switch.")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Button(model.spaceOpen ? "Close Space" : "Open Space") {
                    Task {
                        if model.spaceOpen {
                            await dismissImmersiveSpace()
                        } else {
                            await openSpace()
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                Text(model.spaceOpen ? "Space open" : "Space closed")
                    .foregroundStyle(.secondary)
            }
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                GridRow { Text("Route in use").foregroundStyle(.secondary); Text(model.stats.routeInUse) }
                GridRow { Text("Material").foregroundStyle(.secondary); Text(model.stats.materialInUse) }
                GridRow { Text("World tracking").foregroundStyle(.secondary); Text(model.stats.trackingState) }
                GridRow { Text("Textures / grids").foregroundStyle(.secondary); Text("\(model.textureWidth) × \(model.textureHeight) bgra8Unorm_srgb, \(EyeGrid.columns) × \(EyeGrid.rows) vertices per eye") }
            }
            .font(.footnote)
        }
    }

    private var switches: some View {
        GroupBox("Switches") {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Texture route", selection: $model.route) {
                    ForEach(TextureRoute.allCases) { route in
                        Text(route.label).tag(route)
                    }
                }
                .pickerStyle(.segmented)
                if !TextureRoute.allCases.allSatisfy(\.isAvailable) {
                    let missing = TextureRoute.allCases.filter { !$0.isAvailable }.map(\.label).joined(separator: ", ")
                    Text("Not available here: \(missing). The two device-resource routes need visionOS 27; Metal shared textures do not exist in the simulator.")
                        .font(.footnote).foregroundStyle(.secondary)
                }

                HStack {
                    Text("Lead")
                    Slider(value: $model.leadPeriods, in: 0 ... 4, step: 0.25)
                    Text(String(format: "%.2f periods = %.1f ms", model.leadPeriods, model.leadSeconds * 1000))
                        .monospacedDigit()
                        .frame(minWidth: 170, alignment: .trailing)
                }

                Picker("Immersion", selection: $model.fullImmersion) {
                    Text("Mixed").tag(false)
                    Text("Full").tag(true)
                }
                .pickerStyle(.segmented)

                Picker("Test pattern", selection: $model.pattern) {
                    ForEach(PatternMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                Picker("Texture size", selection: $model.textureDivisor) {
                    Text("1920 × 1824 per eye").tag(1)
                    Text("960 × 912 per eye").tag(2)
                }
                .pickerStyle(.segmented)
                Toggle("Update the grids every frame (off: textures only, grids keep their last positions)", isOn: $model.updateGrids)

                Toggle("Cube on the device anchor (+ marker ahead, disc on the scene origin)", isOn: $model.showAnchorMarkers)
                Toggle("Sky is passthrough (alpha 0 under the 0.5 threshold)", isOn: $model.passthroughSky)
                Toggle("View overlays (crosshair, 10° ring, moving bar, ramp, eye marks)", isOn: $model.showOverlays)

                HStack {
                    Text("Head-locked distance")
                    Slider(value: $model.headLockedDistance, in: 0.5 ... 5, step: 0.25)
                    Text(String(format: "%.2f m", model.headLockedDistance)).monospacedDigit().frame(minWidth: 70, alignment: .trailing)
                }
                HStack {
                    Text("Nominal IPD")
                    Slider(value: $model.interpupillaryDistanceMillimetres, in: 54 ... 74, step: 1)
                    Text(String(format: "%.0f mm", model.interpupillaryDistanceMillimetres)).monospacedDigit().frame(minWidth: 70, alignment: .trailing)
                }
            }
            .padding(.top, 6)
        }
    }

    private var numbers: some View {
        let s = model.stats.latest
        return GroupBox("Numbers (last half second)") {
            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 6) {
                row("Frames per second (tickets committed)", String(format: "%.1f", s.ticketsPerSecond))
                row("RealityKit updates per second", String(format: "%.1f", s.updatesPerSecond))
                row("Dropped tickets (render thread busy)", String(format: "%d total, %.1f /s", s.droppedTotal, s.droppedPerSecond))
                row("Lead in use", String(format: "%.1f ms", s.leadMs))
                row("Ticket age at pickup, avg / max", ms(s.pickupAgeAverageMs, s.pickupAgeMaxMs))
                row("Main thread in the replace calls, avg / max", ms(s.replaceAverageMs, s.replaceMaxMs))
                row("    of which the two texture replaces", ms(s.textureReplaceAverageMs, s.textureReplaceMaxMs))
                row("    of which the two grid replaces", ms(s.meshReplaceAverageMs, s.meshReplaceMaxMs))
                row("Render thread encode + commit, avg / max", ms(s.encodeAverageMs, s.encodeMaxMs))
                row("GPU time per ticket, avg / max", ms(s.gpuAverageMs, s.gpuMaxMs))
                row("Commit to GPU completion, avg / max", ms(s.completionLagAverageMs, s.completionLagMaxMs))
                row("Command buffers in flight at commit, max", "\(s.inFlightMax)")
                row("Device anchor: predicted / retried / cached / missing", "\(s.anchorsPredicted) / \(s.anchorsRetried) / \(s.anchorsCached) / \(s.anchorsMissing)")
                row("Tickets since the space opened", "\(s.ticketsTotal)")
            }
            .font(.system(.body, design: .monospaced))
            .padding(.top, 6)
        }
    }

    private var rampReference: some View {
        GroupBox("Colour ramp reference (the same sRGB values the texture shows)") {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 0) {
                    ForEach(0 ..< 14, id: \.self) { i in
                        Rectangle().fill(Self.rampColor(i)).frame(height: 36)
                    }
                }
                Text("Greys 0.0 to 0.9 in steps of 0.1, then red, green, blue, white. Hold the window next to the band at the top of the frame: with the tone map off they should match.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .padding(.top, 6)
        }
    }

    private var sharePlay: some View {
        GroupBox("SharePlay (question 4)") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    Button("Start SharePlay") { model.session.startSharePlay() }
                        .buttonStyle(.borderedProminent)
                    Button("Leave") { model.session.leave() }
                        .disabled(model.session.status == .idle)
                }
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                    GridRow { Text("Status").foregroundStyle(.secondary); Text(model.session.status.label) }
                    GridRow { Text("Participants").foregroundStyle(.secondary); Text("\(model.session.participantCount)") }
                    GridRow { Text("Local participant spatial").foregroundStyle(.secondary); Text(model.session.isSpatial ? "yes" : "no") }
                    GridRow { Text("Group immersion style").foregroundStyle(.secondary); Text(model.session.groupImmersionStyleName) }
                }
                .font(.footnote)
                Text(model.session.statusMessage)
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .padding(.top, 6)
        }
    }

    private var log: some View {
        GroupBox("Log") {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(model.stats.messages.enumerated()), id: \.offset) { _, line in
                    Text(line)
                }
            }
            .font(.system(size: 11, design: .monospaced))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 6)
        }
    }

    // MARK: Helpers

    private func openSpace() async {
        switch await openImmersiveSpace(id: "presenter") {
        case .opened:
            break
        case .userCancelled:
            model.stats.log("Opening the space was cancelled")
        case .error:
            model.stats.log("Opening the space failed")
        @unknown default:
            break
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).monospacedDigit()
        }
    }

    private func ms(_ average: Double, _ maximum: Double) -> String {
        String(format: "%.2f / %.2f ms", average, maximum)
    }

    static func rampColor(_ i: Int) -> Color {
        switch i {
        case 0 ..< 10:
            let g = Double(i) * 0.1
            return Color(.sRGB, red: g, green: g, blue: g, opacity: 1)
        case 10: return Color(.sRGB, red: 1, green: 0, blue: 0, opacity: 1)
        case 11: return Color(.sRGB, red: 0, green: 1, blue: 0, opacity: 1)
        case 12: return Color(.sRGB, red: 0, green: 0, blue: 1, opacity: 1)
        default: return Color(.sRGB, red: 1, green: 1, blue: 1, opacity: 1)
        }
    }
}
