import SwiftUI
import UIKit
import UniformTypeIdentifiers

@main struct REAApp: App {
    @StateObject private var session = REASession()
    var body: some Scene { WindowGroup { ContentView().environmentObject(session).preferredColorScheme(.dark) } }
}

@MainActor final class REASession: ObservableObject {
    @Published var serverURL = UserDefaults.standard.string(forKey: "rea.serverURL") ?? ""
    @Published var token = ""
    @Published var status = "Não conectado"
    @Published var detail = "Configure o endereço HTTPS do backend."
    @Published var busy = false
    @Published var tools: [[String: Any]] = []
    @Published var selectedTool = ""
    @Published var argumentsJSON = "{}"
    @Published var uploadedPath = ""
    @Published var uploadedName = ""
    @Published var resultText = ""

    private func endpoint(_ path: String) throws -> URL {
        guard let base = URL(string: serverURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              base.scheme?.lowercased() == "https", base.host != nil else {
            throw NSError(domain: "REA", code: 1, userInfo: [NSLocalizedDescriptionKey: "Informe a URL HTTPS pública do backend."])
        }
        return base.appendingPathComponent(path)
    }
    private func authorizedRequest(_ path: String, method: String = "GET") throws -> URLRequest {
        guard !token.isEmpty else { throw NSError(domain: "REA", code: 401, userInfo: [NSLocalizedDescriptionKey: "Informe o token de acesso do backend."]) }
        var request = URLRequest(url: try endpoint(path))
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 300
        return request
    }
    func testConnection() async {
        busy = true; defer { busy = false }
        do {
            let request = URLRequest(url: try endpoint("health"), timeoutInterval: 15)
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw NSError(domain: "REA", code: 503, userInfo: [NSLocalizedDescriptionKey: String(data: data, encoding: .utf8) ?? "Backend indisponível."])
            }
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let state = object?["status"] as? String ?? "unknown"
            status = state == "ready" ? "Backend REA pronto" : "Backend iniciando"
            detail = "\(object?["service"] as? String ?? "REA") · \(object?["transport"] as? String ?? "MCP")"
            UserDefaults.standard.set(serverURL, forKey: "rea.serverURL")
            if state == "ready" { await discoverTools() }
        } catch { status = "Sem conexão"; detail = error.localizedDescription }
    }
    func discoverTools() async {
        do {
            let request = try authorizedRequest("api/tools")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw NSError(domain: "REA", code: 502, userInfo: [NSLocalizedDescriptionKey: String(data: data, encoding: .utf8) ?? "Falha no catálogo MCP."])
            }
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            tools = object?["tools"] as? [[String: Any]] ?? []
            if !tools.contains(where: { ($0["name"] as? String) == selectedTool }) { selectedTool = tools.first?["name"] as? String ?? "" }
            detail = "\(tools.count) ferramentas recebidas do catálogo MCP oficial."
        } catch { detail = "Catálogo indisponível: \(error.localizedDescription)" }
    }
    func upload(_ source: URL) async {
        busy = true; defer { busy = false }
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "-" + source.lastPathComponent)
        do {
            try FileManager.default.copyItem(at: source, to: temporary)
            defer { try? FileManager.default.removeItem(at: temporary) }
            var components = URLComponents(url: try endpoint("api/upload"), resolvingAgainstBaseURL: false)!
            components.queryItems = [URLQueryItem(name: "filename", value: source.lastPathComponent)]
            var request = try authorizedRequest("api/upload", method: "POST")
            request.url = components.url
            request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            let (data, response) = try await URLSession.shared.upload(for: request, fromFile: temporary)
            guard let http = response as? HTTPURLResponse, http.statusCode == 201 else {
                throw NSError(domain: "REA", code: 422, userInfo: [NSLocalizedDescriptionKey: String(data: data, encoding: .utf8) ?? "Upload recusado."])
            }
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let upload = object?["upload"] as? [String: Any]
            guard let path = upload?["path"] as? String else { throw URLError(.cannotParseResponse) }
            uploadedPath = path; uploadedName = source.lastPathComponent
            status = "Arquivo enviado ao backend"
            detail = "Selecione uma ferramenta compatível e use o caminho retornado nos argumentos dela."
            await discoverTools()
        } catch { status = "Falha no upload"; detail = error.localizedDescription }
    }
    func callSelectedTool() async {
        guard !selectedTool.isEmpty else { return }
        busy = true; defer { busy = false }
        do {
            let argsData = Data(argumentsJSON.utf8)
            guard let args = try JSONSerialization.jsonObject(with: argsData) as? [String: Any] else {
                throw NSError(domain: "REA", code: 400, userInfo: [NSLocalizedDescriptionKey: "Argumentos precisam ser um objeto JSON."])
            }
            var request = try authorizedRequest("api/tools/call", method: "POST")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["name": selectedTool, "arguments": args])
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw NSError(domain: "REA", code: 502, userInfo: [NSLocalizedDescriptionKey: String(data: data, encoding: .utf8) ?? "A ferramenta REA retornou erro."])
            }
            let value = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
            let pretty = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed])
            resultText = String(data: pretty, encoding: .utf8) ?? "Resultado recebido."
            status = "Ferramenta executada"; detail = "Resposta retornada pelo servidor MCP."
        } catch { status = "Execução não concluída"; detail = error.localizedDescription }
    }
    var selectedSchema: String {
        guard let item = tools.first(where: { ($0["name"] as? String) == selectedTool }), let schema = item["inputSchema"],
              let data = try? JSONSerialization.data(withJSONObject: schema, options: [.prettyPrinted, .sortedKeys]) else { return "Esquema indisponível." }
        return String(data: data, encoding: .utf8) ?? ""
    }
}

struct ContentView: View {
    @EnvironmentObject private var session: REASession
    @State private var importing = false
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 4) { Text("REA").font(.system(size: 36, weight: .bold, design: .rounded)); Text("Reverse Engineering Assistant").foregroundStyle(.secondary) }
                    connectionCard
                    GroupBox {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Importar artefato").font(.headline)
                            Button { importing = true } label: { Label("Importar IPA, framework ou binário", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity) }.buttonStyle(.borderedProminent).disabled(session.busy)
                            if !session.uploadedName.isEmpty { Text(session.uploadedName).foregroundStyle(.green); Text(session.uploadedPath).font(.system(.caption2, design: .monospaced)).textSelection(.enabled) }
                            Text("O arquivo é enviado ao backend configurado. A importação não executa uma análise por si só.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    GroupBox {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack { Text("Ferramentas MCP reais").font(.headline); Spacer(); Button("Atualizar") { Task { await session.discoverTools() } }.font(.caption) }
                            if session.tools.isEmpty { Text("Conecte o backend para descobrir o catálogo.").font(.caption).foregroundStyle(.secondary) }
                            else {
                                Picker("Ferramenta", selection: $session.selectedTool) { ForEach(session.tools.compactMap { $0["name"] as? String }, id: \.self) { Text($0).tag($0) } }
                                Text("Esquema de entrada").font(.subheadline.weight(.semibold))
                                ScrollView(.horizontal) { Text(session.selectedSchema).font(.system(.caption2, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                                Text("Argumentos JSON").font(.subheadline.weight(.semibold))
                                TextEditor(text: $session.argumentsJSON).font(.system(.caption, design: .monospaced)).frame(minHeight: 120).scrollContentBackground(.hidden).padding(6).background(.black.opacity(0.2), in: RoundedRectangle(cornerRadius: 8))
                                if !session.uploadedPath.isEmpty { Button("Copiar caminho do arquivo") { UIPasteboard.general.string = session.uploadedPath }.font(.caption) }
                                Button { Task { await session.callSelectedTool() } } label: { Label("Executar ferramenta REA", systemImage: "play.fill").frame(maxWidth: .infinity) }.buttonStyle(.borderedProminent).disabled(session.busy || session.selectedTool.isEmpty)
                            }
                        }
                    }
                    if !session.resultText.isEmpty { GroupBox("Resultado retornado pelo REA") { Text(session.resultText).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) } }
                    if session.busy { ProgressView().frame(maxWidth: .infinity) }
                }.padding()
            }.navigationTitle("Workspace").navigationBarTitleDisplayMode(.inline)
            .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: false) { result in
                switch result { case .success(let urls): if let url = urls.first { Task { await session.upload(url) } }; case .failure(let error): session.status = "Falha ao importar"; session.detail = error.localizedDescription }
            }
        }
    }
    private var connectionCard: some View {
        GroupBox { VStack(alignment: .leading, spacing: 10) {
            Label("Servidor REA", systemImage: "server.rack").font(.headline)
            TextField("https://seu-backend.example", text: $session.serverURL).textInputAutocapitalization(.never).keyboardType(.URL).autocorrectionDisabled().textFieldStyle(.roundedBorder)
            SecureField("Token de acesso", text: $session.token).textInputAutocapitalization(.never).autocorrectionDisabled().textFieldStyle(.roundedBorder)
            Button { Task { await session.testConnection() } } label: { Label("Testar conexão e carregar ferramentas", systemImage: "network").frame(maxWidth: .infinity) }.buttonStyle(.bordered).disabled(session.busy)
            Text(session.status).font(.subheadline.weight(.semibold)); Text(session.detail).font(.caption).foregroundStyle(.secondary)
        } }
    }
}