//
//  NetworkManager.swift
//  Clandeq
//
//  Created by SuperMax (AI Senior Developer) on 2026-06-01.
//  Copyright © 2026 PAPAMETALL CORPORATION. All rights reserved.
//

import Foundation

/// Ошибки сетевого взаимодействия
enum NetworkError: Error, LocalizedError {
    case invalidURL
    case serverError(statusCode: Int)
    case invalidResponse
    case downloadFailed(String)
    
    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Неверный формат URL-адреса."
        case .serverError(let code):
            return "Ошибка сервера. Код ответа: \(code)."
        case .invalidResponse:
            return "Сервер вернул некорректный ответ."
        case .downloadFailed(let message):
            return "Не удалось скачать файл базы данных: \(message)"
        }
    }
}

/// Модель ответа бэкенда на запрос синхронизации
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

/// NetworkManager отвечает за высокопроизводительное сетевое взаимодействие с Go-бэкендом Clandeq.
/// Использует современный concurrency стек Swift (async/await) и URLSession.
final class NetworkManager {
    static let shared = NetworkManager()
    
    // Базовый URL бэкенда (считывается из конфигурации, по умолчанию локальный ПК разработчика)
    private let baseURLString = "http://localhost:8080/api/v1"
    
    private init() {}
    
    /// Шаг 1. Инициирует синхронизацию сделки на Go-бэкенде и скачивает скомпилированный SQLite-файл
    /// - Parameter dealID: UUID сделки из CRM
    /// - Returns: URL локального сохраненного SQLite-файла во внутренней песочнице iPhone Documents
    func syncAndDownloadOfflineDB(for dealID: String) async throws -> URL {
        guard let syncURL = URL(string: "\(baseURLString)/deals/\(dealID)/sync") else {
            throw NetworkError.invalidURL
        }
        
        // Создаем POST-запрос для инициализации сборки оффлайн-базы
        var request = URLRequest(url: syncURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        // Выполняем сетевой запрос через async/await URLSession
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NetworkError.invalidResponse
        }
        
        guard (200...299).contains(httpResponse.statusCode) else {
            throw NetworkError.serverError(statusCode: httpResponse.statusCode)
        }
        
        // Декодируем ответ сервера для получения прямой ссылки на скачивание SQLite
        let decoder = JSONDecoder()
        let syncResponse = try decoder.decode(SyncResponse.self, from: data)
        
        // Шаг 2. Скачиваем бинарный файл .sqlite
        return try await downloadSQLiteFile(from: syncResponse.downloadUrl, for: dealID)
    }
    
    /// Скачивает файл базы данных по прямой ссылке в директорию Documents устройства
    private func downloadSQLiteFile(from urlString: String, for dealID: String) async throws -> URL {
        guard let downloadURL = URL(string: urlString) else {
            throw NetworkError.invalidURL
        }
        
        // Выполняем скачивание напрямую во временный файл во избежание перегрузки ОЗУ (File Streaming)
        let (tempLocalURL, response) = try await URLSession.shared.download(from: downloadURL)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NetworkError.invalidResponse
        }
        
        guard (200...299).contains(httpResponse.statusCode) else {
            throw NetworkError.serverError(statusCode: httpResponse.statusCode)
        }
        
        // Определяем целевой путь в защищенной песочнице Documents/Clandeq/
        let fileManager = FileManager.default
        let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let clandeqFolderURL = documentsURL.appendingPathComponent("Clandeq", isDirectory: true)
        
        // Создаем директорию Clandeq, если она еще не существует
        if !fileManager.fileExists(atPath: clandeqFolderURL.path) {
            try fileManager.createDirectory(at: clandeqFolderURL, withIntermediateDirectories: true, attributes: nil)
        }
        
        // Финальный путь для хранения оффлайн базы по сделке
        let destinationURL = clandeqFolderURL.appendingPathComponent("deal_\(dealID)_offline.sqlite")
        
        // Если старая версия базы уже существует — удаляем её перед записью новой
        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        
        // Перемещаем скачанный файл из временной директории по постоянному адресу
        try fileManager.moveItem(at: tempLocalURL, to: destinationURL)
        
        #if DEBUG
        print("[NetworkManager] База данных успешно сохранена по пути: \(destinationURL.path)")
        #endif
        
        return destinationURL
    }
}
