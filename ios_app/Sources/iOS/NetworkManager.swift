//
//  NetworkManager.swift
//  Clandeq
//
//  Created by SuperMax (AI Senior Developer) on 2026-06-01.
//  Copyright © 2026 PAPAMETALL CORPORATION. All rights reserved.
//

import Foundation
import SQLite3

/// Перечисление возможных сетевых ошибок и сбоев файловой системы.
/// Соответствует протоколу LocalizedError для автоматического отображения читаемых сообщений на русском языке.
enum NetworkError: Error, LocalizedError {
    case invalidURL
    case serverError(statusCode: Int)
    case invalidResponse
    case downloadFailed(String)
    case filesystemError(String)
    
    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Сформирован неверный или пустой URL-адрес для запроса к Go-бэкенду Clandeq."
        case .serverError(let code):
            return "Критическая ошибка удаленного сервера Clandeq. Код ответа HTTP: \(code)."
        case .invalidResponse:
            return "Go-сервер вернул некорректный формат ответа (ожидался JSON с метаданными)."
        case .downloadFailed(let message):
            return "Не удалось осуществить загрузку SQLite-базы данных: \(message)"
        case .filesystemError(let message):
            return "Сбой локальной файловой системы iOS при сохранении SQLite: \(message)"
        }
    }
}

/// Модель ответа Go-бэкенда при успешном завершении ИИ-генерации (Gemini 2.5 Flash) и компиляции базы.
struct SyncResponse: Codable {
    let status: String
    let dealId: String
    let downloadUrl: String
    let compressedHistory: String
    
    enum CodingKeys: String, CodingKey {
        case status
        case dealId = "deal_id"
        case downloadUrl = "download_url"
        case compressedHistory = "compressed_history"
    }
}

/// NetworkManager — главный сетевой шлюз мобильного приложения Clandeq.
/// Разработан на базе современного асинхронного стека Apple Swift (Concurrency SDK - async/await).
final class NetworkManager {
    static let shared = NetworkManager()
    
    // Дефолтный fallback URL бэкенда
    private let defaultBaseURLString = "http://localhost:8080/api/v1"
    
    private init() {}
    
    /// Получает текущий рабочий URL бэкенда из реестра на GitHub
    private func fetchCurrentBaseURL() async -> String {
        let registryURLString = "https://raw.githubusercontent.com/quadroflex2000-droid/clandeq/main/backend_url.txt"
        guard let url = URL(string: registryURLString) else {
            return defaultBaseURLString
        }
        
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            if let fetchedURL = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !fetchedURL.isEmpty {
                #if DEBUG
                print("[NetworkManager] Обнаружен динамический бэкенд URL: \(fetchedURL)")
                #endif
                return fetchedURL + "/api/v1"
            }
        } catch {
            #if DEBUG
            print("[NetworkManager] Ошибка загрузки бэкенд URL: \(error.localizedDescription)")
            #endif
        }
        
        return defaultBaseURLString
    }
    
    /// Основной метод синхронизации:
    /// 1. Отправляет POST-запрос на Go-бэкенд для запуска Gemini 2.5 Flash генерации.
    /// 2. Получает ответ с прямой ссылкой на скачивание SQLite-файла.
    /// 3. Потоком (через Stream download) скачивает файл во избежание утечек ОЗУ.
    /// 4. Переносит в изолированную песочницу (Sandbox) iOS - папку Documents/Clandeq.
    ///
    /// - Parameter dealID: UUID сделки из CRM Битрикс24.
    /// - Returns: URL-адрес на сохраненный файл базы данных во внутренней файловой системе iPhone.
    func syncAndDownloadOfflineDB(for dealID: String) async throws -> URL {
        // Динамически запрашиваем актуальный адрес бэкенда перед отправкой запроса
        let activeBaseURL = await fetchCurrentBaseURL()
        
        // Формируем URL для запуска ИИ-пайплайна
        guard let syncURL = URL(string: "\(activeBaseURL)/deals/\(dealID)/sync") else {
            throw NetworkError.invalidURL
        }
        
        var request = URLRequest(url: syncURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Тайм-аут выставлен на 30 секунд, так как Gemini 2.5 Flash отрабатывает быстро, но паковщику нужно собрать SQLite
        request.timeoutInterval = 30.0
        
        let data: Data
        let response: URLResponse
        
        do {
            // Выполняем асинхронный сетевой запрос
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw NetworkError.downloadFailed("Ошибка сетевого соединения: \(error.localizedDescription)")
        }
        
        // Валидируем HTTP статус
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NetworkError.invalidResponse
        }
        
        guard (200...299).contains(httpResponse.statusCode) else {
            throw NetworkError.serverError(statusCode: httpResponse.statusCode)
        }
        
        // Декодируем метаданные, содержащие прямую ссылку на SQLite файл
        let decoder = JSONDecoder()
        guard let syncResponse = try? decoder.decode(SyncResponse.self, from: data) else {
            throw NetworkError.invalidResponse
        }
        
        // Запускаем вторую фазу: скачивание бинарного файла SQLite
        var downloadURLString = syncResponse.downloadUrl
        // Обеспечиваем безопасное HTTPS-соединение для обхода iOS ATS ограничений
        if downloadURLString.hasPrefix("http://") {
            downloadURLString = downloadURLString.replacingOccurrences(of: "http://", with: "https://")
        }
        
        // Корректируем хост, если бэкенд вернул дефолтный localhost или старый туннель
        if downloadURLString.contains("localhost:8080/api/v1") {
            downloadURLString = downloadURLString.replacingOccurrences(of: "http://localhost:8080/api/v1", with: activeBaseURL)
            downloadURLString = downloadURLString.replacingOccurrences(of: "https://localhost:8080/api/v1", with: activeBaseURL)
        } else if !downloadURLString.contains(activeBaseURL) {
            // Если бэкенд вернул http версию динамического хоста, обновляем ее до активного HTTPS хоста
            if let hostMatch = downloadURLString.components(separatedBy: "/api/v1").first {
                downloadURLString = downloadURLString.replacingOccurrences(of: hostMatch + "/api/v1", with: activeBaseURL)
            }
        }
        
        return try await downloadSQLiteFile(from: downloadURLString, for: dealID)
    }
    
    /// Скачивает бинарный файл напрямую во временный буфер файловой системы, а затем перемещает в документы.
    /// Это предотвращает удержание больших объемов данных в оперативной памяти (RAM) iPhone.
    private func downloadSQLiteFile(from urlString: String, for dealID: String) async throws -> URL {
        guard let downloadURL = URL(string: urlString) else {
            throw NetworkError.invalidURL
        }
        
        let tempLocalURL: URL
        let response: URLResponse
        
        do {
            // Потоковая загрузка файла во временную директорию iOS (tmp/)
            (tempLocalURL, response) = try await URLSession.shared.download(from: downloadURL)
        } catch {
            throw NetworkError.downloadFailed("Не удалось установить сессию скачивания бинарного файла: \(error.localizedDescription)")
        }
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NetworkError.invalidResponse
        }
        
        guard (200...299).contains(httpResponse.statusCode) else {
            throw NetworkError.serverError(statusCode: httpResponse.statusCode)
        }
        
        // --- РАБОТА С ФАЙЛОВОЙ СИСТЕМОЙ IOS (SANDBOX MECHANICS) ---
        let fileManager = FileManager.default
        
        // 1. Получаем путь к системной директории Documents приложения.
        // Каждый экземпляр iOS-приложения работает в изолированном контейнере (Sandbox).
        // Доступ к внешней файловой системе запрещен, а папка Documents сохраняется при бэкапах iCloud.
        guard let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw NetworkError.filesystemError("Не удалось получить доступ к DocumentDirectory приложения.")
        }
        
        // 2. Создаем выделенную поддиректорию Clandeq внутри Documents для чистоты структуры
        let clandeqFolderURL = documentsURL.appendingPathComponent("Clandeq", isDirectory: true)
        
        do {
            if !fileManager.fileExists(atPath: clandeqFolderURL.path) {
                // Создаем папку, включая все промежуточные директории (withIntermediateDirectories: true)
                try fileManager.createDirectory(at: clandeqFolderURL, withIntermediateDirectories: true, attributes: nil)
            }
        } catch {
            throw NetworkError.filesystemError("Не удалось создать целевую директорию 'Clandeq': \(error.localizedDescription)")
        }
        
        // 3. Формируем финальное имя файла для конкретной сделки
        let destinationURL = clandeqFolderURL.appendingPathComponent("deal_\(dealID)_offline.sqlite")
        
        do {
            // Если база по этой сделке скачивалась ранее, удаляем старый файл, так как FileManager.moveItem() выдаст ошибку при перезаписи
            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.removeItem(at: destinationURL)
            }
            
            // Переносим скачанный файл из временного кэша (.tmp) в постоянную директорию
            try fileManager.moveItem(at: tempLocalURL, to: destinationURL)
        } catch {
            throw NetworkError.filesystemError("Ошибка копирования файла из временного кэша: \(error.localizedDescription)")
        }
        
        #if DEBUG
        print("[Clandeq iOS] База данных сделки \(dealID) успешно зафиксирована в локальном хранилище по пути: \(destinationURL.path)")
        #endif
        
        return destinationURL
    }
    
    /// Локально разворачивает оффлайн демо-база данных SQLite прямо на устройстве в условиях отсутствия интернета
    func createMockOfflineDB(for dealID: String) throws -> URL {
        let fileManager = FileManager.default
        guard let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw NetworkError.filesystemError("Не удалось получить доступ к DocumentDirectory.")
        }
        
        let clandeqFolderURL = documentsURL.appendingPathComponent("Clandeq", isDirectory: true)
        if !fileManager.fileExists(atPath: clandeqFolderURL.path) {
            try fileManager.createDirectory(at: clandeqFolderURL, withIntermediateDirectories: true, attributes: nil)
        }
        
        let destinationURL = clandeqFolderURL.appendingPathComponent("deal_\(dealID)_offline.sqlite")
        
        // Если база существует, удаляем её перед пересозданием
        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        
        guard sqlite3_open_v2(destinationURL.path, &db, flags, nil) == SQLITE_OK else {
            let errorMsg = db != nil ? String(cString: sqlite3_errmsg(db)) : "Неизвестная ошибка"
            throw NetworkError.filesystemError("Ошибка создания локальной базы: \(errorMsg)")
        }
        
        defer { sqlite3_close(db) }
        
        let createQueries = [
            "CREATE TABLE IF NOT EXISTS deal_context (compressed_history TEXT);",
            "CREATE TABLE IF NOT EXISTS objection_rules (id INTEGER PRIMARY KEY, objection_trigger TEXT, response_script TEXT, haptic_pattern INTEGER);",
            "CREATE VIRTUAL TABLE IF NOT EXISTS objection_rules_fts USING fts5(objection_trigger, response_script);"
        ]
        
        for query in createQueries {
            guard sqlite3_exec(db, query, nil, nil, nil) == SQLITE_OK else {
                let errorMsg = db != nil ? String(cString: sqlite3_errmsg(db)) : "Неизвестная ошибка SQL"
                throw NetworkError.filesystemError("Ошибка инициализации таблиц: \(errorMsg)")
            }
        }
        
        // Вставка демонстрационных данных
        let inserts = [
            "INSERT INTO deal_context (compressed_history) VALUES ('• ДЕМО-РЕЖИМ (100% ОФФЛАЙН)\n• Инициализирован умный локальный симулятор переговоров.\n• Регламент тактик загружен из локального хранилища.');",
            "INSERT INTO objection_rules (id, objection_trigger, response_script, haptic_pattern) VALUES (1, 'дорого', 'Мы используем премиальную фурнитуру Blum и сертифицированную сталь с пожизненной гарантией. Это экономит до сорока процентов бюджета на дистанции пяти лет.', 2);",
            "INSERT INTO objection_rules (id, objection_trigger, response_script, haptic_pattern) VALUES (2, 'сроки', 'Все сорванные сроки компенсируются в размере одного процента от суммы контракта за каждый день просрочки по официальному договору.', 3);",
            "INSERT INTO objection_rules_fts (rowid, objection_trigger, response_script) VALUES (1, 'дорого', 'Мы используем премиальную фурнитуру Blum и сертифицированную сталь с пожизненной гарантией.');",
            "INSERT INTO objection_rules_fts (rowid, objection_trigger, response_script) VALUES (2, 'сроки', 'Все сорванные сроки компенсируются в размере одного процента от суммы контракта.');"
        ]
        
        for query in inserts {
            sqlite3_exec(db, query, nil, nil, nil)
        }
        
        print("[NetworkManager] Локальная демо-база успешно инициализирована по пути: \(destinationURL.path)")
        return destinationURL
    }
}
