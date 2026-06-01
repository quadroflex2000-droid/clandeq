//
//  NetworkManager.swift
//  Clandeq
//
//  Created by SuperMax (AI Senior Developer) on 2026-06-01.
//  Copyright © 2026 PAPAMETALL CORPORATION. All rights reserved.
//

import Foundation

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
    
    // Базовый URL Go-сервера Clandeq (считывается из конфигурации или по умолчанию указывает на локальную машину)
    private let baseURLString = "http://localhost:8080/api/v1"
    
    private init() {}
    
    /// Основной метод синхронизации:
    /// 1. Отправляет POST-запрос на Go-бэкенд для запуска Gemini 2.5 Flash генерации.
    /// 2. Получает ответ с прямой ссылкой на скачивание SQLite-файла.
    /// 3. Потоком (через Stream download) скачивает файл во избежание утечек ОЗУ.
    /// 4. Переносит в изолированную песочницу (Sandbox) iOS - папку Documents/Clandeq.
    ///
    /// - Parameter dealID: UUID сделки из CRM Битрикс24.
    /// - Returns: URL-адрес на сохраненный файл базы данных во внутренней файловой системе iPhone.
    func syncAndDownloadOfflineDB(for dealID: String) async throws -> URL {
        // Формируем URL для запуска ИИ-пайплайна
        guard let syncURL = URL(string: "\(baseURLString)/deals/\(dealID)/sync") else {
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
        return try await downloadSQLiteFile(from: syncResponse.downloadUrl, for: dealID)
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
}
