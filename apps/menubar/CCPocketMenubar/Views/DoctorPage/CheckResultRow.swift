import SwiftUI

struct CheckResultRow: View {
    let check: CheckResult
    let onAction: (() -> Void)?
    var onProviderLogin: ((String) -> Void)?
    var onProviderInstall: ((String) -> Void)?
    var onCopyCommands: (() -> Void)?
    var onOpenTerminal: (() -> Void)?

    private var statusColor: Color {
        switch check.status {
        case "pass": return .green
        case "fail": return .red
        case "warn": return .orange
        default: return .secondary
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: check.statusIcon)
                    .foregroundStyle(statusColor)
                    .font(.body)
                    .contentTransition(.symbolEffect(.replace))

                Text(check.localizedName)
                    .font(.subheadline.weight(.medium))

                Spacer()

                Text(check.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            // Provider sub-items
            if let providers = check.providers {
                ForEach(providers) { provider in
                    HStack(spacing: 8) {
                        Image(systemName: providerIcon(provider))
                            .foregroundStyle(providerColor(provider))
                            .font(.caption)

                        Text(provider.name)
                            .font(.caption)

                        Spacer()

                        // Install button for uninstalled providers
                        if !provider.installed {
                            Button {
                                onProviderInstall?(provider.name)
                            } label: {
                                Label("Install", systemImage: "arrow.down.circle")
                                    .font(.caption2)
                            }
                            .controlSize(.small)
                            .buttonStyle(.borderedProminent)
                            .tint(.accentColor)
                        }

                        // Login button for installed but unauthenticated providers
                        if provider.installed && !provider.authenticated {
                            Button {
                                onProviderLogin?(provider.name)
                            } label: {
                                Label("Login", systemImage: "person.badge.key")
                                    .font(.caption2)
                            }
                            .controlSize(.small)
                            .buttonStyle(.borderedProminent)
                            .tint(.orange)
                        }

                        Text(providerStatus(provider))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.leading, 24)
                }
            }

            // Remediation with terminal guide
            if check.status == "fail" || check.status == "warn" {
                VStack(alignment: .leading, spacing: 6) {
                    if let remediation = check.remediation {
                        Text(remediation)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 6) {
                        if let onCopyCommands {
                            Button {
                                onCopyCommands()
                            } label: {
                                Label(String(localized: "Copy"), systemImage: "doc.on.doc")
                                    .font(.caption2)
                            }
                            .controlSize(.mini)
                            .buttonStyle(.bordered)
                        }

                        if let onOpenTerminal {
                            Button {
                                onOpenTerminal()
                            } label: {
                                Label(String(localized: "Terminal"), systemImage: "terminal")
                                    .font(.caption2)
                            }
                            .controlSize(.mini)
                            .buttonStyle(.borderedProminent)
                        }

                        if let action = onAction {
                            Button("Fix", action: action)
                                .controlSize(.mini)
                                .buttonStyle(.borderedProminent)
                                .tint(.accentColor)
                        }
                    }
                }
                .padding(.leading, 24)
            }
        }
    }

    private func providerIcon(_ p: ProviderResult) -> String {
        if !p.installed { return "minus.circle" }
        if !p.authenticated { return "exclamationmark.triangle.fill" }
        return "checkmark.circle.fill"
    }

    private func providerColor(_ p: ProviderResult) -> Color {
        if !p.installed { return .secondary }
        if !p.authenticated { return .orange }
        return .green
    }

    private func providerStatus(_ p: ProviderResult) -> String {
        if !p.installed { return String(localized: "Not installed") }
        var parts: [String] = []
        if let v = p.version { parts.append(v) }
        parts.append(p.authenticated ? String(localized: "authenticated") : (p.authMessage ?? String(localized: "not authenticated")))
        return parts.joined(separator: " · ")
    }
}
