import Foundation

/// Network access for the Transitland API. One request at a time is polite;
/// a dense downtown search fans out to dozens of stop and route requests, so
/// every fan-out goes through `parallel`, which caps in-flight concurrency,
/// and every call gets one retry for transient failures (timeouts, dropped
/// connections, 429/5xx) instead of surfacing the error alert.
enum TransitHTTP {

    /// Maximum simultaneous in-flight requests across a whole fetch.
    static let defaultMaxConcurrentRequests = 8

    static let retryDelay: Duration = .seconds(1)

    /// One request, one retry for transient failures.
    static func data(for request: URLRequest) async throws -> Data {
        try await attempt(for: request, retryLeft: true)
    }

    /// Runs `operation` for every item with at most `maxConcurrent` tasks in
    /// flight. Result order is not guaranteed; callers key results by ID.
    static func parallel<T: Sendable, R: Sendable>(
        _ items: [T],
        maxConcurrent: Int = defaultMaxConcurrentRequests,
        _ operation: @escaping @Sendable (T) async -> R
    ) async -> [R] {
        guard !items.isEmpty else { return [] }
        let cap = max(1, maxConcurrent)
        var allResults: [R] = []
        allResults.reserveCapacity(items.count)

        // Chunks must run one after another. Adding every chunk to one
        // outer task group would start them all at once and blow the cap.
        var start = 0
        while start < items.count {
            let end = min(start + cap, items.count)
            let chunk = Array(items[start..<end])
            let chunkResults = await withTaskGroup(of: R.self) { group in
                for item in chunk {
                    group.addTask { await operation(item) }
                }
                var results: [R] = []
                results.reserveCapacity(chunk.count)
                for await result in group {
                    results.append(result)
                }
                return results
            }
            allResults.append(contentsOf: chunkResults)
            start = end
        }
        return allResults
    }

    // MARK: - Private

    private static func attempt(
        for request: URLRequest,
        retryLeft: Bool
    ) async throws -> Data {
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw URLError(.badServerResponse)
            }
            guard (200...299).contains(httpResponse.statusCode) else {
                let retryableStatus = httpResponse.statusCode == 429
                    || (500...599).contains(httpResponse.statusCode)
                guard retryLeft, retryableStatus else {
                    throw URLError(.badServerResponse)
                }
                try await Task.sleep(for: retryDelay)
                return try await attempt(for: request, retryLeft: false)
            }
            return data
        } catch let error as URLError where retryLeft && isTransient(error) {
            try await Task.sleep(for: retryDelay)
            return try await attempt(for: request, retryLeft: false)
        }
    }

    private static func isTransient(_ error: URLError) -> Bool {
        switch error.code {
        case .timedOut, .networkConnectionLost, .notConnectedToInternet:
            return true
        default:
            return false
        }
    }
}
