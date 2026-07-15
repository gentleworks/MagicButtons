import TouchKit

extension TouchPhase {
    /// Maps the framework's raw contact `state` to our four phases. **Pinned from
    /// on-device bring-up** (`dump-frames` on the target OS): a contact's life runs
    /// `3 → 4 … 4 → 5 → 6 → 7`, with `major` decaying to 0 at 7.
    ///
    /// | raw `state` | phase   | meaning                    |
    /// |-------------|---------|----------------------------|
    /// | 3           | .began  | making contact             |
    /// | 4           | .moved  | touching (moving or still) |
    /// | 5, 6, 7     | .ended  | breaking / lifting / gone  |
    ///
    /// States 0–2 (not a live contact) return nil and are skipped. `.moved`
    /// covers stationary too — the recognizer treats them identically, so the
    /// adapter does not currently emit `.stationary`.
    init?(rawState: Int32) {
        switch rawState {
        case 3:       self = .began
        case 4:       self = .moved
        case 5, 6, 7: self = .ended
        default:      return nil
        }
    }
}
