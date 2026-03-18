import AppKit
import SwiftUI

struct OnboardingView: View {
    @ObservedObject var doctorVM: DoctorViewModel
    var onComplete: () -> Void

    @State private var currentStep = 0

    private var steps: [(icon: String, title: String, description: String)] {
        [
            ("hand.wave.fill", String(localized: "Welcome to CC Pocket"), String(localized: "Manage your Bridge Server, monitor usage, and connect your mobile device — all from the menu bar.")),
            ("stethoscope", String(localized: "Environment Check"), String(localized: "Let's make sure everything is set up correctly.")),
            ("checkmark.seal.fill", String(localized: "You're All Set!"), String(localized: "Your environment is ready. You can always re-run Doctor from the Doctor tab if needed.")),
        ]
    }

    var body: some View {
        VStack(spacing: 0) {
            // Step indicator
            HStack(spacing: 6) {
                ForEach(0..<steps.count, id: \.self) { index in
                    Capsule()
                        .fill(index <= currentStep ? Color.accentColor : .white.opacity(0.15))
                        .frame(width: index == currentStep ? 20 : 8, height: 4)
                        .animation(.smooth, value: currentStep)
                }
            }
            .padding(.top, 20)
            .padding(.bottom, 16)

            if currentStep == 0 {
                welcomeStep
            } else if currentStep == 1 {
                doctorStep
            } else {
                doneStep
            }
        }
    }

    // MARK: - Step 0: Welcome

    private var welcomeStep: some View {
        VStack(spacing: 0) {
            VStack(spacing: 16) {
                Image(systemName: steps[0].icon)
                    .font(.system(size: 40))
                    .foregroundStyle(Color.accentColor)
                    .symbolEffect(.bounce, value: currentStep)

                Text(steps[0].title)
                    .font(.title3.weight(.semibold))

                Text(steps[0].description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 20)

            Spacer()

            Button("Get Started") {
                withAnimation { currentStep = 1 }
                doctorVM.runDoctor()
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal, 24)
            .padding(.bottom, 20)
        }
    }

    // MARK: - Step 1: Doctor (Main)

    private var doctorStep: some View {
        VStack(spacing: 0) {
            // Header
            VStack(spacing: 8) {
                Image(systemName: steps[1].icon)
                    .font(.system(size: 32))
                    .foregroundStyle(Color.accentColor)

                Text(steps[1].title)
                    .font(.title3.weight(.semibold))

                Text(steps[1].description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)

            // Scrollable step list
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if doctorVM.isRunning && doctorVM.report == nil {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Running checks…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 16)
                    } else if let report = doctorVM.report {
                        setupStepList(report: report)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 12)
            }

            // Fixed bottom bar
            bottomBar
        }
    }

    // MARK: - Step List (flattened numbered steps)

    @ViewBuilder
    private func setupStepList(report: DoctorReport) -> some View {
        let allSteps = buildStepList(report: report)

        ForEach(Array(allSteps.enumerated()), id: \.offset) { index, step in
            stepRow(step: step, number: index + 1)
                .padding(.vertical, 4)
        }

        // Error / progress
        if let error = doctorVM.actionError {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(.caption2)
                .foregroundStyle(.red)
                .padding(.top, 4)
        }

        if let action = doctorVM.actionInProgress {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.mini)
                Text(action)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 4)
        }
    }

    // MARK: - Row Components

    @ViewBuilder
    private func stepRow(step: SetupStep, number: Int) -> some View {
        HStack(alignment: .top, spacing: 8) {
            // Badge: green check if passed, numbered circle if pending
            if step.isPassed {
                Image(systemName: "checkmark")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 18, height: 18)
                    .background(.green, in: .circle)
            } else {
                Text("\(number)")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 18, height: 18)
                    .background(Color.accentColor, in: .circle)
            }

            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(step.commands.enumerated()), id: \.element.id) { idx, cmd in
                    if idx > 0 {
                        Text(String(localized: "or"))
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, alignment: .center)
                    }

                    Text(cmd.comment)
                        .font(.caption2)
                        .foregroundStyle(cmd.isPassed ? .tertiary : .secondary)

                    CommandRow(command: cmd.command) {
                        #if DEBUG
                        doctorVM.markCommandCompleted(cmd.command)
                        #endif
                    }
                    .opacity(cmd.isPassed ? 0.5 : 1)
                }
            }
        }
    }

    // MARK: - Bottom Bar (pinned)

    private var bottomBar: some View {
        VStack(spacing: 8) {
            Divider()

            // Terminal + Re-check (always visible)
            HStack(spacing: 8) {
                Button {
                    doctorVM.openSetupTerminal()
                } label: {
                    Label(String(localized: "Open Terminal"), systemImage: "terminal")
                        .font(.caption)
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.small)
                .buttonStyle(.bordered)

                Button {
                    doctorVM.runDoctor()
                } label: {
                    Label(String(localized: "Re-check"), systemImage: "arrow.clockwise")
                        .font(.caption)
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
                .disabled(doctorVM.isRunning)
            }

            // Navigation
            HStack {
                Button("Back") {
                    withAnimation { currentStep -= 1 }
                }
                .buttonStyle(.borderless)
                .font(.caption)

                Spacer()

                Button(doctorVM.allPassed ? String(localized: "Continue") : String(localized: "Continue Anyway")) {
                    withAnimation { currentStep = 2 }
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .disabled(doctorVM.isRunning)
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
    }

    // MARK: - Step 2: Done

    private var doneStep: some View {
        VStack(spacing: 0) {
            VStack(spacing: 16) {
                Image(systemName: steps[2].icon)
                    .font(.system(size: 40))
                    .foregroundStyle(.green)
                    .symbolEffect(.bounce, value: currentStep)

                Text(steps[2].title)
                    .font(.title3.weight(.semibold))

                Text(steps[2].description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 20)

            Spacer()

            Button("Open CC Pocket") {
                onComplete()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal, 24)
            .padding(.bottom, 20)
        }
    }

    // MARK: - Step Builder

    private struct SetupCommand: Identifiable {
        let id = UUID()
        let comment: String
        let command: String
        let isPassed: Bool
    }

    private struct SetupStep {
        /// Multiple commands = "pick one" (shown with "or" separator)
        let commands: [SetupCommand]

        var isPassed: Bool {
            commands.contains { $0.isPassed }
        }
    }

    private func buildStepList(report: DoctorReport) -> [SetupStep] {
        var steps: [SetupStep] = []
        var seenChecks: Set<String> = []

        for check in report.results {
            // Bridge Server and launchd share the same command — deduplicate
            let groupKey: String
            if check.name == "Bridge Server" || check.name == "launchd service" {
                groupKey = "bridge"
            } else {
                groupKey = check.name
            }
            guard !seenChecks.contains(groupKey) else { continue }
            seenChecks.insert(groupKey)

            let commands = doctorVM.allSetupCommands(for: check)
            guard !commands.isEmpty else { continue }

            let checkPassed = check.status == "pass"
            let isPickOne = check.name == "CLI providers" && commands.count > 1

            if isPickOne {
                // Group all commands into one step (pick one)
                let cmds = commands.map { entry -> SetupCommand in
                    #if DEBUG
                    let done = doctorVM.completedCommands.contains(entry.command)
                    return SetupCommand(comment: entry.comment, command: entry.command, isPassed: checkPassed || done)
                    #else
                    return SetupCommand(comment: entry.comment, command: entry.command, isPassed: checkPassed)
                    #endif
                }
                steps.append(SetupStep(commands: cmds))
            } else {
                // One command per step
                for entry in commands {
                    #if DEBUG
                    let done = doctorVM.completedCommands.contains(entry.command)
                    let passed = checkPassed || done
                    #else
                    let passed = checkPassed
                    #endif
                    steps.append(SetupStep(commands: [
                        SetupCommand(comment: entry.comment, command: entry.command, isPassed: passed),
                    ]))
                }
            }
        }

        return steps
    }
}

// MARK: - Command Row (reusable)

struct CommandRow: View {
    let command: String
    var onCopied: (() -> Void)?

    @State private var copied = false

    var body: some View {
        HStack(spacing: 4) {
            Text(command)
                .font(.system(.caption2, design: .monospaced))
                .textSelection(.enabled)

            Spacer(minLength: 4)

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
                copied = true
                onCopied?()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    copied = false
                }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.caption2)
                    .frame(width: 16, height: 16)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(copied ? .green : .secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.black.opacity(0.2), in: .rect(cornerRadius: 6))
    }
}
