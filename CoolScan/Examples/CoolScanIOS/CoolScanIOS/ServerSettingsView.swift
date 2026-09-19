import SwiftUI

/// Where scans get reconstructed: servers found on the network, a manual
/// address, the detail preset, and a connection test.
struct ServerSettingsView: View {
    @ObservedObject var discovery: ServerDiscovery
    @Environment(\.dismiss) private var dismiss

    @State private var manualAddress = ServerSettings.manualBaseURL?.absoluteString ?? ""
    @State private var detail = ServerSettings.options.detail
    @State private var testResult: String?
    @State private var testing = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if discovery.servers.isEmpty {
                        Text(discovery.statusText)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(discovery.servers) { server in
                        Button {
                            Task { await pin(server) }
                        } label: {
                            Label(server.name, systemImage: "desktopcomputer")
                        }
                    }
                } header: {
                    Text("Found on this network")
                } footer: {
                    Text("Run `swift run CoolScanServer` in CoolScan/Server on a Mac on the same Wi‑Fi. Tap a server to pin its address.")
                }

                Section("Address") {
                    TextField("http://192.168.1.20:8787", text: $manualAddress)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit(saveManual)
                    Button(testing ? "Testing…" : "Test connection") {
                        Task { await test() }
                    }
                    .disabled(testing || manualAddress.isEmpty)
                    if let testResult {
                        Text(testResult)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    Picker("Detail", selection: $detail) {
                        ForEach(RemoteReconstructionOptions.Detail.allCases) { option in
                            Text(option.label).tag(option)
                        }
                    }
                    .onChange(of: detail) { _, value in
                        var options = ServerSettings.options
                        options.detail = value
                        ServerSettings.options = options
                    }
                } header: {
                    Text("Reconstruction on the Mac")
                } footer: {
                    Text("Full is Apple's highest preset (millions of triangles, 8K textures; textures are reduced to 2K for the phone). Custom keeps 250k triangles and 2K maps.")
                }
            }
            .navigationTitle("Mac server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        saveManual()
                        dismiss()
                    }
                }
            }
            .onAppear { discovery.start() }
        }
    }

    private func saveManual() {
        let trimmed = manualAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            ServerSettings.manualBaseURL = nil
        } else if let url = URL(string: trimmed.hasPrefix("http") ? trimmed : "http://" + trimmed) {
            ServerSettings.manualBaseURL = url
            manualAddress = url.absoluteString
        }
    }

    private func pin(_ server: DiscoveredServer) async {
        do {
            let url = try await ServerDiscovery.resolve(server)
            manualAddress = url.absoluteString
            saveManual()
            await test()
        } catch {
            testResult = "Could not resolve \(server.name): \(error.localizedDescription)"
        }
    }

    private func test() async {
        saveManual()
        guard let url = ServerSettings.manualBaseURL else { return }
        testing = true
        defer { testing = false }
        do {
            let health = try await ServerClient(baseURL: url).health()
            testResult = "\(health.serverName): OK · photogrammetry \(health.photogrammetrySupported ? "available" : "NOT available") · default \(health.defaultDetail)"
        } catch {
            testResult = "Failed: \(error.localizedDescription)"
        }
    }

    /// Resolves the server to use right now: the pinned address first, then
    /// the first discovered one.
    @MainActor
    static func currentClient(discovery: ServerDiscovery) async -> ServerClient? {
        if let url = ServerSettings.manualBaseURL {
            let client = ServerClient(baseURL: url)
            if (try? await client.health()) != nil { return client }
        }
        for server in discovery.servers {
            if let url = try? await ServerDiscovery.resolve(server) {
                let client = ServerClient(baseURL: url)
                if (try? await client.health()) != nil { return client }
            }
        }
        return nil
    }
}
