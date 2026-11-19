import SwiftUI

@main
struct REAApp: App {
    @StateObject private var session = REASession()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(session)
                .preferredColorScheme(.dark)
        }
    }
}

@MainActor
final class REASession: ObservableObject {
    @Published var serverURL = UserDefaults.standard.string(forKey: "rea.serverURL") ?? "http://127.0.0.1:8787"
    @Published var status = "Não conectado"
    @Published var detail = "Configure o endereço do servidor REA."
    @Published var isChecking = false
    @Published var selectedFileName: String?

    func saveServer() {
        UserDefaults.standard.set(serverURL, forKey: "rea.serverURL")
    }

    func checkConnection() async {
        guard let base = URL(string: serverURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            status = "Endereço inválido"
            detail = "Informe uma URL HTTP ou HTTPS válida."
            return
        }
        isChecking = true
        defer { isChecking = false }
        var request = URLRequest(url: base.appendingPathComponent("health"))
        request.timeoutInterval = 12
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            guard (200..<300).contains(http.statusCode) else {
                status = "Servidor respondeu: \(http.statusCode)"
                detail = String(data: data, encoding: .utf8) ?? "Resposta sem texto."
                return
            }
            status = "Conectado"
            detail = String(data: data, encoding: .utf8) ?? "Servidor REA disponível."
        } catch {
            status = "Sem conexão"
            detail = "Não foi possível acessar /health. Verifique se o bridge REA está ativo e acessível. \(error.localizedDescription)"
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var session: REASession
    @State private var showingImporter = false
    @State private var importedURL: URL?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("REA").font(.system(size: 38, weight: .bold, design: .rounded))
                        Text("Reverse Engineering Assistant").foregroundStyle(.secondary)
                    }
                    connectionCard
                    VStack(alignment: .leading, spacing: 12) {
                        Label("Analisar arquivo", systemImage: "doc.zipper").font(.headline)
                        Text("Importe um IPA, framework ou binário para preparar uma análise pelo servidor REA.")
                            .font(.subheadline).foregroundStyle(.secondary)
                        Button { showingImporter = true } label: {
                            Label("Importar arquivo", systemImage: "square.and.arrow.down")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        if let name = session.selectedFileName {
                            Label(name, systemImage: "checkmark.circle.fill")
                                .font(.footnote).foregroundStyle(.green)
                        }
                        Text("A análise real depende de um servidor REA conectado. O app não finge executar Ghidra ou ferramentas que não estão instaladas.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding().background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Ferramentas", systemImage: "wrench.and.screwdriver").font(.headline)
                        feature("Importação de IPA e binários", "doc")
                        feature("Conexão com bridge HTTP", "network")
                        feature("Análises e resultados", "waveform.path")
                        feature("Histórico de sessões", "clock")
                        Text("As funções de análise e histórico serão habilitadas pela integração com o backend REA.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding().background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
                }
                .padding()
            }
            .navigationTitle("Workspace")
            .navigationBarTitleDisplayMode(.inline)
            .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.item], allowsMultipleSelection: false) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first else { return }
                    let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    session.selectedFileName = url.lastPathComponent
                    importedURL = url
                case .failure(let error):
                    session.status = "Falha ao importar"
                    session.detail = error.localizedDescription
                }
            }
        }
    }

    private var connectionCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Servidor REA", systemImage: "server.rack").font(.headline)
                Spacer()
                Circle().fill(session.status == "Conectado" ? .green : .orange).frame(width: 8, height: 8)
            }
            TextField("https://seu-servidor.example", text: $session.serverURL)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                .autocorrectionDisabled()
                .textFieldStyle(.roundedBorder)
                .onSubmit { session.saveServer() }
            Button {
                session.saveServer()
                Task { await session.checkConnection() }
            } label: {
                HStack {
                    if session.isChecking { ProgressView().tint(.white) }
                    Text(session.isChecking ? "Verificando..." : "Testar conexão")
                }.frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(session.isChecking)
            Text(session.status).font(.subheadline.weight(.semibold))
            Text(session.detail).font(.caption).foregroundStyle(.secondary)
        }
        .padding().background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
    }

    private func feature(_ title: String, _ icon: String) -> some View {
        Label(title, systemImage: icon).font(.subheadline).foregroundStyle(.secondary)
    }
}
