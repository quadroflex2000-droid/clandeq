//
//  HapticManager.swift
//  Clandeq
//
//  Created by SuperMax (AI Senior Developer) on 2026-06-01.
//  Copyright © 2026 PAPAMETALL CORPORATION. All rights reserved.
//

import Foundation
import CoreHaptics

#if os(watchOS)
import WatchKit
#endif

/// HapticManager отвечает за воспроизведение тактильных рисунков (Haptic Patterns) на руке менеджера.
/// На Apple Watch он генерирует вибрацию в полной тишине, обеспечивая менеджеру скрытые подсказки на переговорах.
final class HapticManager {
    static let shared = HapticManager()
    
    // Движок тактильной отдачи CoreHaptics
    private var hapticEngine: CHHapticEngine?
    private var supportsCoreHaptics = false
    
    private init() {
        setupHapticEngine()
    }
    
    /// Инициализация и прогрев тактильного движка CoreHaptics
    private func setupHapticEngine() {
        // Проверяем аппаратную поддержку CoreHaptics на данном устройстве
        let capabilities = CHHapticEngine.capabilitiesForHardware()
        supportsCoreHaptics = capabilities.supportsHaptics
        
        guard supportsCoreHaptics else {
            #if DEBUG
            print("[HapticManager] Устройство не поддерживает CoreHaptics. Будет использован нативный fallback-режим.")
            #endif
            return
        }
        
        do {
            hapticEngine = try CHHapticEngine()
            
            // Обработчик неожиданного отключения движка СУБД/ОС (например, при сильной загрузке)
            hapticEngine?.resetHandler = { [weak self] in
                #if DEBUG
                print("[HapticManager] Ресет тактильного движка. Перезапускаем...")
                #endif
                try? self?.hapticEngine?.start()
            }
            
            // Обработчик остановки движка при неактивности
            hapticEngine?.stoppedHandler = { reason in
                #if DEBUG
                print("[HapticManager] Движок остановлен. Причина: \(reason.rawValue)")
                #endif
            }
            
            // Запуск движка
            try hapticEngine?.start()
        } catch {
            print("[HapticManager] Ошибка инициализации CoreHaptics: \(error.localizedDescription)")
            supportsCoreHaptics = false
        }
    }
    
    /// Генерирует физический рисунок вибрации на часах/телефоне в зависимости от уровня критичности триггера
    /// - Parameter patternId: 1 — Мягкая подсказка, 2 — Предупреждение о стрессе, 3 — Смертельный триггер конкурента
    func triggerHaptic(patternId: Int) {
        // Убедимся, что тактильный движок запущен перед воспроизведением
        if supportsCoreHaptics {
            try? hapticEngine?.start()
        }
        
        switch patternId {
        case 1:
            // Мягкий тактильный сигнал (легкое похлопывание): Низкая интенсивность и резкость
            playSoftGuidance()
        case 2:
            // Настойчивое предупреждение (три пульсирующих вибрации)
            playStressAlarm()
        case 3:
            // Двойной быстрый удар (триггер конкурента): Максимальная интенсивность и жесткость
            playCompetitorAlert()
        default:
            playSoftGuidance()
        }
    }
    
    // MARK: - CoreHaptics Рисунки
    
    /// Паттерн 1: Мягкий одиночный клик (Soft Transient)
    private func playSoftGuidance() {
        guard supportsCoreHaptics, let engine = hapticEngine else {
            playFallback(type: .click)
            return
        }
        
        let intensity = CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.4)
        let sharpness = CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.3)
        
        let event = CHHapticEvent(eventType: .hapticTransient, parameters: [intensity, sharpness], relativeTime: 0.0)
        
        do {
            let pattern = try CHHapticPattern(events: [event], parameters: [])
            let player = try engine.makePlayer(with: pattern)
            try player.start(atTime: 0)
        } catch {
            playFallback(type: .click)
        }
    }
    
    /// Паттерн 2: Пульсирующая вибрация (Alarm/Stress Pulse)
    private func playStressAlarm() {
        guard supportsCoreHaptics, let engine = hapticEngine else {
            playFallback(type: .directionUp)
            return
        }
        
        let intensity = CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.7)
        let sharpness = CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.6)
        
        // Создаем три последовательных удара с интервалом в 150мс
        let event1 = CHHapticEvent(eventType: .hapticTransient, parameters: [intensity, sharpness], relativeTime: 0.0)
        let event2 = CHHapticEvent(eventType: .hapticTransient, parameters: [intensity, sharpness], relativeTime: 0.15)
        let event3 = CHHapticEvent(eventType: .hapticTransient, parameters: [intensity, sharpness], relativeTime: 0.3)
        
        do {
            let pattern = try CHHapticPattern(events: [event1, event2, event3], parameters: [])
            let player = try engine.makePlayer(with: pattern)
            try player.start(atTime: 0)
        } catch {
            playFallback(type: .directionUp)
        }
    }
    
    /// Паттерн 3: Двойной мощный толчок (Competitor Double-Vibe)
    private func playCompetitorAlert() {
        guard supportsCoreHaptics, let engine = hapticEngine else {
            playFallback(type: .notification)
            return
        }
        
        let maxIntensity = CHHapticEventParameter(parameterID: .hapticIntensity, value: 1.0)
        let maxSharpness = CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.9)
        
        // Два очень жестких удара друг за другом (интервал 100мс)
        let event1 = CHHapticEvent(eventType: .hapticTransient, parameters: [maxIntensity, maxSharpness], relativeTime: 0.0)
        let event2 = CHHapticEvent(eventType: .hapticTransient, parameters: [maxIntensity, maxSharpness], relativeTime: 0.1)
        
        do {
            let pattern = try CHHapticPattern(events: [event1, event2], parameters: [])
            let player = try engine.makePlayer(with: pattern)
            try player.start(atTime: 0)
        } catch {
            playFallback(type: .notification)
        }
    }
    
    // MARK: - watchOS/iOS Fallback-режим
    
    /// Виды нативной тактильной отдачи для fallback-режима
    enum FallbackHapticType {
        case click
        case directionUp
        case notification
    }
    
    /// Осуществляет резервную генерацию вибрации в обход CoreHaptics (для симулятора или старых watchOS)
    private func playFallback(type: FallbackHapticType) {
        #if os(watchOS)
        let device = WKInterfaceDevice.current()
        switch type {
        case .click:
            device.play(.click)
        case .directionUp:
            device.play(.directionUp)
        case .notification:
            device.play(.notification)
        }
        #elseif os(iOS)
        let generator: UIFeedbackGenerator
        switch type {
        case .click:
            let impact = UIImpactFeedbackGenerator(style: .light)
            impact.impactOccurred()
        case .directionUp:
            let notification = UINotificationFeedbackGenerator()
            notification.notificationOccurred(.warning)
        case .notification:
            let notification = UINotificationFeedbackGenerator()
            notification.notificationOccurred(.error)
        }
        #endif
    }
}
