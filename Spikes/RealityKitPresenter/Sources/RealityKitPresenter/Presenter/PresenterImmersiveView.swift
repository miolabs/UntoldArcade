//
//  PresenterImmersiveView.swift
//  RealityKitPresenter spike
//
//  The body of the ImmersiveSpace: a RealityView holding the presenter's entities, with
//  the SceneEvents.Update subscription that drives the tickets.
//

import RealityKit
import SwiftUI

struct PresenterImmersiveView: View {
    let model: SpikeModel
    @State private var holder = PresenterHolder()

    var body: some View {
        RealityView { content in
            do {
                let presenter = try await EyePresenter(model: model)
                content.add(presenter.root)
                holder.subscription = content.subscribe(to: SceneEvents.Update.self) { event in
                    MainActor.assumeIsolated {
                        presenter.onUpdate(deltaTime: event.deltaTime)
                    }
                }
                presenter.start()
                holder.presenter = presenter
            } catch {
                model.stats.log("Presenter could not be created: \(error)")
            }
        }
        .onAppear { model.spaceOpen = true }
        .onDisappear {
            holder.presenter?.stop()
            holder.subscription?.cancel()
            holder.subscription = nil
            holder.presenter = nil
            model.spaceOpen = false
        }
    }
}

@MainActor
final class PresenterHolder {
    var presenter: EyePresenter?
    var subscription: EventSubscription?
}
