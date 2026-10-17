//
//  PresenterActivity.swift
//  RealityKitPresenter spike
//

import Foundation
import GroupActivities

/// The SharePlay activity for question 4: a group immersive space from a FaceTime call.
struct PresenterActivity: GroupActivity {
    static let activityIdentifier = "com.miolabs.RealityKitPresenterSpike.session"

    var metadata: GroupActivityMetadata {
        var metadata = GroupActivityMetadata()
        metadata.title = "RealityKit Presenter Spike"
        metadata.subtitle = "Personas against the frame grids"
        metadata.type = .generic
        return metadata
    }
}
