// Package packager компилирует сжатый ИИ-контекст и тактические правила в локальный SQLite-файл
package packager

import (
	"context"
	"database/sql"
	"fmt"
	"os"
	"path/filepath"
	"time"

	"clandeq/internal/ai"

	// Импортируем pure-Go драйвер SQLite без зависимостей от CGO
	_ "modernc.org/sqlite"
)

// PackagerService управляет созданием локальных баз данных SQLite для мобильных устройств
type PackagerService struct {
	storageDir string
}

// NewPackagerService создает новый экземпляр сервиса
func NewPackagerService(storageDir string) (*PackagerService, error) {
	// Создаем директорию для хранения файлов, если она отсутствует
	if err := os.MkdirAll(storageDir, 0755); err != nil {
		return nil, fmt.Errorf("failed to create storage directory: %w", err)
	}
	return &PackagerService{storageDir: storageDir}, nil
}

// CreateOfflineDB компилирует данные по сделке в зашифрованный/изолированный .sqlite файл
func (s *PackagerService) CreateOfflineDB(ctx context.Context, dealID string, data *ai.ClandeqContext) (string, error) {
	// Генерируем уникальное имя файла для конкретной версии сделки
	filename := fmt.Sprintf("deal_%s_%d.sqlite", dealID, time.Now().Unix())
	dbPath := filepath.Join(s.storageDir, filename)

	// Если файл уже существует (например, при коллизиях), удаляем его
	_ = os.Remove(dbPath)

	// Открываем/создаем новый файл SQLite базы данных.
	// Используем pure-Go драйвер "sqlite"
	db, err := sql.Open("sqlite", dbPath)
	if err != nil {
		return "", fmt.Errorf("failed to open sqlite file %s: %w", dbPath, err)
	}
	defer db.Close()

	// Настройка прагм для экстремальной производительности и минимизации операций записи на flash-память iPhone
	pragmas := []string{
		"PRAGMA journal_mode = OFF;", // Отключаем логирование для одноразовой быстрой записи
		"PRAGMA synchronous = OFF;",  // Асинхронная запись для скорости
		"PRAGMA foreign_keys = ON;",  // Включаем валидацию внешних ключей
	}
	for _, pragma := range pragmas {
		if _, err := db.ExecContext(ctx, pragma); err != nil {
			return "", fmt.Errorf("failed to set pragma: %w", err)
		}
	}

	// 1. Создаем структуру таблиц для оффлайн работы
	schema := `
	-- Таблица метаданных (для версионирования)
	CREATE TABLE IF NOT EXISTS metadata (
		key TEXT PRIMARY KEY,
		value TEXT NOT NULL
	);

	-- Таблица сжатой истории сделки
	CREATE TABLE IF NOT EXISTS deal_context (
		deal_id TEXT PRIMARY KEY,
		compressed_history TEXT NOT NULL,
		updated_at TEXT NOT NULL
	);

	-- Таблица тактических правил для оффлайн сопоставления на встрече
	CREATE TABLE IF NOT EXISTS objection_rules (
		id INTEGER PRIMARY KEY AUTOINCREMENT,
		objection_trigger TEXT NOT NULL,
		response_script TEXT NOT NULL,
		haptic_pattern INTEGER NOT NULL
	);

	-- Создаем FTS5 (Full-Text Search) виртуальную таблицу для мгновенного текстового поиска по триггерам без интернета
	CREATE VIRTUAL TABLE IF NOT EXISTS objection_rules_fts USING fts5(
		objection_trigger,
		content='objection_rules',
		content_rowid='id'
	);

	-- Триггеры для автоматической синхронизации FTS индекса при вставке данных
	CREATE TRIGGER IF NOT EXISTS t_objection_rules_ai AFTER INSERT ON objection_rules BEGIN
		INSERT INTO objection_rules_fts(rowid, objection_trigger) VALUES (new.id, new.objection_trigger);
	END;
	`
	if _, err := db.ExecContext(ctx, schema); err != nil {
		return "", fmt.Errorf("failed to create offline database schema: %w", err)
	}

	// Начало транзакции для атомарной быстрой сборки базы
	tx, err := db.BeginTx(ctx, nil)
	if err != nil {
		return "", fmt.Errorf("failed to begin transaction: %w", err)
	}
	defer tx.Rollback() // Откатит изменения, если транзакция не завершится успешным Commit()

	// 2. Вставка метаданных
	metaQuery := `INSERT INTO metadata (key, value) VALUES (?, ?);`
	metadata := map[string]string{
		"deal_id":     dealID,
		"version":     "1",
		"compiled_at": time.Now().Format(time.RFC3339),
	}
	for k, v := range metadata {
		if _, err := tx.ExecContext(ctx, metaQuery, k, v); err != nil {
			return "", fmt.Errorf("failed to insert metadata %s: %w", k, err)
		}
	}

	// 3. Вставка сжатой истории
	contextQuery := `INSERT INTO deal_context (deal_id, compressed_history, updated_at) VALUES (?, ?, ?);`
	if _, err := tx.ExecContext(ctx, contextQuery, dealID, data.CompressedHistory, time.Now().Format(time.RFC3339)); err != nil {
		return "", fmt.Errorf("failed to insert compressed history: %w", err)
	}

	// 4. Вставка возражений и скриптов
	ruleQuery := `INSERT INTO objection_rules (objection_trigger, response_script, haptic_pattern) VALUES (?, ?, ?);`
	stmt, err := tx.PrepareContext(ctx, ruleQuery)
	if err != nil {
		return "", fmt.Errorf("failed to prepare rule statement: %w", err)
	}
	defer stmt.Close()

	for _, rule := range data.RulesAndScripts {
		if _, err := stmt.ExecContext(ctx, rule.ObjectionTrigger, rule.ResponseScript, rule.HapticPattern); err != nil {
			return "", fmt.Errorf("failed to insert rule with trigger %s: %w", rule.ObjectionTrigger, err)
		}
	}

	// Фиксируем транзакцию на диске
	if err := tx.Commit(); err != nil {
		return "", fmt.Errorf("failed to commit offline db transaction: %w", err)
	}

	return dbPath, nil
}
