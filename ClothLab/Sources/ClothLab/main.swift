//
//  main.swift
//  ClothLab
//
// Copyright (C) Untold Engine Studios
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import simd

// Unbuffered, so a script following the output sees every line at once.
setvbuf(stdout, nil, _IONBF, 0)

// `-headless <seconds>`: the solver alone, no window, one line of figures
// every half second of simulated time. For finding a fault in the solver;
// it says nothing about how the cloth looks.
if let index = CommandLine.arguments.firstIndex(of: "-headless"), index + 1 < CommandLine.arguments.count,
   let seconds = Float(CommandLine.arguments[index + 1])
{
    runHeadless(seconds: seconds, arguments: CommandLine.arguments)
    exit(0)
}

// Top-level code runs on the main thread.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}

func runHeadless(seconds: Float, arguments: [String]) {
    func value(_ flag: String) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }
    var parameters = ClothSolver.Parameters()
    if let raw = value("-substeps"), let n = Int(raw) { parameters.substeps = n }
    if let raw = value("-stretch"), let c = Float(raw) { parameters.stretchCompliance = c }
    if let raw = value("-bend"), let c = Float(raw) { parameters.bendCompliance = c }
    if let raw = value("-damping"), let c = Float(raw) { parameters.damping = c }
    if let raw = value("-rest"), let named = ClothSolver.RestShape(rawValue: raw) { parameters.restShape = named }
    if let raw = value("-fabric"), let named = LabScene.Fabric(rawValue: raw) { parameters.bendCompliance = named.bendCompliance }
    if arguments.contains("-interfacing") { parameters.interfacing = 100 }
    let mesh: ClothMesh
    if value("-step") == "shirt" {
        guard let garment = ClothMesh.garment(GarmentSource(rawValue: value("-mesh") ?? "4k") ?? .proxy4k,
                                              pin: GarmentPin(rawValue: value("-shirtPin") ?? "shoulders") ?? .shoulders)
        else { print("no garment"); return }
        mesh = garment
    } else {
        mesh = .sheet(width: 1.0, height: 1.2, spacing: 0.0175, top: 1.95,
                      pin: SheetPin(rawValue: value("-sheetPin") ?? "hooks") ?? .hooks)
    }
    let topology = ClothTopology(triangles: mesh.triangles)
    let solver = ClothSolver(mesh: mesh, topology: topology, parameters: parameters)
    print("\(mesh.name): \(mesh.positions.count) particles, \(topology.edges.count) edges, \(topology.bendPairs.count) bend pairs, \(mesh.pins.count) pins")
    let steps = Int(seconds * 60)
    for step in 0 ... steps {
        if arguments.contains("-trace"), step < 12 {
            var worst = 0, worstMove: Float = 0
            for (i, p) in solver.positions.enumerated() where simd_length(p - mesh.positions[i]) > worstMove {
                worstMove = simd_length(p - mesh.positions[i]); worst = i
            }
            print("frame \(step): worst move \(worstMove) at particle \(worst) rest \(mesh.positions[worst]) now \(solver.positions[worst]) stretch \(solver.stretch())")
        }
        if step % 30 == 0 {
            let stretch = solver.stretch()
            var lo = SIMD3<Float>(repeating: .infinity), hi = SIMD3<Float>(repeating: -.infinity)
            for p in solver.positions { lo = simd_min(lo, p); hi = simd_max(hi, p) }
            print(String(format: "t %5.1f  stretch mean %6.2f%% worst %7.2f%%  speed %7.3f  bounds x[%.2f %.2f] y[%.2f %.2f] z[%.2f %.2f]",
                         Float(step) / 60, stretch.mean * 100, stretch.worst * 100, solver.meanSpeed(),
                         lo.x, hi.x, lo.y, hi.y, lo.z, hi.z))
        }
        solver.step(deltaTime: 1.0 / 60.0)
    }
}
