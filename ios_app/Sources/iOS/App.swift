import SwiftUI

@main
struct ClandeqApp: App {
    var body: some Scene {
        WindowGroup {
            ClandeqMainView()
        }
    }
}

struct ClandeqMainView: View {
    @State private var status: String = "Готов к синхронизации"
    @State private var isDownloading = false
    
    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                
                VStack(spacing: 24) {
                    Spacer()
                    
                    Image(systemName: "bolt.shield")
                        .font(.system(size: 72, weight: .light))
                        .foregroundColor(.cyan)
                        .shadow(color: .cyan.opacity(0.6), radius: 10)
                    
                    Text("CLANDEQ")
                        .font(.system(size: 32, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                        .tracking(4.0)
                    
                    Text("ОПТИМИЗИРОВАНО ДЛЯ APPLE WATCH")
                        .font(.caption)
                        .foregroundColor(.cyan)
                        .tracking(1.5)
                    
                    Spacer()
                    
                    VStack(spacing: 8) {
                        Text("СТАТУС СИСТЕМЫ")
                            .font(.caption2)
                            .foregroundColor(.gray)
                        Text(status)
                            .font(.body)
                            .foregroundColor(.white)
                    }
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(Color.white.opacity(0.05))
                    .cornerRadius(12)
                    
                    Button(action: {
                        Task {
                            await syncAndDownload()
                        }
                    }) {
                        HStack {
                            if isDownloading {
                                ProgressView()
                                    .tint(.black)
                                    .padding(.trailing, 8)
                            } else {
                                Image(systemName: "arrow.down.to.line")
                            }
                            Text(isDownloading ? "ЗАГРУЗКА..." : "СИНХРОНИЗИРОВАТЬ ДАННЫЕ")
                        }
                        .font(.headline.bold())
                        .foregroundColor(.black)
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .background(isDownloading ? Color.cyan.opacity(0.5) : Color.cyan)
                        .cornerRadius(12)
                        .shadow(color: .cyan.opacity(0.4), radius: 8)
                    }
                    .disabled(isDownloading)
                    
                    Spacer()
                }
                .padding(24)
            }
            .navigationTitle("")
        }
    }
    
    private func syncAndDownload() async {
        isDownloading = true
        status = "Подключение к Go-бэкенду..."
        
        do {
            let mockDealID = "test-deal-uuid-1234"
            status = "Запрос генерации SQLite базы с помощью ИИ..."
            let fileURL = try await NetworkManager.shared.syncAndDownloadOfflineDB(for: mockDealID)
            status = "База успешно сохранена!\nПуть: \(fileURL.lastPathComponent)"
        } catch {
            status = "Ошибка: \(error.localizedDescription)"
        }
        
        isDownloading = false
    }
}
