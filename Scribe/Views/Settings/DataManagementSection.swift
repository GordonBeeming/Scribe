import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct DataManagementSection: View {
    @Environment(\.modelContext) private var modelContext

    @State private var showDemoDataAlert = false
    @State private var showClearConfirmation = false
    @State private var showShareSheet = false
    @State private var showFileImporter = false
    @State private var showImportModeAlert = false
    @State private var showSuccessAlert = false
    @State private var showErrorAlert = false
    @State private var successMessage = ""
    @State private var errorMessage = ""
    @State private var exportFileURL: URL?
    @State private var importData: Data?

    var body: some View {
        Section("Data Management") {
            // Generate Demo Data
            Button {
                if DataManagementService.hasExistingData(in: modelContext) {
                    showDemoDataAlert = true
                } else {
                    generateDemoData()
                }
            } label: {
                Label("Generate Demo Data", systemImage: "wand.and.stars")
            }
            .alert("Generate Demo Data", isPresented: $showDemoDataAlert) {
                Button("Add Demo Data") { generateDemoData() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("You already have existing data. Demo data will be added alongside your current data.")
            }

            // Clear All Data
            Button(role: .destructive) {
                showClearConfirmation = true
            } label: {
                Label("Clear All Data", systemImage: "trash")
            }
            .confirmationDialog("Clear All Data", isPresented: $showClearConfirmation, titleVisibility: .visible) {
                Button("Delete All Data", role: .destructive) {
                    DataManagementService.clearAllData(in: modelContext)
                    successMessage = "All data has been cleared."
                    showSuccessAlert = true
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will permanently delete all budget items, overrides, occurrences, and family members. This action cannot be undone.")
            }

            // Export Data
            Button {
                exportData()
            } label: {
                Label("Export Data", systemImage: "square.and.arrow.up")
            }
            .sheet(isPresented: $showShareSheet) {
                if let url = exportFileURL {
                    ActivityViewRepresentable(activityItems: [url])
                }
            }

            // Import Data
            Button {
                showFileImporter = true
            } label: {
                Label("Import Data", systemImage: "square.and.arrow.down")
            }
            .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.json]) { result in
                handleFileImport(result)
            }
            .alert("Import Mode", isPresented: $showImportModeAlert) {
                Button("Merge") { performImport(mode: .merge) }
                Button("Replace") { performImport(mode: .replace) }
                Button("Cancel", role: .cancel) { importData = nil }
            } message: {
                Text("Merge will update existing records and add new ones. Replace will clear all current data first.")
            }
        }
        .alert("Success", isPresented: $showSuccessAlert) {
            Button("OK") {}
        } message: {
            Text(successMessage)
        }
        .alert("Error", isPresented: $showErrorAlert) {
            Button("OK") {}
        } message: {
            Text(errorMessage)
        }
    }

    private func generateDemoData() {
        DemoDataGenerator.generate(in: modelContext)
        successMessage = "Demo data has been generated."
        showSuccessAlert = true
    }

    private func exportData() {
        do {
            let data = try DataManagementService.exportData(from: modelContext)
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            let fileName = "Scribe-Export-\(formatter.string(from: Date())).json"
            let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
            try data.write(to: tempURL)
            exportFileURL = tempURL
            showShareSheet = true
        } catch {
            errorMessage = "Failed to export: \(error.localizedDescription)"
            showErrorAlert = true
        }
    }

    private func handleFileImport(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            guard url.startAccessingSecurityScopedResource() else {
                errorMessage = "Unable to access the selected file."
                showErrorAlert = true
                return
            }
            defer { url.stopAccessingSecurityScopedResource() }

            do {
                importData = try Data(contentsOf: url)
                showImportModeAlert = true
            } catch {
                errorMessage = "Failed to read file: \(error.localizedDescription)"
                showErrorAlert = true
            }
        case .failure(let error):
            errorMessage = "Failed to select file: \(error.localizedDescription)"
            showErrorAlert = true
        }
    }

    private func performImport(mode: ImportMode) {
        guard let data = importData else { return }
        do {
            try DataManagementService.importData(data, into: modelContext, mode: mode)
            successMessage = "Data imported successfully."
            showSuccessAlert = true
        } catch {
            errorMessage = "Failed to import: \(error.localizedDescription)"
            showErrorAlert = true
        }
        importData = nil
    }
}
