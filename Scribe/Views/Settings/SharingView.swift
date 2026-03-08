import SwiftUI
import CloudKit

struct SharingView: View {
    @State private var showingSharingController = false
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section {
                Text("Family sharing lets you share your budget with family members via iCloud. Everyone with access can view and confirm expenses.")
                    .foregroundStyle(ScribeTheme.secondaryText)
            }

            Section("Share Budget") {
                Button {
                    showingSharingController = true
                } label: {
                    Label("Invite Family Member", systemImage: "person.badge.plus")
                }

                if let share = ShareManager.shared.currentShare {
                    Button {
                        showingSharingController = true
                    } label: {
                        Label("Manage Sharing", systemImage: "person.2")
                    }
                }
            }

            Section("Participants") {
                let participants = ShareManager.shared.participants
                if participants.isEmpty {
                    ContentUnavailableView(
                        "No Participants",
                        systemImage: "person.2.slash",
                        description: Text("Share your budget to see participants here.")
                    )
                    .listRowBackground(Color.clear)
                } else {
                    ForEach(participants, id: \.userIdentity.lookupInfo?.emailAddress) { participant in
                        HStack {
                            Image(systemName: participant.role == .owner ? "star.circle.fill" : "person.circle.fill")
                                .foregroundStyle(participant.role == .owner ? ScribeTheme.accent : ScribeTheme.secondaryText)
                            VStack(alignment: .leading) {
                                Text(participant.userIdentity.nameComponents?.formatted() ?? "Unknown")
                                    .font(.body)
                                Text(participant.acceptanceStatus == .accepted ? "Accepted" : "Pending")
                                    .font(.caption)
                                    .foregroundStyle(ScribeTheme.secondaryText)
                            }
                            Spacer()
                            Text(participant.role == .owner ? "Owner" : "Member")
                                .font(.caption)
                                .foregroundStyle(ScribeTheme.secondaryText)
                        }
                    }
                }
            }

            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .foregroundStyle(ScribeTheme.error)
                        .font(.caption)
                }
            }
        }
        .navigationTitle("Family Sharing")
        .onAppear {
            Task {
                isLoading = true
                do {
                    try await ShareManager.shared.fetchExistingShare()
                } catch {
                    errorMessage = error.localizedDescription
                }
                isLoading = false
            }
        }
        .sheet(isPresented: $showingSharingController) {
            CloudSharingView(
                share: ShareManager.shared.currentShare,
                container: CloudKitManager.shared.container
            )
            .ignoresSafeArea()
        }
        .overlay {
            if isLoading {
                ProgressView()
            }
        }
    }
}

#Preview {
    NavigationStack {
        SharingView()
    }
}
