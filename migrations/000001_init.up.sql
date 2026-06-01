-- 000001_init.up.sql
-- Инициализация схемы базы данных для B2B SaaS продукта Clandeq (Edge AI Copilot)

-- Поддержка автоматического создания UUID
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- Функция для автоматического обновления поля updated_at
CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = CURRENT_TIMESTAMP;
    RETURN NEW;
END;
$$ language 'plpgsql';

-- 1. Таблица Пользователей (Менеджеры переговоров)
CREATE TABLE IF NOT EXISTS users (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    email VARCHAR(255) UNIQUE NOT NULL,
    password_hash VARCHAR(255) NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- Индекс для быстрого поиска по email при авторизации
CREATE INDEX IF NOT EXISTS idx_users_email ON users(email);

-- Триггер автообновления updated_at для users
CREATE TRIGGER trigger_update_users_updated_at
    BEFORE UPDATE ON users
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();


-- 1.1 Таблица API-токенов (Поддержка нескольких токенов/устройств на пользователя)
CREATE TABLE IF NOT EXISTS user_tokens (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    token VARCHAR(255) UNIQUE NOT NULL,
    device_name VARCHAR(100), -- Описание устройства (например, "iPhone 15 Pro", "Apple Watch S9")
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    expires_at TIMESTAMP WITH TIME ZONE -- Опциональный срок действия токена
);

-- Индекс для валидации сессии/токена при каждом API-запросе
CREATE INDEX IF NOT EXISTS idx_user_tokens_token ON user_tokens(token);
CREATE INDEX IF NOT EXISTS idx_user_tokens_user_id ON user_tokens(user_id);


-- 2. Таблица Клиентов (B2B-клиенты, импортированные из CRM)
CREATE TABLE IF NOT EXISTS clients (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    crm_id VARCHAR(100) UNIQUE, -- Ссылка на ID во внешней CRM (Bitrix24, Salesforce и т.д.)
    name VARCHAR(255) NOT NULL,
    company VARCHAR(255),
    email VARCHAR(255),
    phone VARCHAR(50),
    metadata JSONB DEFAULT '{}'::jsonb, -- Кастомные поля CRM
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- Индексы на внешние ключи и GIN-индекс для быстрого поиска внутри metadata
CREATE INDEX IF NOT EXISTS idx_clients_user_id ON clients(user_id);
CREATE INDEX IF NOT EXISTS idx_clients_crm_id ON clients(crm_id);
CREATE INDEX IF NOT EXISTS idx_clients_metadata_gin ON clients USING gin (metadata);

-- Триггер автообновления updated_at для clients
CREATE TRIGGER trigger_update_clients_updated_at
    BEFORE UPDATE ON clients
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();


-- 3. Таблица Сделок (Дела/переговоры)
CREATE TABLE IF NOT EXISTS deals (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    client_id UUID NOT NULL REFERENCES clients(id) ON DELETE CASCADE,
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    crm_id VARCHAR(100) UNIQUE, -- ID сделки в CRM
    title VARCHAR(255) NOT NULL,
    status VARCHAR(100) NOT NULL,
    value NUMERIC(15, 2) DEFAULT 0.00 CHECK (value >= 0.00), -- Проверка на неотрицательность
    currency VARCHAR(10) DEFAULT 'USD',
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- Индексы для фильтрации и поиска сделок (составной индекс для листинга сделок по статусу)
CREATE INDEX IF NOT EXISTS idx_deals_client_id ON deals(client_id);
CREATE INDEX IF NOT EXISTS idx_deals_user_id_status ON deals(user_id, status);
CREATE INDEX IF NOT EXISTS idx_deals_crm_id ON deals(crm_id);

-- Триггер автообновления updated_at для deals
CREATE TRIGGER trigger_update_deals_updated_at
    BEFORE UPDATE ON deals
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();


-- 4. Таблица Контекста Сделки (Сжатая история и тактические скрипты для мобильного Edge AI)
CREATE TABLE IF NOT EXISTS deal_contexts (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    deal_id UUID UNIQUE NOT NULL REFERENCES deals(id) ON DELETE CASCADE,
    compressed_history TEXT NOT NULL, -- Сжатый суммаризированный лог прошлых встреч
    rules_and_scripts JSONB NOT NULL DEFAULT '{}'::jsonb, -- Карта "Возражение -> Сценарий ответа / haptic паттерн"
    sqlite_file_url TEXT, -- Ссылка на подготовленный SQLite файл на бэкенде
    version INT NOT NULL DEFAULT 1,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- Индекс на внешний ключ и GIN-индекс для скриптов
CREATE INDEX IF NOT EXISTS idx_deal_contexts_deal_id ON deal_contexts(deal_id);
CREATE INDEX IF NOT EXISTS idx_deal_contexts_rules_and_scripts_gin ON deal_contexts USING gin (rules_and_scripts);

-- Триггер автообновления updated_at для deal_contexts
CREATE TRIGGER trigger_update_deal_contexts_updated_at
    BEFORE UPDATE ON deal_contexts
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();


-- 5. Таблица Телеметрии Встреч (Пост-аналитика после завершения переговоров)
CREATE TABLE IF NOT EXISTS meeting_logs (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    deal_id UUID NOT NULL REFERENCES deals(id) ON DELETE CASCADE,
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    meeting_date TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    transcript TEXT, -- Семантическая транскрибация встречи (выгруженная с телефона)
    stress_timeline JSONB DEFAULT '{}'::jsonb, -- Временная шкала уровня стресса (акустический анализ)
    talk_ratio NUMERIC(5, 2) CHECK (talk_ratio >= 0.00 AND talk_ratio <= 1.00), -- Соотношение говорения менеджера (от 0.00 до 1.00)
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- Составной индекс для хронологического листинга логов встреч по сделке
CREATE INDEX IF NOT EXISTS idx_meeting_logs_deal_id_date ON meeting_logs(deal_id, meeting_date DESC);
CREATE INDEX IF NOT EXISTS idx_meeting_logs_user_id ON meeting_logs(user_id);
