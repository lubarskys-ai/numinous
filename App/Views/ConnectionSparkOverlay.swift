import SwiftUI
import UIKit

/// A whole-screen flourish when a new connection joins your web — the effect is
/// chosen by the axis it touched: a person beats the **heart** (pink lub-dub), a
/// book or idea lights the **mind** (a warm bulb flickering on). Lives at the app
/// root so it washes over every screen, and never blocks touches.
struct ConnectionSparkOverlay: View {
    @EnvironmentObject var model: AppModel

    @State private var glow: Double = 0
    @State private var scale: CGFloat = 1
    @State private var symbol = "heart.fill"
    @State private var tint = Color.pink

    var body: some View {
        ZStack {
            RadialGradient(
                colors: [tint.opacity(0.55 * glow), tint.opacity(0)],
                center: .center, startRadius: 4, endRadius: 640)
            Image(systemName: symbol)
                .font(.system(size: 170))
                .foregroundStyle(tint)
                .scaleEffect(scale)
                .opacity(glow)
                .shadow(color: tint.opacity(0.6), radius: 44)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .opacity(glow > 0.001 ? 1 : 0)
        .onChange(of: model.spark) { spark in
            guard let spark else { return }
            Task { await play(axisID: spark.axisID) }
        }
    }

    private func play(axisID: String) async {
        switch axisID {
        case "mind": symbol = "lightbulb.fill"; tint = Color(red: 1.0, green: 0.78, blue: 0.28); await bulb()
        default:     symbol = "heart.fill";     tint = .pink;                                   await heartbeat()
        }
    }

    // MARK: - Heart: two lub-dub beats

    private func heartbeat() async {
        let haptic = UIImpactFeedbackGenerator(style: .heavy)
        haptic.prepare()
        func thump(_ intensity: CGFloat, glow g: Double, scale s: CGFloat, over dur: Double) {
            haptic.impactOccurred(intensity: intensity)
            withAnimation(.easeOut(duration: dur)) { glow = g; scale = s }
        }
        for _ in 0..<2 {
            thump(0.6, glow: 0.5, scale: 1.10, over: 0.11)   // lub
            try? await Task.sleep(nanoseconds: 150_000_000)
            thump(1.0, glow: 0.95, scale: 1.26, over: 0.11)  // dub
            try? await Task.sleep(nanoseconds: 150_000_000)
            withAnimation(.easeOut(duration: 0.34)) { glow = 0.14; scale = 1.0 }
            try? await Task.sleep(nanoseconds: 520_000_000)
        }
        withAnimation(.easeOut(duration: 0.6)) { glow = 0; scale = 1 }
    }

    // MARK: - Mind: a bulb flickering on, then a warm hold

    private func bulb() async {
        let click = UIImpactFeedbackGenerator(style: .rigid)
        click.prepare()
        func flick(_ g: Double, scale s: CGFloat, over dur: Double, haptic: CGFloat? = nil) {
            if let haptic { click.impactOccurred(intensity: haptic) }
            withAnimation(.easeOut(duration: dur)) { glow = g; scale = s }
        }
        scale = 0.9
        // Stutter to life like a filament catching.
        flick(0.7, scale: 1.06, over: 0.05, haptic: 0.5)
        try? await Task.sleep(nanoseconds: 70_000_000)
        flick(0.15, scale: 1.0, over: 0.05)
        try? await Task.sleep(nanoseconds: 60_000_000)
        flick(1.0, scale: 1.20, over: 0.06, haptic: 1.0)   // full on
        try? await Task.sleep(nanoseconds: 90_000_000)
        // Settle to a steady warm glow and hold.
        withAnimation(.easeOut(duration: 0.3)) { glow = 0.6; scale = 1.08 }
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        withAnimation(.easeIn(duration: 0.7)) { glow = 0; scale = 1 }
    }
}
