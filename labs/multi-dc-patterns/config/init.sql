-- Инициализация базы данных orders для паттерна transactional outbox
-- Этот скрипт запускается автоматически при первом старте PostgreSQL-контейнера

-- Таблица бизнес-сущностей: заказы
CREATE TABLE IF NOT EXISTS orders (
    id          VARCHAR(255) PRIMARY KEY,
    customer_id VARCHAR(255) NOT NULL,
    status      VARCHAR(50)  NOT NULL DEFAULT 'CREATED',
    amount      NUMERIC(10,2) NOT NULL,
    created_at  TIMESTAMP    NOT NULL DEFAULT NOW(),
    updated_at  TIMESTAMP    NOT NULL DEFAULT NOW()
);

-- Таблица outbox: промежуточный буфер для публикации событий в Kafka.
-- Ключевой принцип: INSERT в outbox и UPDATE в orders происходят
-- в одной транзакции -> атомарность гарантирована базой данных.
-- Polling publisher (или Debezium CDC) читает outbox и публикует в Kafka.
CREATE TABLE IF NOT EXISTS outbox (
    id             UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
    aggregate_type VARCHAR(255) NOT NULL,   -- тип агрегата (например 'Order')
    aggregate_id   VARCHAR(255) NOT NULL,   -- идентификатор агрегата (orderId)
    event_type     VARCHAR(255) NOT NULL,   -- тип события (OrderCreated, OrderPaid)
    payload        JSONB        NOT NULL,   -- содержимое события в формате JSON
    created_at     TIMESTAMP    NOT NULL DEFAULT NOW(),
    published      BOOLEAN      NOT NULL DEFAULT FALSE  -- флаг успешной публикации
);

-- Индекс для быстрого polling непубликованных событий.
-- WHERE NOT published: partial index -- только для строк где published=false.
-- Когда все события опубликованы, индекс практически пуст -> быстрый поиск.
CREATE INDEX idx_outbox_unpublished
    ON outbox (published, created_at)
    WHERE NOT published;

-- Индекс для поиска по aggregate_id (полезен при дедупликации на consumer-side)
CREATE INDEX idx_outbox_aggregate_id
    ON outbox (aggregate_type, aggregate_id);
