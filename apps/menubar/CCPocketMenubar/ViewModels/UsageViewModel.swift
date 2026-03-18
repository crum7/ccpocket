import Foundation
import SwiftUI

@MainActor
final class UsageViewModel: ObservableObject {
    @Published var providers: [UsageInfo] = []
    @Published var isLoading = false
    @Published var error: String?

    private let bridgeClient = BridgeClient()
    private var refreshTimer: Timer?

    func startAutoRefresh() {
        // Don't fetch immediately — let onChange(bridgeStatus) trigger the first fetch
        // once bridge is confirmed running
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.fetchUsage()
            }
        }
    }

    func stopAutoRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    func fetchUsage() {
        guard !isLoading else { return }
        isLoading = true
        error = nil

        Task {
            do {
                let response = try await bridgeClient.usage()
                providers = response.providers
                error = nil
            } catch {
                // Only show error if we had no previous data
                if providers.isEmpty {
                    self.error = "Failed to load usage data"
                }
            }
            isLoading = false
        }
    }
}
