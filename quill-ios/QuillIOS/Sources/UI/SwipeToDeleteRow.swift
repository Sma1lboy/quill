import SwiftUI

/// Swipe-left-to-delete for rows living outside a List. Follows the
/// apple-design rules: content tracks the finger 1:1, over-drag past the
/// action rubber-bands, release snaps by position+velocity with a
/// critically damped spring, and a full-length fling deletes directly.
/// No confirmation dialog — the swipe already expressed intent; the safety
/// net is the deleted folder sitting in a .trash dir for undo.
struct SwipeToDeleteRow<Content: View>: View {
    var disabled = false
    let onDelete: () -> Void
    @ViewBuilder let content: () -> Content

    /// Revealed action width.
    private let actionWidth: CGFloat = 76
    /// Past this offset a release deletes outright. Must sit inside the
    /// rubber-band's reachable range: the band asymptotes around -138pt, so
    /// anything near that can never be hit and the gesture silently degrades
    /// to velocity-only — which is how a quick flick used to delete a row the
    /// user had barely moved.
    private let flingCommit: CGFloat = 108

    @State private var offset: CGFloat = 0
    @State private var open = false
    /// Delete fires at most once per row. Two paths reach it (a fling in
    /// `onEnded`, a tap on the revealed trash), and `deleteSession` moves the
    /// folder to `.trash` after clearing whatever sits there — so a second
    /// fire on the same id deletes the undo backup the first one just made.
    @State private var deleted = false

    private func commitDelete() {
        // `disabled` masks the drag gesture but not the revealed button, so
        // the busy check belongs here too — this is the one path both take.
        guard !deleted, !disabled else { return }
        deleted = true
        withAnimation(.spring(response: 0.3, dampingFraction: 1.0)) {
            offset = 0
            open = false
        }
        onDelete()
    }

    var body: some View {
        #if DEBUG
        Self.selfCheck()
        #endif
        return content()
            .offset(x: offset)
            .background(alignment: .trailing) {
                if offset < 0 {
                    // The action fills exactly the gap the row vacates —
                    // past the rest width it stretches with the rubber-band
                    // instead of detaching from the row edge.
                    Button {
                        commitDelete()
                    } label: {
                        Image(systemName: "trash.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Theme.paper)
                            .frame(width: -offset)
                            .frame(maxHeight: .infinity)
                            .background(
                                RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                                    .fill(Theme.error)
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Delete recording")
                }
            }
            .contentShape(Rectangle())
            .highPriorityGesture(dragGesture, including: disabled ? .subviews : .all)
            .animation(nil, value: offset) // gesture drives offset directly
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 12, coordinateSpace: .local)
            .onChanged { value in
                // Horizontal intent only; let vertical scrolls through.
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                let base: CGFloat = open ? -actionWidth : 0
                var x = base + value.translation.width
                if x > 0 {
                    x = 0
                } else if x < -actionWidth {
                    // Rubber-band past the action (apple-design §9).
                    let over = -x - actionWidth
                    x = -actionWidth - over * actionWidth / (actionWidth + over * 0.55) * 0.55
                }
                offset = x
            }
            .onEnded { value in
                let velocity = value.velocity.width
                // Delete outright only on a deliberate long swipe. Distance is
                // required — a fast flick can clear 1200pt/s in 30pt of travel,
                // so velocity alone deleted rows the user had barely moved, and
                // the old distance test was unreachable behind the rubber-band,
                // leaving velocity to decide everything. Velocity can still
                // lower the bar for a committed swipe, never replace it.
                if Self.shouldFling(offset: offset, velocity: velocity, commit: flingCommit) {
                    commitDelete()
                    return
                }
                // Position + velocity decide open/closed (velocity sign
                // wins on a reversal — apple-design quick reference).
                let shouldOpen = velocity < 100 && (-offset > actionWidth / 2 || velocity < -300)
                snap(to: shouldOpen ? -actionWidth : 0)
            }
    }

    /// Fling-to-delete: past `commit`, or past 80% of it while still moving
    /// left fast. Pure, so the thresholds can be checked without a gesture.
    static func shouldFling(offset: CGFloat, velocity: CGFloat, commit: CGFloat) -> Bool {
        if -offset >= commit { return true }
        return -offset >= commit * 0.8 && velocity < -900
    }

    #if DEBUG
    /// Both directions matter: too eager and a flick deletes a row the user
    /// only meant to peek at, too strict and the fling gesture is dead.
    static func selfCheck() {
        let c: CGFloat = 108
        // The bug: a fast flick with almost no travel must NOT delete.
        assert(!shouldFling(offset: -30, velocity: -2400, commit: c))
        assert(!shouldFling(offset: -76, velocity: -3000, commit: c))  // parked at rest width
        // A deliberate long swipe still deletes.
        assert(shouldFling(offset: -110, velocity: 0, commit: c))
        assert(shouldFling(offset: -90, velocity: -1200, commit: c))   // near-commit + moving
        // Near-commit but slowing to a stop should just open, not delete.
        assert(!shouldFling(offset: -90, velocity: -200, commit: c))
        // A rightward release never deletes.
        assert(!shouldFling(offset: -100, velocity: 2000, commit: c))
    }
    #endif

    private func snap(to target: CGFloat) {
        withAnimation(.spring(response: 0.3, dampingFraction: 1.0)) {
            offset = target
            open = target != 0
        }
    }
}
