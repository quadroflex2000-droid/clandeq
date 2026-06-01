//
//  ClandeqEngine.swift
//  Clandeq
//
//  Created by SuperMax (AI Senior Developer) on 2026-06-01.
//  Copyright © 2026 PAPAMETALL CORPORATION. All rights reserved.
//

import Foundation
import AVFoundation

/// Главный оркестратор Edge AI модуля Clandeq (ViewModel-посредник).
/// Координирует работу микрофона, локальной базы данных, Speech-to-Text распознавания и связи с часами Apple Watch.
final class ClandeqEngine {
    static let shared = ClandeqEngine()
    
    private let captureService = AudioCaptureService.shared
    private let dbManager = DatabaseManager.shared
    
    // Потокобезопасная очередь для обработки результатов распознавания речи
    private let processingQueue = DispatchQueue(label: "com.clandeq.engine.processing", qos: .userInteractive)
    
    // Текущая телеметрия встречи (сохраняется для последующей выгрузки на бэкенд в meeting_logs)
    private var transcriptions: [String] = []
    private var startTime: Date?
    
    private init() {
        // ШАГ 3: Подписываемся на обновления от AudioCaptureService (STT на базе нативного SFSpeechRecognizer)
        captureService.onTranscriptionUpdate = { [weak self] transcribedText in
            self?.processRecognizedText(transcribedText)
        }
    }
    
    /// Запуск сессии переговоров (подключение микрофона, инициализация БД)
    /// - Parameters:
    ///   - dealID: ID сделки для подгрузки БД
    ///   - sqliteURL: Локальный путь к скачанному SQLite файлу в песочнице
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
        transcriptions.removeAll()
        startTime = Date()
        
        // 3. Запускаем фоновый захват микрофона и Speech-to-Text
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
            "transcript": transcriptions.joined(separator: "\n")
        ]
    }
    
    // MARK: - Core NLP & Haptic Logic
    
    /// Метод-обработчик текста, полученного от STT (SFSpeechRecognizer).
    /// Выполняет FTS поиск по БД, сопоставляет её с базой и отправляет тактильные сигналы на Apple Watch.
    func processRecognizedText(_ text: String) {
        processingQueue.async { [weak self] in
            guard let self = self else { return }
            
            let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedText.isEmpty else { return }
            
            self.transcriptions.append("Клиент: \(trimmedText)")
            
            #if DEBUG
            print("[ClandeqEngine] Распознана речь: \"\(trimmedText)\"")
            #endif
            
            // Выполняем высокоскоростной поиск возражения в оффлайн-БД
            // Вызов метода findTactic() из ШАГА 1
            guard let responseScript = self.dbManager.findTactic(for: trimmedText) else {
                return // Совпадений не найдено, продолжаем пассивный мониторинг
            }
            
            // Находим паттерн тактильной отдачи из базы
            let match = self.dbManager.searchObjection(matching: trimmedText)
            let hapticPattern = match?.hapticPattern ?? 1
            
            #if DEBUG
            print("[ClandeqEngine] Мэтч возражения найден! Скрипт: \"\(responseScript)\". Паттерн тактильной отдачи: \(hapticPattern)")
            #endif
            
            // ШАГ 4: Отправляем моментальный тактильный триггер на Apple Watch по защищенному каналу WatchConnectivity
            WatchSessionManager.shared.sendTriggerToWatch(script: responseScript, hapticPattern: hapticPattern)
        }
    }
}
