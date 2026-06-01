//
//  ClandeqEngine.swift
//  Clandeq
//
//  Created by SuperMax (AI Senior Developer) on 2026-06-01.
//  Copyright © 2026 PAPAMETALL CORPORATION. All rights reserved.
//

import Foundation
import AVFoundation

/// Главный оркестратор Edge AI модуля Clandeq.
/// Координирует работу микрофона, локальной базы данных, ML-моделей и связи с часами Apple Watch.
final class ClandeqEngine: AudioCaptureDelegate {
    static let shared = ClandeqEngine()
    
    private let captureService = AudioCaptureService.shared
    private let dbManager = DatabaseManager.shared
    private let acousticAnalyzer = AcousticAnalyzer()
    
    // Потокобезопасная очередь для обработки результатов распознавания речи
    private let processingQueue = DispatchQueue(label: "com.clandeq.engine.processing", qos: .userInteractive)
    
    // Текущая телеметрия встречи (сохраняется для последующей выгрузки на бэкенд в meeting_logs)
    private var stressTimeline: [TimeInterval: Double] = [:]
    private var currentTalkRatio: Double = 0.5
    private var currentStressLevel: Double = 0.0
    private var transcriptions: [String] = []
    
    private var startTime: Date?
    
    private init() {
        captureService.delegate = self
    }
    
    /// Запуск сессии переговоров (подключение микрофона, инициализация БД)
    /// - Parameters:
    ///   - dealID: ID сделки для подгрузки БД
    ///   - sqliteURL: Локальный путь к скачанному SQLite файлу
    func startNegotiationSession(dealID: String, sqliteURL: URL) throws {
        #if DEBUG
        print("[ClandeqEngine] Запуск боевой оффлайн сессии для сделки \(dealID)...")
        #endif
        
        // 1. Инициализируем локальную базу данных
        try dbManager.openDatabase(at: sqliteURL)
        
        // Считываем сжатый контекст сделки (для прогрева/отображения в UI)
        if let history = try? dbManager.getCompressedHistory() {
            print("[ClandeqEngine] Сжатая история успешно загружена: \(history)")
        }
        
        // 2. Сбрасываем метрики телеметрии встречи
        stressTimeline.removeAll()
        transcriptions.removeAll()
        currentTalkRatio = 0.5
        currentStressLevel = 0.0
        startTime = Date()
        
        // 3. Запускаем фоновый захват микрофона
        try captureService.startCapture()
    }
    
    /// Завершение сессии переговоров и подготовка данных для синхронизации с PostgreSQL
    func stopNegotiationSession() -> [String: Any] {
        captureService.stopCapture()
        dbManager.closeDatabase()
        
        let duration = startTime != nil ? Date().timeIntervalSince(startTime!) : 0.0
        
        #if DEBUG
        print("[ClandeqEngine] Сессия завершена. Длительность: \(duration) сек.")
        #endif
        
        // Формируем пакет телеметрии встречи, готовый для POST-отправки в meeting_logs на бэкенд
        return [
            "duration": duration,
            "talk_ratio": currentTalkRatio,
            "stress_timeline": stressTimeline,
            "transcript": transcriptions.joined(separator: "\n")
        ]
    }
    
    // MARK: - AudioCaptureDelegate
    
    /// Получение сырого аудио-буфера с высокой дискретизацией (44.1/48kHz)
    /// Используется для CoreML акустического анализа стресса и просодии голоса
    func audioCaptureService(_ service: AudioCaptureService, didCaptureRawBuffer buffer: AVAudioPCMBuffer, time: AVAudioTime) {
        let metrics = acousticAnalyzer.analyze(buffer: buffer)
        
        processingQueue.async { [weak self] in
            guard let self = self else { return }
            self.currentStressLevel = metrics.stressLevel
            self.currentTalkRatio = metrics.talkRatio
            
            // Фиксируем телеметрию стресса во временной шкале (с округлением до секунд)
            if let start = self.startTime {
                let seconds = round(Date().timeIntervalSince(start))
                self.stressTimeline[seconds] = metrics.stressLevel
            }
        }
    }
    
    /// Получение даунсэмпленного аудио-буфера (16kHz Mono Float32)
    /// Используется для локальной транскрибации речи в текст через Whisper.cpp
    func audioCaptureService(_ service: AudioCaptureService, didCaptureConvertedBuffer buffer: AVAudioPCMBuffer, time: AVAudioTime) {
        // Здесь буфер уходит в Whisper.cpp.
        // В рамках симуляции, когда Whisper распознает сегмент речи, вызывается метод processRecognizedText()
    }
    
    // MARK: - Core NLP & Haptic Logic
    
    /// Метод-обработчик текста, полученного от STT (Whisper).
    /// Выполняет FTS поиск по БД, компилирует локальный SLM промпт и пушит триггер на часы.
    func processRecognizedText(_ text: String) {
        processingQueue.async { [weak self] in
            guard let self = self else { return }
            
            let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedText.isEmpty else { return }
            
            self.transcriptions.append("Клиент: \(trimmedText)")
            
            #if DEBUG
            print("[ClandeqEngine] Whisper распознал речь: \"\(trimmedText)\"")
            #endif
            
            // Выполняем высокоскоростной поиск возражения в оффлайн-БД
            guard let match = self.dbManager.searchObjection(matching: trimmedText) else {
                return // Совпадений не найдено, продолжаем пассивный мониторинг
            }
            
            #if DEBUG
            print("[ClandeqEngine] Мэтч возражения найден! Триггер: \"\(match.trigger)\". Паттерн тактильной отдачи: \(match.hapticPattern)")
            #endif
            
            // Формируем итоговый промпт для локальной SLM (Small Language Model - Phi-3) на случай,
            // если менеджер попросит развернуть ответ на экране телефона.
            let slmPrompt = self.compileSLMPrompt(objection: match.trigger, rawResponse: match.responseScript)
            
            #if DEBUG
            print("[ClandeqEngine] Сгенерирован локальный SLM-промпт:\n\(slmPrompt)")
            #endif
            
            // Отправляем моментальный триггер на Apple Watch по защищенному каналу WatchConnectivity
            WatchSessionManager.shared.sendTriggerToWatch(script: match.responseScript, hapticPattern: match.hapticPattern)
        }
    }
    
    /// Формирует структурированный промпт для локальной языковой модели
    private func compileSLMPrompt(objection: String, rawResponse: String) -> String {
        return """
        [SYSTEM: Локальный Edge AI Ассистент Clandeq. Сгенерируй тактический речевой модуль на основе регламента.]
        Контекст сделки: Клиент сомневается и выдвинул возражение: "\(objection)".
        Базовый регламент ответа: "\(rawResponse)".
        Задача: Сделай ответ живым, естественным, подходящим для оффлайн переговоров. Максимум 2 предложения. Без лишней вежливости.
        Вывод:
        """
    }
}
