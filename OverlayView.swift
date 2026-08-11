//
//  OverlayView.swift
//  CameraCoach
//
//  Pure UI: draws the rule-of-thirds grid, a level indicator driven by
//  Layer 1's horizon signal, a subject-offset dot, and the Layer 2 tip
//  bubble. This view has no knowledge of Vision or Foundation Models —
//  it just renders whatever FrameSignals + tip text it's given.
//

import SwiftUI

struct OverlayView: View {
    let signals: FrameSignals
    let tip: String
    let readyToShoot: Bool
    let coachingAvailable: Bool
    let coachingEnabled: Bool
    var coachingBusy: Bool = false

    var body: some View {
        GeometryReader { geo in
            ZStack {
                ruleOfThirdsGrid(in: geo.size)
                levelIndicator(in: geo.size)
                subjectDot(in: geo.size)
                guidanceArrow(in: geo.size)

                VStack {
                    // The overlay ignores the safe area (it must line up with
                    // the full-bleed preview), so the badge needs explicit
                    // clearance from the status bar and the top control row.
                    aestheticsBadge
                        .padding(.top, geo.safeAreaInsets.top + 108)
                    Spacer()
                    if coachingEnabled {
                        tipBubble
                            .padding(.bottom, 236) // clear of zoom presets + mode switcher + shutter row
                    }
                }
                .padding()
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: - Rule of thirds

    private func ruleOfThirdsGrid(in size: CGSize) -> some View {
        Path { path in
            let thirdW = size.width / 3
            let thirdH = size.height / 3
            for i in 1...2 {
                path.move(to: CGPoint(x: thirdW * CGFloat(i), y: 0))
                path.addLine(to: CGPoint(x: thirdW * CGFloat(i), y: size.height))
                path.move(to: CGPoint(x: 0, y: thirdH * CGFloat(i)))
                path.addLine(to: CGPoint(x: size.width, y: thirdH * CGFloat(i)))
            }
        }
        .stroke(Color.white.opacity(0.35), lineWidth: 1)
    }

    // MARK: - Level indicator

    private func levelIndicator(in size: CGSize) -> some View {
        let angle = signals.horizonAngleDegrees ?? 0
        let isLevel = abs(angle) < 1.0
        return Rectangle()
            .fill(isLevel ? Color.yellow : Color.white.opacity(0.6))
            .frame(width: size.width * 0.5, height: 2)
            .rotationEffect(.degrees(-angle))
            .position(x: size.width / 2, y: size.height / 2)
    }

    // MARK: - Subject offset dot

    @ViewBuilder
    private func subjectDot(in size: CGSize) -> some View {
        if let offset = signals.subjectOffset {
            let x = size.width / 2 + (offset.x * size.width / 2)
            let y = size.height / 2 + (offset.y * size.height / 2)
            Circle()
                .stroke(Color.yellow, lineWidth: 2)
                .frame(width: 36, height: 36)
                .position(x: x, y: y)
        }
    }

    // MARK: - Directional guidance
    //
    // Glanceable nudges computed from Layer 1's numbers: an arrow pointing
    // toward where the camera should move to center the subject, or a
    // rotation cue when the horizon is tilted. Free (no AI involved).

    @ViewBuilder
    private func guidanceArrow(in size: CGSize) -> some View {
        if let offset = signals.subjectOffset, hypot(offset.x, offset.y) > 0.25 {
            Image(systemName: "arrow.right")
                .font(.title.bold())
                .foregroundStyle(.yellow)
                .shadow(color: .black.opacity(0.5), radius: 3)
                .rotationEffect(.radians(atan2(offset.y, offset.x)))
                .position(x: size.width / 2, y: size.height * 0.54)
                .transition(.opacity)
        } else if let angle = signals.horizonAngleDegrees, abs(angle) > 3 {
            Image(systemName: angle > 0 ? "arrow.clockwise" : "arrow.counterclockwise")
                .font(.title.bold())
                .foregroundStyle(.yellow)
                .shadow(color: .black.opacity(0.5), radius: 3)
                .position(x: size.width / 2, y: size.height * 0.54)
                .transition(.opacity)
        }
    }

    // MARK: - Aesthetics badge

    private var aestheticsBadge: some View {
        HStack {
            Spacer()
            Text(String(format: "%.0f%%", (signals.aestheticsScore + 1) / 2 * 100))
                .font(.caption.monospacedDigit().bold())
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.ultraThinMaterial, in: Capsule())
        }
    }

    // MARK: - Tip bubble

    private var tipBubble: some View {
        HStack(spacing: 8) {
            if !coachingAvailable {
                Image(systemName: "sparkles.slash")
            } else if readyToShoot {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Image(systemName: "sparkles")
            }
            Text(tip)
                .font(.subheadline.weight(.medium))
                .lineLimit(5)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .foregroundStyle(.white)
        // Dim while a request is in flight; animate tip changes so new
        // advice is noticeable.
        .opacity(coachingBusy ? 0.55 : 1)
        .animation(.easeInOut(duration: 0.25), value: coachingBusy)
        .animation(.easeInOut(duration: 0.3), value: tip)
    }
}
