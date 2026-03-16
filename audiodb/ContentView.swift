import SwiftUI

struct LevelBar: View {
    let label: String
    let db: Float

    // Change this to taste. -100 shows very quiet stuff.
    private let floorDB: Float = -100
    private let ceilDB: Float = 0

    private var normalized: CGFloat {
        // Map db -> 0...1
        let clamped = max(min(db, ceilDB), floorDB)
        let t = (clamped - floorDB) / (ceilDB - floorDB)
        return CGFloat(t)
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(label)
                .frame(width: 50, alignment: .leading)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .opacity(0.15)

                    Capsule()
                        .frame(width: geo.size.width * normalized)
                }
            }
            .frame(height: 12)

            Text(String(format: "%.1f dBFS", db))
                .frame(width: 90, alignment: .trailing)
                .monospacedDigit()
        }
    }
}

struct ContentView: View {
    @StateObject private var meter = AudioMeter()

    var body: some View {
        VStack(spacing: 16) {
            Text("System Audio Meter (dBFS)")
                .font(.title2)

            VStack(spacing: 12) {
                LevelBar(label: "RMS", db: meter.rmsDBFS)
                LevelBar(label: "Peak", db: meter.peakDBFS)
            }
            .padding(.horizontal, 24)

            HStack(spacing: 12) {
                Button("Start") { meter.start() }
                    .disabled(meter.isRunning)

                Button("Stop") { meter.stop() }
                    .disabled(!meter.isRunning)

                Button("Reset Peak") { meter.resetPeak() }
            }

            if let err = meter.lastError {
                Text(err).foregroundStyle(.red)
            }
        }
        .padding(24)
        .frame(minWidth: 600, minHeight: 260)
    }
}
