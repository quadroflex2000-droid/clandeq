//
//  HapticManager.swift
//  Clandeq
//
//  Created by SuperMax (AI Senior Developer) on 2026-06-01.
//  Copyright © 2026 PAPAMETALL CORPORATION. All rights reserved.
//

import Foundation

#if os(watchOS)
import WatchKit
#elseif os(iOS)
import UIKit
import CoreHaptics // CoreHaptics доступен на iOS, но отсутствует на watchOS SDK
#endif

/// HapticManager отвечает за воспроизведение тактильных рисунков (Haptic Patterns) на руке менеджера.
final class HapticManager {
    static let shared = HapticManager()
    
    #if os(iOS)
    // Движок тактильной отдачи CoreHaptics (используется только на iPhone)
    private var hapticEngine: CHHapticEngine?
    private var supportsCoreHaptics = false
    #endif
    
    private init() {
        #if os(iOS)
        setupHapticEngine()
        #endif
    }
    
    #if os(iOS)
    /// Инициализация и прогрев тактильного движка CoreHaptics на iPhone
    private func setupHapticEngine() {
        let capabilities = CHHapticEngine.capabilitiesForHardware()
        supportsCoreHaptics = capabilities.supportsHaptics
        
        guard supportsCoreHaptics else { return }
        
        do {
            hapticEngine = try CHHapticEngine()
            hapticEngine?.resetHandler = { [weak self] in
                try? self?.hapticEngine?.start()
            }
            try hapticEngine?.start()
        } catch {
            supportsCoreHaptics = false
        }
    }
    #endif
    
    /// Генерирует физический рисунок вибрации на часах/телефоне
    /// - Parameter patternId: 1 — Мягкая подсказка, 2 — Предупреждение о стрессе, 3 — Смертельный триггер конкурента
    func triggerHaptic(patternId: Int) {
        #if os(iOS)
        if supportsCoreHaptics {
            try? hapticEngine?.start()
        }
        #endif
        
        switch patternId {
        case 1:
            playSoftGuidance()
        case 2:
            playStressAlarm()
        case 3:
            playCompetitorAlert()
        default:
            playSoftGuidance()
        }
    }
    
    // MARK: - Рисунки вибрации
    
    private func playSoftGuidance() {
        #if os(iOS)
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
        #else
        playFallback(type: .click)
        #endif
    }
    
    private func playStressAlarm() {
        #if os(iOS)
        guard supportsCoreHaptics, let engine = hapticEngine else {
            playFallback(type: .directionUp)
            return
        }
        
        let intensity = CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.7)
        let sharpness = CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.6)
        
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
        #else
        playFallback(type: .directionUp)
        #endif
    }
    
    private func playCompetitorAlert() {
        #if os(iOS)
        guard supportsCoreHaptics, let engine = hapticEngine else {
            playFallback(type: .notification)
            return
        }
        
        let maxIntensity = CHHapticEventParameter(parameterID: .hapticIntensity, value: 1.0)
        let maxSharpness = CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.9)
        
        let event1 = CHHapticEvent(eventType: .hapticTransient, parameters: [maxIntensity, maxSharpness], relativeTime: 0.0)
        let event2 = CHHapticEvent(eventType: .hapticTransient, parameters: [maxIntensity, maxSharpness], relativeTime: 0.1)
        
        do {
            let pattern = try CHHapticPattern(events: [event1, event2], parameters: [])
            let player = try engine.makePlayer(with: pattern)
            try player.start(atTime: 0)
        } catch {
            playFallback(type: .notification)
        }
        #else
        playFallback(type: .notification)
        #endif
    }
    
    // MARK: - watchOS/iOS Fallback-режим
    
    enum FallbackHapticType {
        case click
        case directionUp
        case notification
    }
    
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
