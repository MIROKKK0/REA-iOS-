import SwiftUI
import UniformTypeIdentifiers

struct ToolInfo: Decodable, Identifiable {
    let name: String
    let description: String?
    let inputSchema: JSONValue?
    var id: String { name }
    var schemaText: String {
        guard let inputSchema, let data = try? JSONEncoder.pretty.encode(inputSchema),
              let value = String(data: data, encoding: .utf8) else { return "Schema de entrada não informado." }
        return value
    }
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
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
    @State private var analysisMode = "IPA"
    @State private var targetURL = ""
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
                Section("Análise rápida") {
                    Picker("Quero analisar", selection: $analysisMode) {
                        Text("IPA / aplicativo").tag("IPA")
                        Text("Site / URL").tag("SITE")
                    }.pickerStyle(.segmented)
                    if analysisMode == "IPA" {
                        Button("Escolher IPA", systemImage: "doc.badge.plus") { showImporter = true }
                        if let selectedFile {
                            Label(selectedFile.lastPathComponent, systemImage: "doc")
                                .font(.footnote)
                                .lineLimit(2)
                        } else {
                            Text("Escolha um arquivo .ipa no app Arquivos.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } else {
                        TextField("https://exemplo.com", text: $targetURL)
                            .textInputAutocapitalization(.never).keyboardType(.URL)
                            .autocorrectionDisabled()
                    }
                    Button("Analisar automaticamente", systemImage: "sparkles", action: startAnalysis)
                        .disabled(busy || tools.isEmpty || (analysisMode == "IPA" && selectedFile == nil) || (analysisMode == "SITE" && targetURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                    if tools.isEmpty {
                        Text("Conecte primeiro para carregar as ferramentas disponíveis.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("Avançado") {
                    if let tool = tools.first(where: { $0.name == selectedTool }) {
                        Text("Ferramenta selecionada: \(tool.name)").font(.footnote)
                        DisclosureGroup("Descrição e schema") {
                            if let description = tool.description { Text(description).font(.caption) }
                            Text(tool.schemaText).font(.system(.caption2, design: .monospaced)).textSelection(.enabled)
                        }
                        TextEditor(text: $arguments).frame(minHeight: 100).font(.system(.footnote, design: .monospaced))
                        Button("Executar manualmente", action: callTool).disabled(busy)
                    } else {
                        Text("A seleção automática escolhe uma ferramenta compatível pelo nome, descrição e schema.")
                            .font(.caption).foregroundStyle(.secondary)
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
                                if let key = filePathArgumentName() {
                                    arguments = (try? String(data: JSONSerialization.data(withJSONObject: [key: uploadPath], options: [.prettyPrinted, .sortedKeys]), encoding: .utf8)) ?? "{}"
                                    result += "\nArquivo enviado. Caminho inserido em '\(key)'; complete os demais campos obrigatórios antes de executar."
                                } else {
                                    result += "\nUpload concluído, mas o schema da ferramenta selecionada não declara um campo de caminho de arquivo. Selecione uma ferramenta compatível com análise de arquivos."
                                }
                            }
                        } else { result = text }
                    }
                }.resume()
            } catch {
                DispatchQueue.main.async { busy = false; result = error.localizedDescription }
            }
        }
    }



    private func schemaParts(_ tool: ToolInfo) -> ([String: JSONValue], [String])? {
        guard case .object(let root)? = tool.inputSchema,
              case .object(let properties)? = root["properties"] else { return nil }
        let required: [String]
        if case .array(let values)? = root["required"] {
            required = values.compactMap { if case .string(let value) = $0 { return value }; return nil }
        } else { required = [] }
        return (properties, required)
    }

    private func bestTool(for mode: String) -> ToolInfo? {
        let blocked = ["annotate", "rename", "delete", "write", "patch", "modify", "edit", "comment", "execute", "run_command"]
        let positive = mode == "IPA"
            ? ["ipa", "binary", "analy", "inspect", "reverse", "decompil", "disassembl", "import", "artifact", "file"]
            : ["website", "web", "url", "http", "crawl", "fetch", "browse", "site", "domain", "page"]
        return tools.compactMap { tool -> (ToolInfo, Int)? in
            guard let parts = schemaParts(tool) else { return nil }
            let nameText = tool.name.lowercased()
            let text = (tool.name + " " + (tool.description ?? "") + " " + parts.0.keys.joined(separator: " ")).lowercased()
            if blocked.contains(where: { nameText.contains($0) }) { return nil }
            if ["deletes data", "permanently removes", "overwrites the", "modifies the binary"].contains(where: { (tool.description ?? "").lowercased().contains($0) }) { return nil }
            var score = positive.reduce(0) { $0 + (text.contains($1) ? 2 : 0) }
            if mode == "IPA", parts.0.keys.contains(where: { ["file_path", "filepath", "binary_path", "ipa_path", "artifact_path"].contains($0.lowercased()) }) { score += 8 }
            if mode == "SITE", parts.0.keys.contains(where: { ["url", "uri", "website_url", "site_url", "target_url", "page_url"].contains($0.lowercased()) }) { score += 8 }
            if parts.1.isEmpty { score -= 1 }
            let probe = mode == "IPA" ? "/tmp/rea-analysis-input.ipa" : "https://example.com"
            guard score > 0, let mapped = makeArguments(for: tool, input: probe, mode: mode), !mapped.isEmpty else { return nil }
            return (tool, score)
        }.sorted { $0.1 > $1.1 }.first?.0
    }

    private func makeArguments(for tool: ToolInfo, input: String, mode: String) -> [String: Any]? {
        guard let (properties, required) = schemaParts(tool) else { return nil }
        var result: [String: Any] = [:]
        let normalizedInput = input.trimmingCharacters(in: .whitespacesAndNewlines)
        for (key, value) in properties {
            guard case .object(let property) = value,
                  case .string(let type)? = property["type"], type == "string" else { continue }
            let k = key.lowercased()
            if mode == "IPA" && ["file", "filepath", "file_path", "path", "binary", "binary_path", "ipa", "ipa_path", "artifact", "artifact_path", "input_file", "target_path"].contains(k) {
                result[key] = normalizedInput
            } else if mode == "SITE" && ["url", "uri", "website", "website_url", "site", "site_url", "target_url", "domain", "page_url"].contains(k) {
                result[key] = normalizedInput
            }
        }
        for key in required where result[key] == nil {
            guard case .object(let property)? = properties[key],
                  case .string(let type)? = property["type"], type == "string" else { return nil }
            return nil
        }
        return result
    }

    private func startAnalysis() {
        guard let tool = bestTool(for: analysisMode) else {
            result = analysisMode == "IPA"
                ? "Não encontrei no catálogo MCP uma ferramenta de análise de IPA/binário com schema compatível. Não vou chamar uma ferramenta errada."
                : "Não encontrei no catálogo MCP uma ferramenta de análise de sites/URLs com schema compatível."
            return
        }
        selectedTool = tool.name
        if analysisMode == "SITE" {
            guard let url = URL(string: targetURL), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else {
                result = "Informe uma URL válida começando com https:// ou http://."
                return
            }
            guard let args = makeArguments(for: tool, input: url.absoluteString, mode: "SITE") else {
                result = "A ferramenta '\(tool.name)' tem campos obrigatórios que não podem ser preenchidos automaticamente. Veja o schema em Avançado."
                return
            }
            sendToolCall(tool: tool.name, args: args)
        } else {
            guard let file = selectedFile else { return }
            uploadAndAnalyze(file: file, tool: tool)
        }
    }

    private func uploadAndAnalyze(file: URL, tool: ToolInfo) {
        guard let base = URL(string: server) else { result = "URL do servidor inválida."; return }
        busy = true
        result = "Enviando IPA ao REA…"
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
                req.setValue("Bearer \(self.token)", forHTTPHeaderField: "Authorization")
                req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
                req.httpBody = body
                req.timeoutInterval = 300
                URLSession.shared.dataTask(with: req) { data, response, error in
                    DispatchQueue.main.async {
                        if let error { busy = false; result = "Falha no upload: \(error.localizedDescription)"; return }
                        guard let data, let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let path = object["filePath"] as? String else {
                            busy = false
                            result = "O servidor não aceitou o arquivo: \(String(data: data ?? Data(), encoding: .utf8) ?? "sem resposta")"
                            return
                        }
                        uploadPath = path
                        guard let args = makeArguments(for: tool, input: path, mode: "IPA") else {
                            busy = false
                            result = "O arquivo foi enviado, mas o schema de '\(tool.name)' não tem campos obrigatórios compatíveis com caminho de IPA."
                            return
                        }
                        sendToolCall(tool: tool.name, args: args)
                    }
                }.resume()
            } catch {
                DispatchQueue.main.async { busy = false; result = "Não foi possível ler o IPA: \(error.localizedDescription)" }
            }
        }
    }

    private func sendToolCall(tool: String, args: [String: Any]) {
        guard let body = try? JSONSerialization.data(withJSONObject: ["arguments": args]),
              let req = request("/api/tools/\(tool)/call", method: "POST", body: body) else {
            busy = false
            result = "Não foi possível preparar a chamada da ferramenta."
            return
        }
        busy = true
        result = "Executando análise com \(tool)…"
        URLSession.shared.dataTask(with: req) { data, response, error in
            DispatchQueue.main.async {
                busy = false
                if let error { result = error.localizedDescription; return }
                guard let data else { result = "O servidor não retornou conteúdo."; return }
                let payload = String(data: data, encoding: .utf8) ?? "Resposta não textual."
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    result = "HTTP \(http.statusCode): \(payload)"
                } else {
                    result = payload
                }
            }
        }.resume()
    }

    private func filePathArgumentName() -> String? {
        guard let schema = tools.first(where: { $0.name == selectedTool })?.inputSchema,
              case .object(let root) = schema,
              case .object(let properties)? = root["properties"] else { return nil }
        for key in ["filePath", "file_path", "path", "binary_path", "target_path"] where properties[key] != nil {
            return key
        }
        return nil
    }

    private func fillRequiredArguments() {
        guard let schema = tools.first(where: { $0.name == selectedTool })?.inputSchema,
              case .object(let root) = schema,
              case .object(let properties)? = root["properties"] else {
            result = "A ferramenta não anunciou um schema de entrada legível."
            return
        }
        let required: [String]
        if case .array(let values)? = root["required"] {
            required = values.compactMap { if case .string(let value) = $0 { return value }; return nil }
        } else { required = [] }
        var values: [String: Any] = [:]
        for key in required {
            guard case .object(let property)? = properties[key],
                  case .string(let type)? = property["type"] else { continue }
            switch type {
            case "string": values[key] = ""
            case "number", "integer": values[key] = 0
            case "boolean": values[key] = false
            case "array": values[key] = [Any]()
            case "object": values[key] = [String: Any]()
            default: break
            }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            result = "Não foi possível montar os campos obrigatórios."
            return
        }
        arguments = text
        result = required.isEmpty
            ? "O schema não declara campos obrigatórios."
            : "Campos obrigatórios preenchidos como modelo. Complete os valores vazios antes de executar."
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
