//
//  AcousticAnalyzer.swift
//  Clandeq
//
//  Created by SuperMax (AI Senior Developer) on 2026-06-01.
//  Copyright © 2026 PAPAMETALL CORPORATION. All rights reserved.
//

import Foundation
import AVFoundation

/// Сводный отчет о текущем акустическом фоне переговоров
struct AcousticMetrics {
    let stressLevel: Double  // Уровень стресса/напряжения в голосе (от 0.0 до 1.0)
    let talkRatio: Double    // Текущий коэффициент вещания менеджера (от 0.0 до 1.0)
}

/// AcousticAnalyzer симулирует инференс CoreML модели для оценки просодии речи.
/// Вместо слепой генерации случайных чисел, анализатор рассчитывает реальное среднеквадратичное
/// значение амплитуды (RMS) аудио-буфера PCM, выявляя резкие колебания громкости и пауз.
final class AcousticAnalyzer {
    
    private var lastRMSValues: [Float] = []
    private let maxHistoryLength = 20
    
    // Переменные для расчета Talk-Ratio (динамическое соотношение голосов)
    private var managerSamplesCount = 0
    private var clientSamplesCount = 0
    
    /// Анализирует входящий PCM буфер и возвращает акустические метрики в реальном времени
    /// - Parameter buffer: Сырой аудио-буфер от микрофона устройства
    func analyze(buffer: AVAudioPCMBuffer) -> AcousticMetrics {
        guard let channelData = buffer.floatChannelData else {
            return AcousticMetrics(stressLevel: 0.1, talkRatio: 0.5)
        }
        
        let frameLength = Int(buffer.frameLength)
        let channelPointer = channelData[0]
        
        // 1. Рассчитываем RMS (Root Mean Square) для оценки энергии сигнала (громкости)
        var sumOfSquares: Float = 0.0
        for i in 0..<frameLength {
            let sample = channelPointer[i]
            sumOfSquares += sample * sample
        }
        
        let rms = frameLength > 0 ? sqrt(sumOfSquares / Float(frameLength)) : 0.0
        updateRMSHistory(rms)
        
        // 2. Симуляция расчета уровня стресса на основе дисперсии энергии
        // Резкие скачки громкости и высокая волатильность RMS указывают на эмоциональное возбуждение (стресс)
        let stress = calculateStressLevel(currentRMS: rms)
        
        // 3. Симуляция детекции спикера (VAD - Voice Activity Detection / Diarization)
        // Для демонстрации: если энергия буфера превышает порог тишины, распределяем активность
        // В продакшене здесь работает CoreML-классификатор спикеров
        updateTalkRatio(currentRMS: rms)
        
        let totalSamples = managerSamplesCount + clientSamplesCount
        let talkRatio = totalSamples > 0 ? Double(managerSamplesCount) / Double(totalSamples) : 0.5
        
        return AcousticMetrics(stressLevel: stress, talkRatio: talkRatio)
    }
    
    private func updateRMSHistory(_ rms: Float) {
        lastRMSValues.append(rms)
        if lastRMSValues.count > maxHistoryLength {
            lastRMSValues.removeFirst()
        }
    }
    
    private func calculateStressLevel(currentRMS: Float) -> Double {
        guard lastRMSValues.count > 2 else { return 0.1 }
        
        // Вычисляем среднее значение и стандартное отклонение RMS за последнее время
        let mean = lastRMSValues.reduce(0, +) / Float(lastRMSValues.count)
        let sumOfDerivations = lastRMSValues.reduce(0) { $0 + pow($1 - mean, 2) }
        let stdDev = sqrt(sumOfDerivations / Float(lastRMSValues.count))
        
        // Чем выше девиация энергии (stdDev) и текущая амплитуда, тем выше стресс-коэффициент
        let stressFactor = Double(stdDev * 10.0 + currentRMS * 2.0)
        
        // Ограничиваем значение в диапазоне [0.0, 1.0]
        return min(max(stressFactor, 0.0), 1.0)
    }
    
    private func updateTalkRatio(currentRMS: Float) {
        let silenceThreshold: Float = 0.01
        
        if currentRMS > silenceThreshold {
            // Симулируем диаризацию: чередуем реплики случайным образом при активности,
            // отдавая небольшой приоритет менеджеру
            if Float.random(in: 0...1) > 0.45 {
                managerSamplesCount += 1
            } else {
                clientSamplesCount += 1
            }
        }
        
        // Сбрасываем счетчики каждые 5000 итераций для плавающего окна анализа
        if managerSamplesCount + clientSamplesCount > 5000 {
            managerSamplesCount = Int(Double(managerSamplesCount) * 0.2)
            clientSamplesCount = Int(Double(clientSamplesCount) * 0.2)
        }
    }
}
