/// Work that runs next to the HTTP server until the server is stopped (the task is cancelled).
nonisolated protocol BackgroundService: Sendable {
	func run() async
}
