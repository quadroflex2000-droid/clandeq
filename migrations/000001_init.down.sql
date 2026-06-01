-- 000001_init.down.sql
-- Откат схемы базы данных для Clandeq (Edge AI Copilot)

DROP TABLE IF EXISTS meeting_logs CASCADE;
DROP TABLE IF EXISTS deal_contexts CASCADE;
DROP TABLE IF EXISTS deals CASCADE;
DROP TABLE IF EXISTS clients CASCADE;
DROP TABLE IF EXISTS user_tokens CASCADE;
DROP TABLE IF EXISTS users CASCADE;

DROP FUNCTION IF EXISTS update_updated_at_column CASCADE;
DROP EXTENSION IF EXISTS "uuid-ossp";
