import SwiftUI
import UniformTypeIdentifiers

struct ToolInfo: Decodable, Identifiable {
    let name: String
    let description: String?
    let inputSchema: JSONValue?
    var id: String { name }
}

struct ToolsResponse: Decodable { let tools: [ToolInfo] }

indirect enum JSONValue: Codable {
    case object([String: JSONValue]), array([JSONValue]), string(String), number(Double), bool(Bool), null
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([String: JSONValue].self) { self = .object(v) }
        else { self = .array(try c.decode([JSONValue].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
}

struct ContentView: View {
    @State private var server = UserDefaults.standard.string(forKey: "server") ?? "https://rea-bridge-vt6z.onrender.com"
    @State private var token = ""
    @State private var tools: [ToolInfo] = []
    @State private var selectedTool = ""
    @State private var arguments = "{}"
    @State private var result = "Conecte ao REA para descobrir as ferramentas disponíveis."
    @State private var selectedFile: URL?
    @State private var uploadPath = ""
    @State private var busy = false
    @State private var showImporter = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Servidor seguro") {
                    TextField("URL HTTPS do servidor", text: $server).textInputAutocapitalization(.never).keyboardType(.URL)
                    SecureField("Token de acesso", text: $token)
                    Button("Conectar e descobrir ferramentas", action: discoverTools).disabled(busy || token.isEmpty)
                }
                Section("Arquivo para análise") {
                    Button("Selecionar IPA ou arquivo", systemImage: "doc.badge.plus") { showImporter = true }
                    if let selectedFile { Text(selectedFile.lastPathComponent).font(.footnote) }
                    Button("Enviar arquivo ao servidor", action: uploadFile).disabled(selectedFile == nil || busy)
                    if !uploadPath.isEmpty { Text("Arquivo temporário: \\(uploadPath)").font(.caption).textSelection(.enabled) }
                }
                Section("Ferramentas MCP reais") {
                    if tools.isEmpty { Text("Nenhuma ferramenta descoberta ainda.").foregroundStyle(.secondary) }
                    else {
                        Picker("Ferramenta", selection: $selectedTool) {
                            ForEach(tools) { tool in Text(tool.name).tag(tool.name) }
                        }
                        if let tool = tools.first(where: { $0.name == selectedTool }), let description = tool.description {
                            Text(description).font(.caption).foregroundStyle(.secondary)
                        }
                        Text("Argumentos JSON").font(.caption)
                        TextEditor(text: $arguments).frame(minHeight: 120).font(.system(.footnote, design: .monospaced))
                        Button("Executar ferramenta", action: callTool).disabled(busy || selectedTool.isEmpty)
                    }
                }
                Section("Resposta") {
                    if busy { ProgressView() }
                    Text(result).font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
                }
            }
            .navigationTitle("REA • Engenharia reversa")
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.item], allowsMultipleSelection: false) { outcome in
                switch outcome {
                case .success(let urls): selectedFile = urls.first
                case .failure(let error): result = error.localizedDescription
                }
            }
        }
    }

    private func request(_ path: String, method: String = "GET", body: Data? = nil) -> URLRequest? {
        guard let base = URL(string: server.trimmingCharacters(in: CharacterSet(charactersIn: "/"))),
              let url = URL(string: path, relativeTo: base) else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil { req.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        req.httpBody = body
        req.timeoutInterval = 180
        return req
    }

    private func discoverTools() {
        guard let req = request("/api/tools") else { result = "URL inválida"; return }
        busy = true
        UserDefaults.standard.set(server, forKey: "server")
        URLSession.shared.dataTask(with: req) { data, response, error in
            DispatchQueue.main.async {
                busy = false
                if let error { result = error.localizedDescription; return }
                guard let http = response as? HTTPURLResponse, let data else { result = "Resposta inválida"; return }
                guard (200..<300).contains(http.statusCode) else { result = "HTTP \(http.statusCode): \(String(data: data, encoding: .utf8) ?? "")"; return }
                do {
                    let decoded = try JSONDecoder().decode(ToolsResponse.self, from: data)
                    tools = decoded.tools
                    selectedTool = tools.first?.name ?? ""
                    result = "Conectado. \(tools.count) ferramentas MCP descobertas no REA."
                } catch { result = "Falha ao ler catálogo MCP: \(error.localizedDescription)" }
            }
        }.resume()
    }

    private func uploadFile() {
        guard let file = selectedFile, let base = URL(string: server) else { return }
        busy = true
        result = "Enviando arquivo…"
        DispatchQueue.global().async {
            let access = file.startAccessingSecurityScopedResource()
            defer { if access { file.stopAccessingSecurityScopedResource() } }
            do {
                let bytes = try Data(contentsOf: file)
                let boundary = UUID().uuidString
                var body = Data()
                body.append("--\(boundary)\r\n".data(using: .utf8)!)
                body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(file.lastPathComponent)\"\r\n".data(using: .utf8)!)
                body.append("Content-Type: application/octet-stream\r\n\r\n".data(using: .utf8)!)
                body.append(bytes)
                body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
                var req = URLRequest(url: base.appendingPathComponent("api/upload"))
                req.httpMethod = "POST"
                req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
                req.httpBody = body
                req.timeoutInterval = 300
                URLSession.shared.dataTask(with: req) { data, response, error in
                    DispatchQueue.main.async {
                        busy = false
                        if let error { result = error.localizedDescription; return }
                        guard let data else { result = "Sem resposta"; return }
                        let text = String(data: data, encoding: .utf8) ?? ""
                        if let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                            uploadPath = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["filePath"] as? String ?? ""
                            result = text
                            if !uploadPath.isEmpty {
                                arguments = "{\"filePath\": \"\(uploadPath)\"}"
                            }
                        } else { result = text }
                    }
                }.resume()
            } catch {
                DispatchQueue.main.async { busy = false; result = error.localizedDescription }
            }
        }
    }

    private func callTool() {
        guard let data = arguments.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let body = try? JSONSerialization.data(withJSONObject: ["arguments": json]),
              let req = request("/api/tools/\(selectedTool)/call", method: "POST", body: body) else {
            result = "Argumentos JSON inválidos"; return
        }
        busy = true
        URLSession.shared.dataTask(with: req) { data, response, error in
            DispatchQueue.main.async {
                busy = false
                if let error { result = error.localizedDescription; return }
                guard let data else { result = "Sem resposta"; return }
                result = String(data: data, encoding: .utf8) ?? "Resposta não textual"
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { result = "HTTP \(http.statusCode): " + result }
            }
        }.resume()
    }
}
