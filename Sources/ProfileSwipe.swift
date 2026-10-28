import Foundation

/// Turns sideways scrolling anywhere over the palette into a position between a browser's profiles, which the
/// palette draws as it moves. The content follows the fingers, as scrolled content does, and settles on a profile
/// with a spring once they lift; a flick carries further. Up-and-down scrolling is left to the results.
struct ProfileSwipe {
    enum Axis { case undecided, sideways, upright }

    /// Finger travel, in points, that moves one profile.
    static let pageTravel = 180.0
    /// The share of a profile's travel past which letting go moves on to it.
    static let commitShare = 0.28
    /// How far past the first or last profile the fingers can pull, in profiles.
    static let stretch = 0.35

    let count: Int
    /// Where the swipe is, in profiles: 1.5 is halfway between the second and the third.
    private(set) var position: Double
    /// The profile the swipe settles on.
    private(set) var target: Int
    private(set) var axis = Axis.undecided
    /// Momentum scrolling after a sideways swipe moves nothing.
    private(set) var swallowsMomentum = false
    private var velocity = 0.0
    private var start = 0.0
    private var travel = 0.0
    private var pending = (x: 0.0, y: 0.0)
    private var samples: [(time: Double, pages: Double)] = []
    private var lastStep = -Double.infinity

    init(count: Int, index: Int) {
        self.count = count
        target = min(max(index, 0), max(count - 1, 0))
        position = Double(target)
    }

    var isSettled: Bool { position == Double(target) && velocity == 0 }

    /// Fingers touched the trackpad: a moving swipe stops where it is, so it can be caught and pushed on.
    mutating func touch() {
        axis = .undecided
        swallowsMomentum = false
        pending = (0, 0)
        samples = []
        velocity = 0
        start = position
        travel = 0
    }

    /// One step of a gesture. Returns whether it belongs to a sideways swipe; the first movement decides.
    mutating func scroll(dx: Double, dy: Double, time: Double) -> Bool {
        guard axis == .undecided else { return axis == .sideways && drag(dx, time: time) }
        pending.x += dx
        pending.y += dy
        guard max(abs(pending.x), abs(pending.y)) >= 2 else { return false }
        axis = abs(pending.x) > abs(pending.y) * 1.2 ? .sideways : .upright
        return axis == .sideways && drag(pending.x, time: time)
    }

    private mutating func drag(_ dx: Double, time: Double) -> Bool {
        travel += dx
        // Scrolled content follows the fingers: moving them left brings the next profile in from the right.
        position = banded(start - travel / Self.pageTravel)
        samples.append((time, -dx / Self.pageTravel))
        samples.removeAll { time - $0.time > 0.1 }
        return true
    }

    /// The fingers lifted. Returns whether the gesture was a sideways swipe, which then settles on a profile.
    mutating func release(time: Double) -> Bool {
        defer { axis = .undecided }
        guard axis == .sideways else { return false }
        let recent = samples.filter { time - $0.time <= 0.1 }
        let span = max((recent.last?.time ?? time) - (recent.first?.time ?? time), 1.0 / 60)
        velocity = recent.count > 1 ? min(max(recent.reduce(0) { $0 + $1.pages } / span, -12), 12) : 0
        // Where a flick would carry it, measured from the profile it was settling on.
        let moved = position + velocity * 0.12 - Double(target)
        let steps = (abs(moved) + 1 - Self.commitShare).rounded(.down) * (moved < 0 ? -1 : 1)
        target = min(max(target + Int(steps), 0), count - 1)
        swallowsMomentum = true
        return true
    }

    mutating func momentumEnded() { swallowsMomentum = false }

    /// A mouse wheel turned sideways, or another device without gestures: one profile per turn, ignoring the
    /// repeats of one turn. Returns whether it was sideways.
    mutating func step(dx: Double, dy: Double, time: Double) -> Bool {
        guard abs(dx) > abs(dy), dx != 0 else { return false }
        guard time - lastStep > 0.3 else { return true }
        lastStep = time
        move(to: target + (dx > 0 ? -1 : 1))
        return true
    }

    /// Settles on `index`; asked past either end, it bumps against it and comes back.
    mutating func move(to index: Int) {
        axis = .undecided
        let bounded = min(max(index, 0), count - 1)
        if bounded == target && index != target { velocity += Double(index - target) * 2.5 }
        target = bounded
    }

    /// Advances the spring toward the target by `elapsed` seconds. Returns whether it still moves.
    mutating func advance(by elapsed: Double) -> Bool {
        guard axis != .sideways else { return false }
        let frequency = 2 * Double.pi * 2.6
        let damping = 0.86
        var remaining = min(max(elapsed, 0), 0.1)
        while remaining > 0 {
            let step = min(remaining, 1.0 / 240)
            velocity += (-frequency * frequency * (position - Double(target)) - 2 * damping * frequency * velocity) * step
            position += velocity * step
            remaining -= step
        }
        guard abs(position - Double(target)) < 0.001 && abs(velocity) < 0.01 else { return true }
        position = Double(target)
        velocity = 0
        return false
    }

    /// Past the first or last profile, the fingers pull ever less, like scrolled content at its end.
    private func banded(_ raw: Double) -> Double {
        let upper = Double(count - 1)
        func rubber(_ over: Double) -> Double { (1 - 1 / (over * 0.55 / Self.stretch + 1)) * Self.stretch }
        if raw < 0 { return -rubber(-raw) }
        if raw > upper { return upper + rubber(raw - upper) }
        return raw
    }
}
