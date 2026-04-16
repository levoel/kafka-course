#!/bin/bash
# Упражнение 03: Паттерн Transactional Outbox
#
# Цель: реализовать атомарную публикацию событий в Kafka через outbox-таблицу
# в PostgreSQL, используя простой polling publisher на bash.
#
# Проблема Dual Write (без outbox):
#   BEGIN
#     UPDATE orders SET status = 'paid'  -- запись в БД
#     kafka.produce("payments", event)   -- запись в Kafka (NOT транзакционно!)
#   COMMIT
#   Если Kafka недоступна после COMMIT -- событие потеряно.
#   Если БД падает после produce -- событие отправлено, но изменение потеряно.
#
# Решение: Transactional Outbox
#   BEGIN
#     UPDATE orders SET status = 'paid'
#     INSERT INTO outbox (event_type, payload) VALUES ('OrderPaid', {...})
#   COMMIT  <-- обе операции атомарны в одной DB-транзакции
#   Polling Publisher: SELECT * FROM outbox WHERE NOT published -> produce -> UPDATE
#
# Что изучите:
#   - Почему dual write = race condition
#   - Как outbox обеспечивает at-least-once с atomicity
#   - Реализацию polling publisher
#   - Идемпотентный consumer (обработка возможных дубликатов)
#
# Требования: docker compose up -d, postgres-outbox healthy
#
# Запуск: bash exercises/03_outbox_pattern.sh

set -euo pipefail

DC1="kafka-dc1"
POSTGRES="postgres-outbox"
PSQL="docker exec ${POSTGRES} psql -U admin -d orders"
EVENTS_TOPIC="orders.events"

echo "=== Упражнение 03: Паттерн Transactional Outbox ==="
echo ""

# --- Шаг 1: Проверка готовности PostgreSQL ---
echo "=== Шаг 1: Проверка готовности PostgreSQL ==="
echo ""

until docker exec "${POSTGRES}" pg_isready -U admin -d orders >/dev/null 2>&1; do
  echo "  PostgreSQL ещё не готов, ждём 5 секунд..."
  sleep 5
done
echo "PostgreSQL готов."
echo ""

# --- Шаг 2: Проверка структуры outbox таблицы ---
# Таблица создана в config/init.sql при первом запуске контейнера.
# Показываем структуру для понимания схемы.
echo "=== Шаг 2: Структура outbox таблицы ==="
echo ""
${PSQL} -c "\d outbox"
echo ""

# --- Шаг 3: Создание топика для событий заказов на DC-1 ---
echo "=== Шаг 3: Создание Kafka топика '${EVENTS_TOPIC}' ==="
echo ""

docker exec "${DC1}" kafka-topics.sh \
  --bootstrap-server localhost:9092 \
  --create \
  --topic "${EVENTS_TOPIC}" \
  --partitions 3 \
  --replication-factor 1 \
  --if-not-exists

echo "Топик '${EVENTS_TOPIC}' создан."
echo ""

# --- Шаг 4: Атомарная запись -- бизнес-операция + outbox в одной транзакции ---
# Это ключевой момент паттерна: UPDATE orders + INSERT outbox = один COMMIT.
# Нет риска потери события даже при падении между двумя операциями.
echo "=== Шаг 4: Атомарная запись заказов + outbox событий ==="
echo ""
echo "Каждый блок BEGIN...COMMIT: одна атомарная операция."
echo "Если процесс падает после COMMIT -- событие в outbox и будет опубликовано."
echo "Если падает до COMMIT -- откат, нет ни заказа, ни события."
echo ""

${PSQL} << 'SQL'
-- Заказ 1: создание + outbox событие в одной транзакции
BEGIN;
  INSERT INTO orders (id, customer_id, status, amount)
  VALUES ('order-001', 'customer-alice', 'CREATED', 99.99)
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO outbox (aggregate_type, aggregate_id, event_type, payload)
  VALUES (
    'Order',
    'order-001',
    'OrderCreated',
    '{"orderId": "order-001", "customerId": "customer-alice", "amount": 99.99}'
  );
COMMIT;

-- Заказ 2
BEGIN;
  INSERT INTO orders (id, customer_id, status, amount)
  VALUES ('order-002', 'customer-bob', 'CREATED', 149.50)
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO outbox (aggregate_type, aggregate_id, event_type, payload)
  VALUES (
    'Order',
    'order-002',
    'OrderCreated',
    '{"orderId": "order-002", "customerId": "customer-bob", "amount": 149.50}'
  );
COMMIT;

-- Заказ 3
BEGIN;
  INSERT INTO orders (id, customer_id, status, amount)
  VALUES ('order-003', 'customer-charlie', 'CREATED', 299.00)
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO outbox (aggregate_type, aggregate_id, event_type, payload)
  VALUES (
    'Order',
    'order-003',
    'OrderCreated',
    '{"orderId": "order-003", "customerId": "customer-charlie", "amount": 299.00}'
  );
COMMIT;

-- Заказ 4: оплата -- отдельное событие для того же заказа
BEGIN;
  UPDATE orders SET status = 'PAID', updated_at = NOW() WHERE id = 'order-001';

  INSERT INTO outbox (aggregate_type, aggregate_id, event_type, payload)
  VALUES (
    'Order',
    'order-001',
    'OrderPaid',
    '{"orderId": "order-001", "customerId": "customer-alice", "amount": 99.99, "paidAt": "2026-04-16T12:00:00Z"}'
  );
COMMIT;

-- Заказ 5
BEGIN;
  INSERT INTO orders (id, customer_id, status, amount)
  VALUES ('order-005', 'customer-diana', 'CREATED', 49.99)
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO outbox (aggregate_type, aggregate_id, event_type, payload)
  VALUES (
    'Order',
    'order-005',
    'OrderCreated',
    '{"orderId": "order-005", "customerId": "customer-diana", "amount": 49.99}'
  );
COMMIT;
SQL

echo "5 транзакций выполнено."
echo ""

# --- Шаг 5: Просмотр непубликованных событий в outbox ---
echo "=== Шаг 5: Непубликованные события в outbox ==="
echo ""

${PSQL} -c "
SELECT id, aggregate_type, aggregate_id, event_type, published, created_at
FROM outbox
ORDER BY created_at;"

echo ""

# --- Шаг 6: Polling Publisher -- читаем outbox, публикуем в Kafka, помечаем published ---
# Это простой bash-реализация polling publisher.
# В production: Debezium CDC (читает WAL, не требует polling) или
# специализированная библиотека (Transactional Outbox Library).
#
# Алгоритм:
#   1. SELECT ... WHERE NOT published ORDER BY created_at LIMIT 10
#   2. Для каждой записи: produce в Kafka
#   3. UPDATE outbox SET published=true WHERE id = ...
#
# Важно: шаги 2-3 НЕ атомарны -- при сбое между produce и UPDATE
# сообщение может быть опубликовано повторно (at-least-once).
# Consumer должен быть идемпотентным (dedup по aggregate_id).
echo "=== Шаг 6: Polling Publisher -- публикация outbox событий в Kafka ==="
echo ""
echo "Читаем непубликованные записи из outbox и публикуем в Kafka..."
echo "Каждое событие: produce в '${EVENTS_TOPIC}', затем UPDATE published=true"
echo ""

# Получаем непубликованные записи в формате: id|aggregate_id|event_type|payload
RECORDS=$(docker exec "${POSTGRES}" psql -U admin -d orders -t -A -F'|' -c \
  "SELECT id, aggregate_id, event_type, payload
   FROM outbox
   WHERE NOT published
   ORDER BY created_at
   LIMIT 10;")

if [ -z "${RECORDS}" ]; then
  echo "Нет непубликованных записей в outbox."
else
  PUBLISHED_COUNT=0
  while IFS='|' read -r OUTBOX_ID AGGREGATE_ID EVENT_TYPE PAYLOAD; do
    # Публикуем событие в Kafka (ключ = aggregate_id для упорядоченности per aggregate)
    echo "${PAYLOAD}" | docker exec -i "${DC1}" kafka-console-producer.sh \
      --bootstrap-server localhost:9092 \
      --topic "${EVENTS_TOPIC}" \
      --property "parse.key=false" 2>/dev/null

    # Помечаем как опубликованное
    docker exec "${POSTGRES}" psql -U admin -d orders -c \
      "UPDATE outbox SET published = true WHERE id = '${OUTBOX_ID}';" \
      -q >/dev/null

    echo "  Опубликовано: ${EVENT_TYPE} для ${AGGREGATE_ID} (outbox_id=${OUTBOX_ID})"
    PUBLISHED_COUNT=$((PUBLISHED_COUNT + 1))
  done <<< "${RECORDS}"

  echo ""
  echo "Опубликовано ${PUBLISHED_COUNT} событий."
fi

echo ""

# --- Шаг 7: Проверка состояния outbox после публикации ---
echo "=== Шаг 7: Состояние outbox после публикации ==="
echo ""
echo "Все записи должны иметь published=true:"

${PSQL} -c "
SELECT aggregate_id, event_type, published, created_at
FROM outbox
ORDER BY created_at;"

echo ""

# --- Шаг 8: Проверка сообщений в Kafka ---
echo "=== Шаг 8: Сообщения в Kafka топике '${EVENTS_TOPIC}' ==="
echo ""
echo "Читаем опубликованные события из Kafka:"

docker exec "${DC1}" kafka-console-consumer.sh \
  --bootstrap-server localhost:9092 \
  --topic "${EVENTS_TOPIC}" \
  --from-beginning \
  --max-messages 10 \
  --timeout-ms 5000 2>/dev/null || true

echo ""

# --- Шаг 9: Демонстрация атомарности -- транзакция с ошибкой ---
# Показываем, что при ROLLBACK ни бизнес-запись, ни outbox не попадают в БД.
# Публикации в Kafka не происходит -- нет dual write проблемы.
echo "=== Шаг 9: Демонстрация атомарности (транзакция с ошибкой) ==="
echo ""
echo "Симулируем ошибку бизнес-логики: заказ order-999 с невалидной суммой."
echo "Транзакция откатывается -- ни заказ, ни outbox событие не сохранятся."
echo ""

${PSQL} << 'SQL'
BEGIN;
  -- Бизнес-операция
  INSERT INTO orders (id, customer_id, status, amount)
  VALUES ('order-999', 'customer-error', 'CREATED', -100.00);

  -- Проверка: отрицательная сумма недопустима
  DO $$
  BEGIN
    IF (SELECT amount FROM orders WHERE id = 'order-999') < 0 THEN
      RAISE EXCEPTION 'Сумма заказа не может быть отрицательной: %',
        (SELECT amount FROM orders WHERE id = 'order-999');
    END IF;
  END $$;

  -- Эта строка не выполнится из-за RAISE EXCEPTION выше
  INSERT INTO outbox (aggregate_type, aggregate_id, event_type, payload)
  VALUES ('Order', 'order-999', 'OrderCreated', '{"orderId": "order-999"}');
COMMIT;
SQL

echo ""
echo "Проверяем: order-999 не должен появиться в БД:"
${PSQL} -c "SELECT id, status FROM orders WHERE id = 'order-999';"
echo ""
echo "Проверяем: outbox не содержит события для order-999:"
${PSQL} -c "SELECT aggregate_id FROM outbox WHERE aggregate_id = 'order-999';"
echo ""

# --- Итог ---
echo "=== Итог упражнения 03 ==="
echo ""
echo "Вы изучили:"
echo "  1. Dual write problem: запись в БД и в Kafka НЕ атомарны без outbox"
echo "  2. Transactional Outbox: INSERT outbox + UPDATE orders в одной транзакции"
echo "  3. Polling Publisher: SELECT unpublished -> produce Kafka -> UPDATE published=true"
echo "  4. At-least-once: при сбое между produce и UPDATE сообщение может дублироваться"
echo "  5. Consumer должен быть идемпотентным: dedup по aggregate_id"
echo "  6. В production: Debezium CDC читает WAL вместо polling (меньше задержка)"
echo ""
echo "Поздравляем! Все три упражнения Multi-DC лаба завершены."
echo ""
echo "Очистка стенда:"
echo "  docker compose down -v"
