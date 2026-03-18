import SwiftUI

struct PopoverContentView: View {
    @ObservedObject var viewModel: AppViewModel
    @StateObject private var usageVM = UsageViewModel()
    @StateObject private var qrCodeVM = QRCodeViewModel()
    @StateObject private var doctorVM = DoctorViewModel()

    /// Track previous tab index for slide direction
    @State private var previousTabIndex = 0

    var body: some View {
        VStack(spacing: 0) {
            HeaderView(viewModel: viewModel)
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 8)

            GlassTabBar(selectedTab: $viewModel.selectedTab)
                .padding(.horizontal, 16)
                .padding(.bottom, 4)

            // Content area with directional slide transition
            ZStack {
                switch viewModel.selectedTab {
                case .usage:
                    UsagePageView(viewModel: usageVM, bridgeStatus: viewModel.bridgeStatus)
                        .transition(slideTransition)
                case .qrCode:
                    QRCodePageView(viewModel: qrCodeVM)
                        .transition(slideTransition)
                case .doctor:
                    DoctorPageView(viewModel: doctorVM)
                        .transition(slideTransition)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .animation(.smooth(duration: 0.3), value: viewModel.selectedTab)
        }
        .frame(width: 380, height: 500)
        .onChange(of: viewModel.selectedTab) { oldTab, newTab in
            previousTabIndex = oldTab.rawValue
            switch newTab {
            case .usage:
                usageVM.fetchUsage()
            case .qrCode:
                qrCodeVM.refresh()
            case .doctor:
                if doctorVM.report == nil {
                    doctorVM.runDoctor()
                }
            }
        }
        .onChange(of: viewModel.bridgeStatus) { _, newStatus in
            if newStatus == .running && viewModel.selectedTab == .usage {
                usageVM.fetchUsage()
            }
        }
        .onAppear {
            usageVM.startAutoRefresh()
        }
        .onDisappear {
            usageVM.stopAutoRefresh()
        }
    }

    private var slideTransition: AnyTransition {
        let forward = viewModel.selectedTab.rawValue >= previousTabIndex
        return .push(from: forward ? .trailing : .leading)
    }
}

// MARK: - Glass Tab Bar

struct GlassTabBar: View {
    @Binding var selectedTab: AppTab
    @Namespace private var tabNamespace

    var body: some View {
        HStack(spacing: 2) {
            ForEach(AppTab.allCases) { tab in
                Button {
                    withAnimation(.smooth(duration: 0.25)) {
                        selectedTab = tab
                    }
                } label: {
                    Label(tab.label, systemImage: tab.icon)
                        .font(.subheadline.weight(.medium))
                        .padding(.vertical, 7)
                        .frame(maxWidth: .infinity)
                        .background {
                            if selectedTab == tab {
                                Capsule()
                                    .fill(.white.opacity(0.12))
                                    .matchedGeometryEffect(id: "activeTab", in: tabNamespace)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .foregroundStyle(selectedTab == tab ? .primary : .tertiary)
            }
        }
        .padding(3)
        .glassEffect(.regular, in: .capsule)
    }
}
