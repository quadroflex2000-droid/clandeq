//
//  WatchSessionManager.swift
//  Clandeq
//
//  Created by SuperMax (AI Senior Developer) on 2026-06-01.
//  Copyright © 2026 PAPAMETALL CORPORATION. All rights reserved.
//

import Foundation
import WatchConnectivity

/// Расширение для простого уведомления SwiftUI-интерфейса часов о полученном триггере
extension Notification.Name {
    static let didReceiveClandeqTrigger = Notification.Name("com.clandeq.didReceiveClandeqTrigger")
}

/// WatchSessionManager координирует беспроводную синхронизацию между iPhone и Apple Watch.
/// Использует энергоэффективный стек WatchConnectivity (WCSession) для передачи тактильных сигналов за доли миллисекунд.
final class WatchSessionManager: NSObject, WCSessionDelegate {
    static let shared = WatchSessionManager()
    
    private let session = WCSession.default
    
    private override init() {
        super.init()
        if WCSession.isSupported() {
            session.delegate = self
            session.activate()
        }
    }
    
    /// Активирует сессию связи. Метод должен вызываться при запуске приложения (AppDelegate/App struct)
    func activate() {
        // Инициализация синглтона выполнит активацию сессии
        #if DEBUG
        print("[WatchSessionManager] Инициализация сессии WCSession...")
        #endif
    }
    
    /// Отправляет тактический триггер (скрипт и тип вибрации) с iPhone на Apple Watch.
    /// Метод вызывается на стороне iOS-клиента.
    /// - Parameters:
    ///   - script: Текстовый модуль ответа на Apple Watch
    ///   - hapticPattern: ID вибрации (1-3)
    func sendTriggerToWatch(script: String, hapticPattern: Int) {
        #if os(iOS)
        guard session.isReachable else {
            print("[WatchSessionManager] Ошибка: Часы Apple Watch недоступны для мгновенных сообщений.")
            return
        }
        
        let payload: [String: Any] = [
            "responseScript": script,
            "hapticPattern": hapticPattern,
            "timestamp": Date().timeIntervalSince1970
        ]
        
        // sendMessage отправляет данные мгновенно по сокету низкого уровня за доли миллисекунд (Real-Time Push)
        session.sendMessage(payload, replyHandler: nil) { error in
            print("[WatchSessionManager] Ошибка отправки пакета на Apple Watch: \(error.localizedDescription)")
        }
        #endif
    }
    
    // MARK: - WCSessionDelegate
    
    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        #if DEBUG
        if let error = error {
            print("[WatchSessionManager] Ошибка активации WCSession: \(error.localizedDescription)")
        } else {
            print("[WatchSessionManager] WCSession активирована. Статус: \(activationState.rawValue)")
        }
        #endif
    }
    
    #if os(iOS)
    func sessionDidBecomeInactive(_ session: WCSession) {
        // Переподключение при смене часов пользователем
        session.activate()
    }
    
    func sessionDidDeactivate(_ session: WCSession) {
        // Переподключение при смене часов пользователем
        session.activate()
    }
    #endif
    
    /// Обработчик входящих сообщений на стороне Apple Watch.
    /// Принимает тактильный пакет, инициирует CoreHaptics вибрацию и обновляет SwiftUI-интерфейс часов.
    func session(_ session: WCSession, didReceiveMessage message: [String : Any]) {
        #if DEBUG
        print("[WatchSessionManager] Часы получили входящий триггер от iPhone!")
        #endif
        
        guard let script = message["responseScript"] as? String,
              let hapticPattern = message["hapticPattern"] as? Int else {
            return
        }
        
        // 1. Моментально запускаем физический вибро-паттерн на руке менеджера (CoreHaptics)
        HapticManager.shared.triggerHaptic(patternId: hapticPattern)
        
        // 2. Публикуем системное уведомление для мгновенного обновления SwiftUI UI на Apple Watch
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .didReceiveClandeqTrigger,
                object: nil,
                userInfo: [
                    "responseScript": script,
                    "hapticPattern": hapticPattern
                ]
            )
        }
    }
}
