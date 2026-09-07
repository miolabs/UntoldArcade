//
//  ZombieResources.swift
//  CoolZombieKit
//
// Copyright (C) Untold Engine Studios
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

public enum ZombieResources {
    /// Root of the kit's bundled assets (`Models/`, `Animations/`), for
    /// `setEngine(.assetBasePath(_:))`. The model and clips are marketplace
    /// assets that ship only inside compiled apps — see the README.
    public static var baseURL: URL? {
        Bundle.module.resourceURL
    }

    /// Which motion data drives the demo. `pack` is MoCap Online's Zombie
    /// Pro (binary-only license); `style100` is the Zombie style of the
    /// 100STYLE dataset (CC BY 4.0), retargeted onto the same rig. Pick
    /// with the launch argument `-clipSet style100`; the pack is the
    /// default.
    public enum ClipSet: String, Sendable {
        case pack
        case style100
    }

    public static var clipSet: ClipSet {
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "-clipSet"), index + 1 < arguments.count,
           let set = ClipSet(rawValue: arguments[index + 1])
        {
            return set
        }
        return .pack
    }

    /// The calm idle played directly while the zombie waits to be provoked
    /// — the stillest idle (no root travel, a slow sway). Motion matching
    /// would pick the aggressive attack idles for a zero goal.
    public static var waitingClip: String {
        switch clipSet {
        case .pack: return "idle_1"
        case .style100: return "s100_idle"
        }
    }

    /// 100STYLE Zombie (Mason, Starke, Komura 2022; CC BY 4.0), one long
    /// capture per locomotion type: idle, forward/backward/sideways walks
    /// and runs, and a transitions take. Cooked from the BVH with
    /// `retarget_100style.py` (world-space delta retarget, smoothed root
    /// path and heading).
    public static let style100Clips: [String] = [
        "s100_idle", "s100_walk", "s100_run",
        "s100_walk_back", "s100_run_back",
        "s100_side_walk", "s100_side_run",
        "s100_transitions",
    ]

    /// Clip names the chase database is built from: standing idles, a
    /// walk/chase ladder (0.4-0.91 m/s), a hyper-chase ladder (2.73-5.56
    /// m/s), circular sprints, in-place turns and acceleration starts — all
    /// with the pack's authored root motion.
    ///
    /// Standing clips must be truly in place. `idle_3` is not: it has a
    /// shuffle step, and a zero-motion goal refuses to play through it —
    /// the search snaps back to the stillest frame every 0.3 s and the idle
    /// visibly restarts. `shamble_1` and the short attack idles hold.
    /// The 0.2 m/s `walk_1` is left out for the mirror reason: it is close
    /// enough to standing that a zero goal keeps playing it and the zombie
    /// creeps into the player instead of stopping.
    public static var chaseClips: [String] {
        switch clipSet {
        case .pack: return packClips
        case .style100: return style100Clips
        }
    }

    public static let packClips: [String] = [
        "idle_1",
        "shamble_1", "hold_1", "hold_2", "hold_3", "hold_4",
        "walk_3", "walk_6",
        "chase_1", "chase_2", "chase_3", "chase_5",
        "hyper_1", "hyper_2", "hyper_3", "hyper_5",
        "hyper_1_cir_l", "hyper_1_cir_r", "hyper_3_cir_l", "hyper_3_cir_r",
        "hyper_5_cir_l", "hyper_5_cir_r",
        "turn_l_45", "turn_r_45", "turn_l_90", "turn_r_90",
        "turn_l_180", "turn_r_180",
        "start_chase", "start_hyper",
    ]
}
