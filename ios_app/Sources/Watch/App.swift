import SwiftUI
import Combine

@main
struct ClandeqWatchApp: App {
    init() {
        // Инициализируем WatchSessionManager при старте приложения на Apple Watch
        WatchSessionManager.shared.activate()
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

struct ContentView: View {
    @State private var lastMessage: String = "Ожидание тактических подсказок..."
    @State private var highlightColor: Color = .gray
    @State private var isAlertActive = false
    
    // Подписка на уведомление из WatchSessionManager о новом триггере
    private let triggerPublisher = NotificationCenter.default.publisher(for: NSNotification.Name("com.clandeq.didReceiveClandeqTrigger"))
    
    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                // Иконка детектора возражений
                Image(systemName: isAlertActive ? "bolt.shield.fill" : "bolt.shield")
                    .font(.system(size: 36))
                    .foregroundColor(highlightColor)
                    .scaleEffect(isAlertActive ? 1.1 : 1.0)
                    .animation(.spring(response: 0.3, dampingFraction: 0.5), value: isAlertActive)
                    .padding(.top, 8)
                
                Text(isAlertActive ? "ОБНАРУЖЕНО ВОЗРАЖЕНИЕ" : "CLANDEQ EDGE AI")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundColor(highlightColor)
                    .tracking(1.0)
                
                Divider()
                    .background(highlightColor.opacity(0.3))
                
                // Текст тактической подсказки
                Text(lastMessage)
                    .font(.system(size: 14, weight: .medium, design: .default))
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 4)
                    .animation(.easeInOut, value: lastMessage)
                
                if isAlertActive {
                    Button(action: {
                        // Сброс подсказки
                        withAnimation {
                            lastMessage = "Мониторинг эфира..."
                            highlightColor = .gray
                            isAlertActive = false
                        }
                    }) {
                        Text("ПРИНЯТО")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.black)
                    }
                    .background(Color.cyan)
                    .cornerRadius(8)
                    .padding(.top, 8)
                    .transition(.opacity)
                }
            }
            .padding(.vertical, 4)
        }
        .background(Color.black)
        .onReceive(triggerPublisher) { notification in
            // ШАГ 4: Принимаем пакет на стороне часов и обновляем UI
            if let userInfo = notification.userInfo,
               let script = userInfo["responseScript"] as? String {
                
                withAnimation(.easeInOut) {
                    self.lastMessage = script
                    self.highlightColor = .cyan
                    self.isAlertActive = true
                }
                
                // Дополнительная дублирующая тактильная отдача для привлечения внимания
                #if os(watchOS)
                WKInterfaceDevice.current().play(.notification)
                #endif
            }
        }
    }
}
