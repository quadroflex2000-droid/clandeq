# Stage 1: Build Stage
FROM golang:1.22-alpine AS builder

# Установка системных зависимостей для сборки (CA-сертификаты, git, tzdata)
RUN apk update && apk add --no-cache ca-certificates git tzdata

WORKDIR /build

# Кэширование Go-зависимостей (оптимизация скорости последующих сборок)
COPY go.mod go.sum ./
RUN go mod download

# Копирование исходного кода проекта
COPY . .

# Сборка оптимизированного бинарного файла без отладочных символов (-ldflags="-s -w")
# CGO_ENABLED=0 полностью убирает зависимость от системных библиотек libc
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build \
    -ldflags="-s -w" \
    -o clandeq-server \
    cmd/server/main.go


# Stage 2: Final Run Stage
FROM alpine:3.19 AS runner

# Безопасность: Установка актуальных корневых сертификатов для HTTPS запросов к Google API
RUN apk update && apk add --no-cache ca-certificates tzdata

WORKDIR /app

# Создание непривилегированного пользователя для запуска приложения (Security Best Practice)
RUN addgroup -S clandeqgroup && adduser -S clandequser -G clandeqgroup

# Копируем бинарный файл из Stage 1
COPY --from=builder /build/clandeq-server .

# Создаем папку для оффлайн баз SQLite и настраиваем права доступа для не-root пользователя
RUN mkdir -p /app/storage && \
    chown -R clandequser:clandeqgroup /app/storage && \
    chmod -R 755 /app/storage

# Переключаемся на безопасного пользователя
USER clandequser

# Конфигурация переменных окружения по умолчанию
ENV PORT=8080
ENV GEMINI_API_KEY=""
ENV STORAGE_DIR=/app/storage
ENV GIN_MODE=release

# Экспортируем порт веб-сервера Fiber
EXPOSE 8080

# Опционально: Определение точки монтирования (Volume) для сохранения SQLite файлов
VOLUME ["/app/storage"]

# Запуск приложения
ENTRYPOINT ["/app/clandeq-server"]
