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

    /// Clip names the chase database is built from: idles, a walk/chase
    /// ladder (0.2-0.91 m/s), a hyper-chase ladder (2.73-5.56 m/s),
    /// circular sprints, in-place turns and acceleration starts — all with
    /// the pack's authored root motion.
    public static let chaseClips: [String] = [
        "idle_3", "shamble_1",
        "walk_1", "walk_3", "walk_6",
        "chase_1", "chase_2", "chase_3", "chase_5",
        "hyper_1", "hyper_2", "hyper_3", "hyper_5",
        "hyper_1_cir_l", "hyper_1_cir_r", "hyper_3_cir_l", "hyper_3_cir_r",
        "hyper_5_cir_l", "hyper_5_cir_r",
        "turn_l_45", "turn_r_45", "turn_l_90", "turn_r_90",
        "turn_l_180", "turn_r_180",
        "start_chase", "start_hyper",
    ]
}
