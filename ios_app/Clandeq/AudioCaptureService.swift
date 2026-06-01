//
//  AudioCaptureService.swift
//  Clandeq
//
//  Created by SuperMax (AI Senior Developer) on 2026-06-01.
//  Copyright © 2026 PAPAMETALL CORPORATION. All rights reserved.
//

import Foundation
import AVFoundation

/// Протокол для объектов, желающих получать захваченные аудио-буферы в реальном времени
protocol AudioCaptureDelegate: AnyObject {
    /// Вызывается при получении сконвертированного буфера (16kHz, Mono, Float32) для транскрибации (Whisper)
    func audioCaptureService(_ service: AudioCaptureService, didCaptureConvertedBuffer buffer: AVAudioPCMBuffer, time: AVAudioTime)
    
    /// Вызывается при получении сырого буфера (оригинальный формат устройства) для акустического анализа (CoreML)
    func audioCaptureService(_ service: AudioCaptureService, didCaptureRawBuffer buffer: AVAudioPCMBuffer, time: AVAudioTime)
}

/// AudioCaptureService отвечает за фоновый захват аудио-потока с микрофона iPhone.
/// Включает в себя профессиональный модуль налету-даунсэмплинга (AVAudioConverter)
/// из оригинальной частоты дискретизации микрофона (обычно 44.1kHz или 48kHz) в 16kHz Mono Float32,
/// что является строгим системным требованием для оффлайн библиотеки Whisper.cpp.
final class AudioCaptureService {
    static let shared = AudioCaptureService()
    
    weak var delegate: AudioCaptureDelegate?
    
    private let audioEngine = AVAudioEngine()
    private var audioConverter: AVAudioConverter?
    
    // Целевой аудио-формат для Whisper.cpp (16000Hz, 1 канал, PCM Float32)
    private let targetFormat: AVAudioFormat
    
    private let queue = DispatchQueue(label: "com.clandeq.audio.capture.queue", qos: .userInteractive)
    
    private(set) var isRecording = false
    
    private init() {
        // Конфигурируем целевой формат: 16kHz, 1 канал, PCM Float 32bit (не интерливленный)
        self.targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                          sampleRate: 16000,
                                          channels: 1,
                                          interleaved: false)!
    }
    
    /// Инициализирует аудиосессию iOS для фоновой записи звука во время переговоров
    func configureAudioSession() throws {
        let audioSession = AVAudioSession.sharedInstance()
        
        // Категория playAndRecord с опциями фоновой работы и Bluetooth-гарнитур (AirPods)
        try audioSession.setCategory(.playAndRecord,
                                     mode: .measurement, // Минимальная задержка и отключение системных эквалайзеров
                                     options: [.allowBluetooth, .allowBluetoothA2DP, .defaultToSpeaker])
        
        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
    }
    
    /// Запускает захват аудио-потока с микрофона устройства
    func startCapture() throws {
        try queue.sync {
            guard !isRecording else { return }
            
            #if DEBUG
            print("[AudioCaptureService] Накапливаем ресурсы и запускаем аудио-движок...")
            #endif
            
            try configureAudioSession()
            
            let inputNode = audioEngine.inputNode
            let inputFormat = inputNode.inputFormat(forBus: 0)
            
            // Настраиваем конвертер аудиоформатов из входящего формата в 16kHz
            setupAudioConverter(from: inputFormat)
            
            // Устанавливаем TAP-точку для захвата буферов (размер буфера ~100мс для плавной обработки)
            let bufferSize: AVAudioFrameCount = 4096
            
            inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: inputFormat) { [weak self] (buffer, time) in
                guard let self = self else { return }
                self.processCapturedBuffer(buffer, time: time)
            }
            
            // Запускаем физический аудио-движок
            audioEngine.prepare()
            try audioEngine.start()
            
            isRecording = true
            
            #if DEBUG
            print("[AudioCaptureService] Аудио-захват успешно запущен. Входящий формат: \(inputFormat.sampleRate)Hz, \(inputFormat.channelCount)Ch")
            #endif
        }
    }
    
    /// Останавливает захват аудио и очищает TAP-порты во избежание утечек памяти
    func stopCapture() {
        queue.sync {
            guard isRecording else { return }
            
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
            
            // Деактивируем аудиосессию с возвратом управления системе
            let audioSession = AVAudioSession.sharedInstance()
            try? audioSession.setActive(false, options: .notifyOthersOnDeactivation)
            
            isRecording = false
            
            #if DEBUG
            print("[AudioCaptureService] Аудио-захват остановлен движок очищен.")
            #endif
        }
    }
    
    // Настройка конвертера аудиоформатов (AVAudioConverter)
    private func setupAudioConverter(from sourceFormat: AVAudioFormat) {
        if sourceFormat.sampleRate == targetFormat.sampleRate && sourceFormat.channelCount == targetFormat.channelCount {
            audioConverter = nil // Конвертация не требуется, форматы совпадают
            return
        }
        
        audioConverter = AVAudioConverter(from: sourceFormat, to: targetFormat)
        if audioConverter == nil {
            print("[AudioCaptureService] Ошибка: Не удалось создать аудиоконвертер.")
        }
    }
    
    // Потоковая обработка и раздача буферов двум потребителям
    private func processCapturedBuffer(_ rawBuffer: AVAudioPCMBuffer, time: AVAudioTime) {
        // Потребитель 1: Модуль акустического анализа (CoreML) получает сырой оригинальный буфер
        delegate?.audioCaptureService(self, didCaptureRawBuffer: rawBuffer, time: time)
        
        // Потребитель 2: Модуль оффлайн транскрибации (Whisper.cpp) получает конвертированный 16kHz Mono буфер
        guard let converter = audioConverter else {
            // Если конвертер не нужен, отдаем сырой буфер
            delegate?.audioCaptureService(self, didCaptureConvertedBuffer: rawBuffer, time: time)
            return
        }
        
        // Вычисляем размер целевого буфера (пропорционально коэффициенту сжатия частоты)
        let sampleRateRatio = targetFormat.sampleRate / rawBuffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(rawBuffer.frameLength) * sampleRateRatio) + 16
        
        guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
            print("[AudioCaptureService] Ошибка создания PCM буфера для конвертации.")
            return
        }
        
        var error: NSError?
        let inputBlock: AVAudioConverterInputBlock = { (inNumPackets, outStatus) -> AVAudioBuffer? in
            outStatus.pointee = .haveData
            return rawBuffer
        }
        
        // Выполняем конвертацию налету (AVAudioConverter Input Block API)
        let status = converter.convert(to: convertedBuffer, error: &error, withInputFrom: inputBlock)
        
        if status == .error || error != nil {
            print("[AudioCaptureService] Ошибка аудио-конвертации: \(error?.localizedDescription ?? "Неизвестно")")
            return
        }
        
        // Передаем сконвертированный 16kHz PCM Float32 буфер нашему делегату
        delegate?.audioCaptureService(self, didCaptureConvertedBuffer: convertedBuffer, time: time)
    }
}
