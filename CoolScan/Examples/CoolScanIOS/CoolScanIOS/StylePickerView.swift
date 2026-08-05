import CoolScan
import SwiftUI

struct StylePickerView: View {
    @Binding var style: CoolScanStyle

    var body: some View {
        Picker("Style", selection: $style) {
            ForEach(CoolScanStyle.allCases, id: \.self) { style in
                Text(label(for: style)).tag(style)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal)
        .background(.clear)
    }

    private func label(for style: CoolScanStyle) -> String {
        switch style {
        case .original: "Real"
        case .toon: "Toon"
        case .comic: "Comic"
        case .pixel: "Pixel"
        case .sketch: "Sketch"
        }
    }
}
