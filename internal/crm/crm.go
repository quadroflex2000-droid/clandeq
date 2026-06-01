// Package crm обеспечивает интеграцию с внешними CRM-системами (Bitrix24, Salesforce и др.)
package crm

import (
	"context"
	"fmt"
	"time"
)

// CRMDealData представляет собой полную сырую информацию по сделке из CRM
type CRMDealData struct {
	DealID      string    `json:"deal_id"`
	Title       string    `json:"title"`
	ClientName  string    `json:"client_name"`
	CompanyName string    `json:"company_name"`
	Value       float64   `json:"value"`
	Currency    string    `json:"currency"`
	HistoryLogs []string  `json:"history_logs"` // Хронология коммуникаций, встреч, писем, комментариев
	Notes       string    `json:"notes"`        // Ручные заметки менеджеров, пожелания клиента
	UpdatedAt   time.Time `json:"updated_at"`
}

// CRMProvider определяет контракт для провайдеров интеграции с CRM
type CRMProvider interface {
	// GetDealData скачивает полную сырую историю по сделке
	GetDealData(ctx context.Context, crmDealID string) (*CRMDealData, error)
}

// MockCRMProvider — демонстрационная реализация CRMProvider для тестирования и автономной разработки
type MockCRMProvider struct{}

// NewMockCRMProvider создает новый экземпляр MockCRMProvider
func NewMockCRMProvider() *MockCRMProvider {
	return &MockCRMProvider{}
}

// GetDealData эмулирует запрос к Bitrix24/Salesforce REST API и возвращает реалистичные B2B-данные
func (m *MockCRMProvider) GetDealData(ctx context.Context, crmDealID string) (*CRMDealData, error) {
	// Симуляция сетевой задержки CRM API
	select {
	case <-ctx.Done():
		return nil, ctx.Err()
	case <-time.After(100 * time.Millisecond):
	}

	if crmDealID == "" {
		return nil, fmt.Errorf("crm deal id is required")
	}

	// Возвращаем богатый контекст переговоров для качественной обработки ИИ
	return &CRMDealData{
		DealID:      crmDealID,
		Title:       "Контракт на поставку серверного оборудования Enterprise-уровня",
		ClientName:  "Алексей Шевелев",
		CompanyName: "Delta Tech Middle East",
		Value:       150000.00,
		Currency:    "USD",
		HistoryLogs: []string{
			"2026-05-10: Первый контакт. Клиент ищет альтернативу Cisco. Интересует отказоустойчивость, доставка в Дубай за 3 недели. Бюджет жесткий.",
			"2026-05-15: Отправлено базовое коммерческое предложение. Клиент сказал: 'Цена слишком высокая по сравнению с локальными китайскими реселлерами'.",
			"2026-05-20: Звонок-презентация. Менеджер объяснил преимущества расширенной 5-летней гарантии и круглосуточной поддержки. Клиент взял паузу.",
			"2026-05-25: Клиент выразил сильное сомнение по поводу сроков интеграции ПО. Боится простоев своей ИТ-инфраструктуры.",
		},
		Notes: "ЛПР (Лицо принимающее решения) — Алексей, технический директор. Очень дотошный к деталям. Давит на цену, ссылаясь на предложение от Huawei. Боится срыва сроков, так как у них запуск проекта 1 июля 2026 года. Предпочитает авторитарный стиль общения, но ценит аргументы на основе SLA.",
		UpdatedAt: time.Now(),
	}, nil
}
