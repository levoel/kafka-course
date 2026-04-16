#!/usr/bin/env bash
# Упражнение 02: CSAS/CTAS, Push/Pull запросы
#
# Цель: освоить основные паттерны ksqlDB:
#   - KStream-KTable join через CSAS (обогащение заказов данными клиентов)
#   - CTAS для создания материализованных агрегаций
#   - Push query для наблюдения в реальном времени
#   - Pull query для точечного lookup по ключу
#
# Что вы сделаете:
#   - Создадите TABLE из топика users (KTable-семантика)
#   - Создадите CSAS с LEFT JOIN orders + users (enrichment)
#   - Наблюдение через push query (EMIT CHANGES)
#   - Создадите CTAS с агрегацией ORDER totals по customer_id
#   - Pull query для получения итогов конкретного клиента
#   - Просмотр всех persistent queries и топологий
#
# Запуск: bash exercises/02_ksqldb_queries.sh
# Требования: docker compose up -d, seed-data.sh выполнен

set -euo pipefail

KAFKA_CONTAINER="kafka-streams-lab"

echo "=== Упражнение 02: CSAS/CTAS, Push/Pull запросы ==="
echo ""
echo "Убедитесь, что у вас открыт ksqlDB CLI в отдельном терминале:"
echo "  docker compose exec ksqldb-cli ksql http://ksqldb-server:8088"
echo ""
echo "Нажмите Enter для начала..."
read -r

# --- Шаг 1: Создание STREAM из топика orders ---
# Если STREAM из упражнения 01 был удалён, создаём заново.
# orders_stream — основной источник событий заказов.
echo "=== Шаг 1: Создание STREAM из топика orders ==="
echo ""
echo "В ksqlDB CLI выполните:"
echo ""
cat << 'STEP1_EOF'
CREATE STREAM IF NOT EXISTS orders_stream (
  order_id VARCHAR KEY,
  customer_id VARCHAR,
  amount DOUBLE,
  product VARCHAR,
  ts BIGINT
) WITH (
  kafka_topic = 'orders',
  value_format = 'JSON'
);
STEP1_EOF
echo ""
echo "Нажмите Enter для продолжения..."
read -r

# --- Шаг 2: Создание TABLE из топика users ---
# CREATE TABLE регистрирует топик 'users' как TABLE (KTable-семантика).
# PRIMARY KEY обязателен для TABLE — ksqlDB хранит актуальное состояние по ключу.
# Новое сообщение с тем же user_id ПЕРЕЗАПИСЫВАЕТ предыдущее (UPSERT).
# Это прямой аналог builder.table("users") в Kafka Streams Java.
echo "=== Шаг 2: Создание TABLE из топика users ==="
echo ""
echo "В ksqlDB CLI выполните:"
echo ""
cat << 'STEP2_EOF'
CREATE TABLE users_table (
  user_id VARCHAR PRIMARY KEY,
  name VARCHAR,
  email VARCHAR,
  city VARCHAR
) WITH (
  kafka_topic = 'users',
  value_format = 'JSON'
);
STEP2_EOF
echo ""
echo "Ожидаемый результат: 'Table created'"
echo ""
echo "EXPLAIN:"
echo "  TABLE user_id = PRIMARY KEY означает KTable."
echo "  Если придёт обновление для user_id='customer_1' — старое значение заменится."
echo "  Это прямой аналог KTable в Kafka Streams из Модуля 07."
echo ""
echo "Проверьте состояние TABLE (pull query к материализованной таблице):"
echo ""
echo "  SELECT * FROM users_table WHERE user_id = 'customer_1';"
echo ""
echo "Ожидаемый вывод: {\"CUSTOMER_1\", \"Иван Петров\", ...}"
echo ""
echo "Нажмите Enter для продолжения..."
read -r

# --- Шаг 3: Создание обогащённого STREAM через CSAS с JOIN ---
# CSAS создаёт persistent query, который:
#   - Читает каждый новый заказ из orders_stream
#   - Делает LEFT JOIN с users_table по customer_id
#   - Добавляет имя и город клиента к заказу
#   - Пишет обогащённые записи в новый топик ENRICHED_ORDERS
# Это KStream-KTable join — классический паттерн обогащения событий.
echo "=== Шаг 3: CSAS с LEFT JOIN — обогащение заказов данными клиентов ==="
echo ""
echo "В ksqlDB CLI выполните:"
echo ""
cat << 'STEP3_EOF'
CREATE STREAM enriched_orders AS
  SELECT
    o.order_id,
    o.amount,
    o.product,
    o.customer_id,
    u.name AS customer_name,
    u.city AS customer_city
  FROM orders_stream o
  LEFT JOIN users_table u ON o.customer_id = u.user_id
  EMIT CHANGES;
STEP3_EOF
echo ""
echo "Ожидаемый результат: 'Stream created'"
echo ""
echo "EXPLAIN:"
echo "  LEFT JOIN orders_stream + users_table = KStream-KTable join."
echo "  Каждое событие из orders обогащается ТЕКУЩИМ значением из users_table."
echo "  Если пользователь не найден — customer_name/city = NULL (LEFT JOIN)."
echo "  Выходной топик ENRICHED_ORDERS создаётся автоматически."
echo ""
echo "Нажмите Enter для продолжения..."
read -r

# --- Шаг 4: Push query — наблюдение обогащённых заказов ---
# Push query с EMIT CHANGES подписывается на поток обогащённых событий.
# Соединение остаётся открытым. LIMIT 5 останавливает после 5 записей.
# В production push queries используются для дашбордов и real-time мониторинга.
echo "=== Шаг 4: Push query — наблюдение обогащённых заказов ==="
echo ""
echo "В ksqlDB CLI выполните:"
echo ""
echo "  SELECT order_id, amount, product, customer_name, customer_city"
echo "  FROM enriched_orders EMIT CHANGES LIMIT 5;"
echo ""
echo "Ожидаемый вывод (5 записей с именами клиентов):"
echo "  order_001 | 250.50 | Ноутбук        | Иван Петров      | Москва"
echo "  order_002 | 89.99  | Мышь           | Мария Сидорова   | Санкт-Петербург"
echo "  ..."
echo ""
echo "Нажмите Enter для продолжения..."
read -r

# --- Шаг 5: CTAS — материализация агрегации по клиентам ---
# CTAS создаёт persistent query, который:
#   - Читает из orders_stream непрерывно
#   - Группирует по customer_id (GROUP BY)
#   - Считает COUNT и SUM(amount)
#   - Материализует результат как TABLE в state store (RocksDB)
# Это KTable с агрегацией — прямой аналог groupByKey().aggregate() в Java DSL.
echo "=== Шаг 5: CTAS — материализация агрегации заказов по клиентам ==="
echo ""
echo "В ksqlDB CLI выполните:"
echo ""
cat << 'STEP5_EOF'
CREATE TABLE order_totals AS
  SELECT
    customer_id,
    COUNT(*) AS order_count,
    SUM(amount) AS total_amount
  FROM orders_stream
  GROUP BY customer_id
  EMIT CHANGES;
STEP5_EOF
echo ""
echo "Ожидаемый результат: 'Table created'"
echo ""
echo "EXPLAIN:"
echo "  CTAS создаёт state store (RocksDB) на диске ksqlDB-сервера."
echo "  По мере поступления заказов order_count и total_amount обновляются."
echo "  TABLE order_totals доступна для pull queries (точечный lookup)."
echo ""
echo "Нажмите Enter для продолжения..."
read -r

# --- Шаг 6: Pull query — точечный lookup по customer_id ---
# Pull query (без EMIT CHANGES) — это one-shot запрос к state store.
# Возвращает ТЕКУЩЕЕ значение для указанного ключа и закрывает соединение.
# Только для материализованных TABLE (CTAS). Аналог database SELECT.
echo "=== Шаг 6: Pull query — точечный lookup по customer_id ==="
echo ""
echo "В ksqlDB CLI выполните pull queries для разных клиентов:"
echo ""
echo "  SELECT * FROM order_totals WHERE customer_id = 'customer_1';"
echo ""
echo "Ожидаемый вывод:"
echo "  customer_id  | order_count | total_amount"
echo "  customer_1   | 4           | 5325.50"
echo ""
echo "  SELECT * FROM order_totals WHERE customer_id = 'customer_2';"
echo ""
echo "EXPLAIN:"
echo "  Pull query идёт напрямую в RocksDB state store — O(1) lookup по ключу."
echo "  Нет сканирования топика. Мгновенный ответ. Соединение закрывается сразу."
echo "  Используйте для REST API backend, сервисного слоя, ответов на запросы пользователей."
echo ""
echo "Нажмите Enter для продолжения..."
read -r

# --- Шаг 7: Просмотр всех persistent queries ---
# SHOW QUERIES — список всех активных persistent queries.
# EXPLAIN показывает топологию каждого query.
echo "=== Шаг 7: Просмотр всех persistent queries ==="
echo ""
echo "В ksqlDB CLI выполните:"
echo ""
echo "  SHOW QUERIES;"
echo ""
echo "Должны быть видны как минимум два query:"
echo "  CSAS_ENRICHED_ORDERS_x    — join + enrichment"
echo "  CTAS_ORDER_TOTALS_x       — агрегация"
echo ""
echo "Для детального описания топологии CTAS:"
echo ""
echo "  EXPLAIN CTAS_ORDER_TOTALS_0;"
echo ""
echo "В топологии будет виден: Source -> GroupBy -> Aggregate -> Sink"
echo "(прямой аналог groupByKey().aggregate() в Kafka Streams Java DSL)"
echo ""
echo "Нажмите Enter для продолжения..."
read -r

# --- Шаг 8: Добавление нового заказа и наблюдение обновления ---
# Демонстрируем real-time обработку: новый заказ появляется в enriched_orders
# и обновляет агрегат в order_totals.
echo "=== Шаг 8: Добавление нового заказа и наблюдение обновлений ==="
echo ""
echo "Добавляем новый заказ для customer_1..."
docker compose exec "${KAFKA_CONTAINER}" \
    bash -c "echo 'order_016:{\"order_id\":\"order_016\",\"customer_id\":\"customer_1\",\"amount\":999.00,\"product\":\"Смартфон\",\"ts\":1705323600000}' | kafka-console-producer \
    --bootstrap-server localhost:9092 \
    --topic orders \
    --property parse.key=true \
    --property key.separator=:"
echo "  Заказ order_016 (999.00, customer_1) добавлен"
echo ""
sleep 3

echo "Проверьте обновление агрегата (pull query):"
echo ""
echo "  SELECT * FROM order_totals WHERE customer_id = 'customer_1';"
echo ""
echo "Ожидаемый вывод: order_count = 5, total_amount = 6324.50 (увеличился на 999.00)"
echo ""
echo "Это real-time обновление materialized view — один из ключевых паттернов ksqlDB."
echo ""
echo "Нажмите Enter для продолжения..."
read -r

# --- Шаг 9: Очистка ---
echo "=== Шаг 9: Очистка (опционально) ==="
echo ""
echo "В ksqlDB CLI выполните для очистки всех объектов:"
echo ""
echo "  -- Остановить все persistent queries"
echo "  TERMINATE CSAS_ENRICHED_ORDERS_0;"
echo "  TERMINATE CTAS_ORDER_TOTALS_0;"
echo ""
echo "  -- Удалить STREAM и TABLE (+ топики)"
echo "  DROP STREAM IF EXISTS enriched_orders DELETE TOPIC;"
echo "  DROP TABLE IF EXISTS order_totals DELETE TOPIC;"
echo "  DROP TABLE IF EXISTS users_table;"
echo "  DROP STREAM IF EXISTS orders_stream;"
echo ""

echo "=== Итог упражнения 02 ==="
echo ""
echo "Вы освоили:"
echo "  1. CREATE TABLE с PRIMARY KEY = KTable (UPSERT-семантика)"
echo "  2. CSAS с LEFT JOIN = KStream-KTable join в SQL"
echo "  3. Push query (EMIT CHANGES) = непрерывная подписка на поток"
echo "  4. CTAS с GROUP BY = материализованная агрегация с state store"
echo "  5. Pull query (без EMIT CHANGES) = точечный O(1) lookup в RocksDB"
echo "  6. Real-time обновление materialized view при появлении новых событий"
echo ""
echo "Следующее упражнение: 03_windowed_aggregation.sh (Windowed aggregations)"
