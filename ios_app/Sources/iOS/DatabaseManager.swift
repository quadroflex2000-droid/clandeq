//
//  DatabaseManager.swift
//  Clandeq
//
//  Created by SuperMax (AI Senior Developer) on 2026-06-01.
//  Copyright © 2026 PAPAMETALL CORPORATION. All rights reserved.
//

import Foundation
import SQLite3 // Нативный фреймворк Apple для работы с SQLite (встроен во все версии iOS/watchOS)

/// Ошибки менеджера локальной базы данных SQLite
enum DatabaseError: Error, LocalizedError {
    case connectionFailed(String)
    case queryFailed(String)
    case recordNotFound
    
    var errorDescription: String? {
        switch self {
        case .connectionFailed(let message):
            return "Не удалось подключиться к локальной базе данных: \(message)"
        case .queryFailed(let message):
            return "Ошибка выполнения SQL-запроса: \(message)"
        case .recordNotFound:
            return "Запись не найдена в локальном контексте сделки."
        }
    }
}

/// Модель совпадения возражения, найденного по FTS-поиску во время встречи
struct ObjectionMatch {
    let id: Int
    let trigger: String
    let responseScript: String
    let hapticPattern: Int
}

/// DatabaseManager управляет локальным оффлайн SQLite-файлом конкретной сделки на iPhone.
/// Выполняет мгновенный полнотекстовый поиск (FTS5) по сырой транскрибированной речи в условиях 100% отсутствия связи.
final class DatabaseManager {
    static let shared = DatabaseManager()
    
    // Ссылка на дескриптор базы данных sqlite3 (использует встроенный тип OpaquePointer)
    private var db: OpaquePointer?
    
    private let queue = DispatchQueue(label: "com.clandeq.database.queue", qos: .userInteractive)
    
    private init() {}
    
    deinit {
        closeDatabase()
    }
    
    /// Открывает соединение с оффлайн-базой данных конкретной сделки
    /// - Parameter fileURL: Путь к .sqlite файлу в песочнице iPhone (DocumentDirectory)
    func openDatabase(at fileURL: URL) throws {
        try queue.sync {
            closeDatabase() // Закрываем предыдущее соединение, если оно существовало
            
            #if DEBUG
            print("[DatabaseManager] Открытие базы данных по пути: \(fileURL.path)")
            #endif
            
            // Открываем базу в режиме Read-Only (безопасно, предотвращает повреждение файла при случайной записи)
            let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
            
            // Вызов нативного C-API sqlite3
            let result = sqlite3_open_v2(fileURL.path, &db, flags, nil)
            
            if result != SQLITE_OK {
                let errorMsg = db != nil ? String(cString: sqlite3_errmsg(db)) : "Неизвестная ошибка"
                throw DatabaseError.connectionFailed(errorMsg)
            }
        }
    }
    
    /// Закрывает текущее соединение с СУБД
    func closeDatabase() {
        if db != nil {
            sqlite3_close(db)
            db = nil
            #if DEBUG
            print("[DatabaseManager] Локальное соединение с SQLite закрыто.")
            #endif
        }
    }
    
    /// Извлекает сжатую историю прошлых встреч и регламент сделки
    /// - Returns: Форматированный текст сжатой истории
    func getCompressedHistory() throws -> String {
        guard let db = db else {
            throw DatabaseError.connectionFailed("База данных не инициализирована.")
        }
        
        return try queue.sync {
            let query = "SELECT compressed_history FROM deal_context LIMIT 1;"
            var statement: OpaquePointer?
            
            defer { sqlite3_finalize(statement) }
            
            let prepareResult = sqlite3_prepare_v2(db, query, -1, &statement, nil)
            guard prepareResult == SQLITE_OK else {
                throw DatabaseError.queryFailed(String(cString: sqlite3_errmsg(db)))
            }
            
            if sqlite3_step(statement) == SQLITE_ROW {
                if let cString = sqlite3_column_text(statement, 0) {
                    return String(cString: cString)
                }
            }
            throw DatabaseError.recordNotFound
        }
    }
    
    /// Метод поиска тактики по распознанной фразе (STT).
    /// Выполняет мгновенный гибридный поиск (сначала высокоскоростной FTS5, затем LIKE подстрок).
    /// - Parameter transcribedText: Распознанный текст речи собеседника.
    /// - Returns: Скрипт ответа из регламента, если найдено совпадение.
    func findTactic(for transcribedText: String) -> String? {
        guard let match = searchObjection(matching: transcribedText) else { return nil }
        return match.responseScript
    }
    
    /// Выполняет мгновенный полнотекстовый поиск (FTS5) по возражениям на основе текущей распознанной фразы.
    /// - Parameter speechText: Сырой распознанный текст от STT-сервиса
    /// - Returns: Тактическое правило и скрипт, если найдено совпадение
    func searchObjection(matching speechText: String) -> ObjectionMatch? {
        guard let db = db, !speechText.isEmpty else { return nil }
        
        return queue.sync {
            // Очищаем и нормализуем текст для безопасного FTS-запроса (удаляем спецсимволы)
            let cleanQuery = cleanSearchTerm(speechText)
            guard !cleanQuery.isEmpty else { return nil }
            
            // 1. Попытка высокоскоростного поиска через виртуальную FTS5 таблицу
            let ftsSQL = """
            SELECT id, objection_trigger, response_script, haptic_pattern 
            FROM objection_rules 
            WHERE id IN (
                SELECT rowid 
                FROM objection_rules_fts 
                WHERE objection_rules_fts MATCH ?
            ) LIMIT 1;
            """
            
            if let match = executeSearch(sql: ftsSQL, bindValue: "\(cleanQuery)*") {
                return match
            }
            
            // 2. Fallback-стратегия: Если точного FTS мэтча нет, ищем вхождение ключевых слов через LIKE
            let fallbackSQL = """
            SELECT id, objection_trigger, response_script, haptic_pattern 
            FROM objection_rules 
            WHERE ? LIKE '%' || objection_trigger || '%' 
            OR objection_trigger LIKE '%' || ? || '%' 
            LIMIT 1;
            """
            
            return executeSearch(sql: fallbackSQL, bindValue: speechText)
        }
    }
    
    // Вспомогательный метод выполнения SQL-запроса поиска
    private func executeSearch(sql: String, bindValue: String) -> ObjectionMatch? {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        
        let prepareResult = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        guard prepareResult == SQLITE_OK else { return nil }
        
        // Привязываем строковой параметр к подготовленному запросу (биндинг защищает от SQL-инъекций)
        let nsString = bindValue as NSString
        sqlite3_bind_text(statement, 1, nsString.utf8String, -1, nil)
        
        // Если это fallback-запрос, привязываем второй параметр
        if sql.contains("OR objection_trigger LIKE") {
            sqlite3_bind_text(statement, 2, nsString.utf8String, -1, nil)
        }
        
        if sqlite3_step(statement) == SQLITE_ROW {
            let id = Int(sqlite3_column_int(statement, 0))
            
            let trigger = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? ""
            let script = sqlite3_column_text(statement, 2).map { String(cString: $0) } ?? ""
            let haptic = Int(sqlite3_column_int(statement, 3))
            
            return ObjectionMatch(id: id, trigger: trigger, responseScript: script, hapticPattern: haptic)
        }
        return nil
    }
    
    // Фильтрация спецсимволов для предотвращения ошибок синтаксического анализатора FTS5
    private func cleanSearchTerm(_ term: String) -> String {
        let allowedCharacters = CharacterSet.alphanumerics.union(.whitespaces)
        return term.components(separatedBy: allowedCharacters.inverted).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
