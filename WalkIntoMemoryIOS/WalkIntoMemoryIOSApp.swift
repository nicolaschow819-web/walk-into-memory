import SwiftUI
import UniformTypeIdentifiers

@main
struct WalkIntoMemoryIOSApp: App {
    @StateObject private var engine = AppEngine()

    var body: some Scene {
        WindowGroup {
            ContentView(engine: engine)
        }
    }
}

struct ContentView: View {
    @ObservedObject var engine: AppEngine
    @State private var importing = false

    var body: some View {
        ZStack {
            ARMetalView(engine: engine)
                .ignoresSafeArea()

            VStack {
                Text(engine.status)
                    .font(.subheadline)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 14))
                    .foregroundStyle(.white)
                    .padding(.top, 16)
                    .padding(.horizontal, 20)

                Spacer()

                HStack(spacing: 16) {
                    Button(action: { importing = true }) {
                        Text("导入场景")
                            .font(.headline)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.borderedProminent)

                    Button(action: { engine.requestReplace() }) {
                        Text("重新放置")
                            .font(.headline)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.bordered)
                    .tint(.white)
                    .background(.black.opacity(0.5), in: Capsule())
                }
                .padding(.bottom, 34)
            }
        }
        .onAppear {
            engine.loadDefaultSceneIfAvailable()
        }
        .fileImporter(isPresented: $importing,
                      allowedContentTypes: [.item, .data, .json],
                      allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            importFiles(urls)
        }
    }

    /// Copies the picked .spz (+ same-name .json when present) into the app
    /// sandbox, then hands them to the engine.
    private func importFiles(_ urls: [URL]) {
        let spz = urls.first { $0.pathExtension.lowercased() == "spz" || $0.pathExtension.lowercased() == "ply" }
        guard let spz else {
            engine.status = "未找到 .spz 文件，请同时选中 .spz 与 .json"
            return
        }
        let base = spz.deletingPathExtension().lastPathComponent
        let json = urls.first { $0.pathExtension.lowercased() == "json" }
            ?? urls.first { $0.deletingPathExtension().lastPathComponent == base && $0.pathExtension.lowercased() == "json" }

        let fm = FileManager.default
        let dir = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Scenes", isDirectory: true)
            .appendingPathComponent(base, isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)

        func stage(_ url: URL) -> URL? {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let dest = dir.appendingPathComponent(url.lastPathComponent)
            try? fm.removeItem(at: dest)
            do {
                try fm.copyItem(at: url, to: dest)
                return dest
            } catch {
                return nil
            }
        }

        guard let localSPZ = stage(spz) else {
            engine.status = "读取所选 .spz 文件失败"
            return
        }
        let localJSON = json.flatMap { stage($0) }
        engine.loadScene(spzURL: localSPZ, jsonURL: localJSON)
    }
}
