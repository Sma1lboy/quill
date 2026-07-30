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
    /// Dragging past this fraction of the row width = commit intent.
    private let flingFraction: CGFloat = 0.55

    @State private var offset: CGFloat = 0
    @State private var open = false

    private func commitDelete() {
        withAnimation(.spring(response: 0.3, dampingFraction: 1.0)) {
            offset = 0
            open = false
        }
        onDelete()
    }

    var body: some View {
        content()
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
                // Fling far left = delete outright.
                if -offset > 240 * flingFraction || velocity < -1200 {
                    commitDelete()
                    return
                }
                // Position + velocity decide open/closed (velocity sign
                // wins on a reversal — apple-design quick reference).
                let shouldOpen = velocity < 100 && (-offset > actionWidth / 2 || velocity < -300)
                snap(to: shouldOpen ? -actionWidth : 0)
            }
    }

    private func snap(to target: CGFloat) {
        withAnimation(.spring(response: 0.3, dampingFraction: 1.0)) {
            offset = target
            open = target != 0
        }
    }
}
