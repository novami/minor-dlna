import Foundation
import Synchronization

/// Keeps the Mac awake while something is streamed or converted; the last release lets it sleep again.
nonisolated final class SleepGuard: Sendable {
	static let shared = SleepGuard()

	/// Holds the Mac awake until it goes away.
	final class Hold: Sendable {
		private let owner: SleepGuard
		fileprivate init(_ owner: SleepGuard) { self.owner = owner }
		deinit { owner.release() }
	}

	private struct State {
		var holds = 0
		var activity: (any NSObjectProtocol)?
	}
	private let state = Mutex(State())

	func hold() -> Hold {
		state.withLock { s in
			s.holds += 1
			if s.holds == 1 {
				s.activity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .userInitiated],
				                                                   reason: "Streaming media to the local network")
			}
		}
		return Hold(self)
	}

	/// Holds in force, for the status.
	var active: Int { state.withLock { $0.holds } }

	private func release() {
		state.withLock { s in
			s.holds -= 1
			if s.holds == 0, let a = s.activity {
				ProcessInfo.processInfo.endActivity(a)
				s.activity = nil
			}
		}
	}
}
