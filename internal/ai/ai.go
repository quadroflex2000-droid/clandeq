// Package ai обеспечивает интеграцию с Google Gen AI SDK (Gemini 1.5 Flash) для генерации RAG-контекста
package ai

import (
	"context"
	"encoding/json"
	"fmt"
	"os"

	"github.com/google/generative-ai-go/genai"
	"google.golang.org/api/option"
)

// AIService представляет собой клиент для работы с Gemini API
type AIService struct {
	client *genai.Client
}

// ClandeqContext представляет структуру ответа от ИИ, которая будет записана в базу данных
type ClandeqContext struct {
	CompressedHistory string             `json:"compressed_history"`
	RulesAndScripts   []ObjectionRule `json:"rules_and_scripts"`
}

// ObjectionRule представляет тактическую рекомендацию для локального оверлея
type ObjectionRule struct {
	ObjectionTrigger string `json:"objection_trigger"` // Описание триггера/возражения (например, "дорого", "Huawei", "сроки")
	ResponseScript   string `json:"response_script"`   // Сжатый речевой модуль для менеджера
	HapticPattern    int    `json:"haptic_pattern"`    // Идентификатор вибрации для Apple Watch (1: Мягкий, 2: Предупреждение, 3: Двойной)
}

// NewAIService инициализирует и возвращает сервис ИИ
func NewAIService(ctx context.Context, apiKey string) (*AIService, error) {
	if apiKey == "" {
		// Пытаемся прочитать из переменной окружения
		apiKey = os.Getenv("GEMINI_API_KEY")
	}
	if apiKey == "" {
		return nil, fmt.Errorf("gemini api key is required")
	}

	client, err := genai.NewClient(ctx, option.WithAPIKey(apiKey))
	if err != nil {
		return nil, fmt.Errorf("failed to create genai client: %w", err)
	}

	return &AIService{client: client}, nil
}

// Close закрывает сетевое соединение с Google API
func (s *AIService) Close() error {
	if s.client != nil {
		return s.client.Close()
	}
	return nil
}

// GenerateNegotiationContext принимает сырые данные CRM и формирует сжатый контекст с тактическими правилами
func (s *AIService) GenerateNegotiationContext(ctx context.Context, rawCRMData string) (*ClandeqContext, error) {
	model := s.client.GenerativeModel("gemini-1.5-flash")

	// Настройка системного промпта для жесткой калибровки формата вывода
	model.SystemInstruction = &genai.Content{
		Parts: []genai.Part{
			genai.Text(`Ты — тактический ИИ-координатор по B2B продажам. Твоя задача — проанализировать сырую историю сделки из CRM и подготовить два блока данных:
1. "compressed_history" — лаконичный текстовый свод текущего статуса переговоров, триггерных болевых точек клиента, его бюджета и конкурентов. Формат — емкие буллеты на русском языке. Максимум 300 слов.
2. "rules_and_scripts" — массив тактических правил возражений для Offline-RAG системы телефона. Каждое правило содержит:
   - "objection_trigger" (ключевые слова или суть возражения/сомнения клиента, например: "дорого", "Huawei", "сроки доставки", "SLA"),
   - "response_script" (короткий тактический ответ для вывода на Apple Watch — емко, без воды, профессиональный речевой модуль на 1-2 предложения),
   - "haptic_pattern" (целое число от 1 до 3: 1 для мягкой подсказки, 2 для предупреждения/стресса, 3 для критических триггеров конкурентов).

Выведи строго валидный JSON документ без разметки markdown, соответствующий JSON Schema:
{
  "compressed_history": "string",
  "rules_and_scripts": [
    {
      "objection_trigger": "string",
      "response_script": "string",
      "haptic_pattern": integer
    }
  ]
}`),
		},
	}

	// Запуск инференса
	resp, err := model.GenerateContent(ctx, genai.Text(rawCRMData))
	if err != nil {
		return nil, fmt.Errorf("failed to generate content from gemini: %w", err)
	}

	if len(resp.Candidates) == 0 || resp.Candidates[0].Content == nil || len(resp.Candidates[0].Content.Parts) == 0 {
		return nil, fmt.Errorf("gemini returned an empty response")
	}

	// Читаем сырой текст ответа
	rawText, ok := resp.Candidates[0].Content.Parts[0].(genai.Text)
	if !ok {
		return nil, fmt.Errorf("failed to cast gemini response part to text")
	}

	// Десериализуем в структуру
	var result ClandeqContext
	if err := json.Unmarshal([]byte(rawText), &result); err != nil {
		return nil, fmt.Errorf("failed to parse gemini json output: %w. raw output: %s", err, string(rawText))
	}

	return &result, nil
}
