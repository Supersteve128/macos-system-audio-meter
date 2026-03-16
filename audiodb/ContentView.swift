import SwiftUI

private struct MeterPalette {
    let fill: LinearGradient
    let glow: Color
    let valueBackground: Color

    static let rms = MeterPalette(
        fill: LinearGradient(
            colors: [Color(red: 0.18, green: 0.78, blue: 0.63), Color(red: 0.12, green: 0.52, blue: 0.70)],
            startPoint: .leading,
            endPoint: .trailing
        ),
        glow: Color(red: 0.18, green: 0.78, blue: 0.63),
        valueBackground: Color(red: 0.90, green: 0.98, blue: 0.96)
    )

    static let peak = MeterPalette(
        fill: LinearGradient(
            colors: [Color(red: 1.00, green: 0.70, blue: 0.26), Color(red: 0.92, green: 0.34, blue: 0.18)],
            startPoint: .leading,
            endPoint: .trailing
        ),
        glow: Color(red: 0.96, green: 0.48, blue: 0.19),
        valueBackground: Color(red: 1.00, green: 0.95, blue: 0.89)
    )
}

private struct LevelBar: View {
    let label: String
    let caption: String
    let db: Float
    let level: Float
    let palette: MeterPalette

    private var normalized: CGFloat {
        CGFloat(min(max(level, 0), 1))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.black.opacity(0.85))

                    Text(caption)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.black.opacity(0.45))
                }

                Spacer()

                Text(String(format: "%.1f dBFS", db))
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(palette.valueBackground)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Color.black.opacity(0.06), lineWidth: 1)
                    )
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.black.opacity(0.08))

                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Color.white.opacity(0.35), Color.white.opacity(0.02)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )

                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(palette.fill)
                        .frame(width: max(24, geo.size.width * normalized))
                        .shadow(color: palette.glow.opacity(0.35), radius: 12, x: 0, y: 0)
                }
            }
            .frame(height: 22)
            .animation(.easeOut(duration: 0.14), value: normalized)

            HStack {
                Text("-100 dBFS")
                Spacer()
                Text("-50 dBFS")
                Spacer()
                Text("0 dBFS")
            }
            .font(.system(size: 10, weight: .medium, design: .rounded))
            .foregroundStyle(Color.black.opacity(0.35))
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color.white.opacity(0.72))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.white.opacity(0.7), lineWidth: 1)
        )
    }
}

private struct StatusPill: View {
    let title: String
    let value: String
    let color: Color

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)

            Text(title)
                .foregroundStyle(Color.black.opacity(0.45))

            Text(value)
                .foregroundStyle(Color.black.opacity(0.85))
        }
        .font(.system(size: 12, weight: .semibold, design: .rounded))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            Capsule(style: .continuous)
                .fill(Color.white.opacity(0.72))
        )
        .overlay(
            Capsule(style: .continuous)
                .stroke(Color.black.opacity(0.06), lineWidth: 1)
        )
    }
}

private struct ControlButtonStyle: ButtonStyle {
    let fill: Color
    let foreground: Color
    let border: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold, design: .rounded))
            .padding(.horizontal, 18)
            .padding(.vertical, 11)
            .frame(minWidth: 108)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(fill.opacity(configuration.isPressed ? 0.88 : 1))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(border, lineWidth: 1)
            )
            .foregroundStyle(foreground)
            .shadow(color: Color.black.opacity(configuration.isPressed ? 0.06 : 0.1), radius: 10, x: 0, y: 6)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct ContentView: View {
    @StateObject private var meter = AudioMeter()

    private var statusColor: Color {
        meter.isRunning ? Color(red: 0.17, green: 0.69, blue: 0.41) : Color(red: 0.62, green: 0.62, blue: 0.66)
    }

    private var statusText: String {
        meter.isRunning ? "Running" : "Idle"
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.97, green: 0.94, blue: 0.90),
                    Color(red: 0.93, green: 0.95, blue: 0.97)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            Circle()
                .fill(Color(red: 0.98, green: 0.71, blue: 0.37).opacity(0.22))
                .frame(width: 320, height: 320)
                .blur(radius: 24)
                .offset(x: -250, y: -200)

            Circle()
                .fill(Color(red: 0.18, green: 0.66, blue: 0.70).opacity(0.20))
                .frame(width: 360, height: 360)
                .blur(radius: 26)
                .offset(x: 280, y: 180)

            VStack(spacing: 24) {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Core Audio monitor for routed system playback")
                                .font(.system(size: 12, weight: .bold, design: .rounded))
                                .textCase(.uppercase)
                                .tracking(1.2)
                                .foregroundStyle(Color.black.opacity(0.45))

                            Text("Real-Time System Audio Meter")
                                .font(.system(size: 34, weight: .bold, design: .rounded))
                                .foregroundStyle(Color.black.opacity(0.9))

                            Text("Measures RMS and peak dBFS from a BlackHole 2ch loopback device with low-latency Core Audio capture.")
                                .font(.system(size: 15, weight: .medium, design: .rounded))
                                .foregroundStyle(Color.black.opacity(0.6))
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Spacer(minLength: 24)

                        VStack(alignment: .trailing, spacing: 10) {
                            StatusPill(title: "Status", value: statusText, color: statusColor)
                            StatusPill(title: "Device", value: "BlackHole 2ch", color: Color(red: 0.28, green: 0.55, blue: 0.83))
                        }
                    }

                    HStack(spacing: 12) {
                        Label("dBFS output proxy", systemImage: "waveform.path.ecg")
                        Label("Peak hold smoothing", systemImage: "gauge.with.needle")
                    }
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.black.opacity(0.56))
                }

                VStack(spacing: 16) {
                    LevelBar(
                        label: "RMS",
                        caption: "Average signal energy",
                        db: meter.rmsDBFS,
                        level: meter.rmsLevel,
                        palette: .rms
                    )

                    LevelBar(
                        label: "Peak",
                        caption: "Fast transient ceiling",
                        db: meter.peakDBFS,
                        level: meter.peakLevel,
                        palette: .peak
                    )
                }

                HStack(spacing: 14) {
                    Button("Start") { meter.start() }
                        .buttonStyle(
                            ControlButtonStyle(
                                fill: Color(red: 0.18, green: 0.73, blue: 0.54),
                                foreground: .white,
                                border: Color.clear
                            )
                        )
                        .disabled(meter.isRunning)

                    Button("Stop") { meter.stop() }
                        .buttonStyle(
                            ControlButtonStyle(
                                fill: Color(red: 0.14, green: 0.16, blue: 0.21),
                                foreground: .white,
                                border: Color.clear
                            )
                        )
                        .disabled(!meter.isRunning)

                    Button("Reset Peak") { meter.resetPeak() }
                        .buttonStyle(
                            ControlButtonStyle(
                                fill: Color.white.opacity(0.65),
                                foreground: Color.black.opacity(0.82),
                                border: Color.black.opacity(0.08)
                            )
                        )
                }
                .opacity(meter.lastError == nil ? 1 : 0.96)

                if let err = meter.lastError {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(Color(red: 0.80, green: 0.24, blue: 0.18))

                        Text(err)
                            .font(.system(size: 13, weight: .medium, design: .rounded))
                            .foregroundStyle(Color.black.opacity(0.72))

                        Spacer()
                    }
                    .padding(16)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(Color(red: 1.00, green: 0.94, blue: 0.91))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(Color(red: 0.91, green: 0.48, blue: 0.36).opacity(0.4), lineWidth: 1)
                    )
                }
            }
            .padding(30)
            .frame(maxWidth: 860)
            .background(
                RoundedRectangle(cornerRadius: 30, style: .continuous)
                    .fill(.ultraThinMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 30, style: .continuous)
                    .stroke(Color.white.opacity(0.6), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.12), radius: 32, x: 0, y: 24)
            .padding(28)
        }
        .frame(minWidth: 860, minHeight: 620)
    }
}
