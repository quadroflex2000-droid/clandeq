//
//  AudioCaptureService.swift
//  Clandeq
//
//  Created by SuperMax (AI Senior Developer) on 2026-06-01.
//  Copyright © 2026 PAPAMETALL CORPORATION. All rights reserved.
//

import Foundation
import AVFoundation
import Speech

/// AudioCaptureService отвечает за фоновый захват аудио-потока с микрофона iPhone
/// и его локальное преобразование в текст (Speech-to-Text) в режиме реального времени.
final class AudioCaptureService {
    static let shared = AudioCaptureService()
    
    // Нативный распознаватель речи Apple для русского языка
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "ru-RU"))
    
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    
    private let audioEngine = AVAudioEngine()
    private let queue = DispatchQueue(label: "com.clandeq.audio.capture.queue", qos: .userInteractive)
    
    private(set) var isRecording = false
    
    /// Замыкание (callback) для передачи распознанных фраз оркестратору ClandeqEngine в реальном времени
    var onTranscriptionUpdate: ((String) -> Void)?
    
    private init() {}
    
    /// Инициализирует аудиосессию iOS для записи звука во время оффлайн переговоров
    func configureAudioSession() throws {
        let audioSession = AVAudioSession.sharedInstance()
        
        // playAndRecord с опциями фоновой работы и беспроводных Bluetooth-гарнитур (AirPods)
        try audioSession.setCategory(.playAndRecord,
                                     mode: .measurement, // Минимальная задержка и отключение эквалайзеров
                                     options: [.allowBluetooth, .allowBluetoothA2DP, .defaultToSpeaker])
        
        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
    }
    
    /// Запускает захват аудио-потока с микрофона и локальную расшифровку речи
    func startCapture() throws {
        try queue.sync {
            guard !isRecording else { return }
            
            #if DEBUG
            print("[AudioCaptureService] Запуск аудиодвижка и локального Speech Recognition...")
            #endif
            
            // 1. Сбрасываем старую сессию распознавания, если она существовала
            resetSpeechRecognition()
            
            // 2. Настраиваем системную аудиосессию
            try configureAudioSession()
            
            // 3. Создаем буферный запрос на распознавание
            recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
            guard let recognitionRequest = recognitionRequest else {
                throw NSError(domain: "Clandeq", code: -1, userInfo: [NSLocalizedDescriptionKey: "Не удалось инициализировать SFSpeechAudioBufferRecognitionRequest"])
            }
            
            // --- ТРЕБОВАНИЕ ПРИВАТНОСТИ (AIR-GAPPED PRIVACY) ---
            // Устанавливаем флаг в true. Это строго принуждает ОС использовать локальный ИИ-чип
            // Apple Neural Engine (ANE) для распознавания речи в оффлайне, полностью блокируя отправку
            // аудиозаписей разговоров на сервера Apple. Работает без интернета.
            recognitionRequest.requiresOnDeviceRecognition = true
            
            // Получаем промежуточные результаты по ходу того, как собеседник проговаривает слова
            recognitionRequest.shouldReportPartialResults = true
            
            // 4. Подключаем входную ноду микрофона
            let inputNode = audioEngine.inputNode
            let recordingFormat = inputNode.outputFormat(forBus: 0)
            
            // Очищаем TAP во избежание конфликтов
            inputNode.removeTap(onBus: 0)
            
            // Устанавливаем TAP для перехвата аудио-буферов
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { (buffer, _) in
                // Передаем каждый PCM-буфер микрофона в сессию распознавания
                recognitionRequest.append(buffer)
            }
            
            // 5. Запускаем физический аудиодвижок
            audioEngine.prepare()
            try audioEngine.start()
            
            // 6. Подключаем таску распознавания речи
            guard let recognizer = speechRecognizer, recognizer.isAvailable else {
                throw NSError(domain: "Clandeq", code: -2, userInfo: [NSLocalizedDescriptionKey: "Локальный русский SpeechRecognizer недоступен на данном устройстве"])
            }
            
            recognitionTask = recognizer.recognitionTask(with: recognitionRequest) { [weak self] (result, error) in
                guard let self = self else { return }
                
                if let result = result {
                    let transcribedText = result.bestTranscription.formattedString
                    
                    // Передаем транскрибированную строчку оркестратору
                    DispatchQueue.main.async {
                        self.onTranscriptionUpdate?(transcribedText)
                    }
                }
                
                if let error = error {
                    #if DEBUG
                    print("[AudioCaptureService] Статус сессии STT: \(error.localizedDescription)")
                    #endif
                }
            }
            
            isRecording = true
            
            #if DEBUG
            print("[AudioCaptureService] Локальный Speech Recognition успешно запущен в режиме Air-Gapped!")
            #endif
        }
    }
    
    /// Останавливает захват аудио и очищает TAP-порты во избежание утечек памяти
    func stopCapture() {
        queue.sync {
            guard isRecording else { return }
            
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
            
            recognitionRequest?.endAudio()
            recognitionTask?.cancel()
            
            let audioSession = AVAudioSession.sharedInstance()
            try? audioSession.setActive(false, options: .notifyOthersOnDeactivation)
            
            resetSpeechRecognition()
            
            isRecording = false
            
            #if DEBUG
            print("[AudioCaptureService] Локальный захват звука полностью остановлен.")
            #endif
        }
    }
    
    private func resetSpeechRecognition() {
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
    }
}
