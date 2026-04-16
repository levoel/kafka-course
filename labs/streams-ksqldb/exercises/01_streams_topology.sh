#!/usr/bin/env bash
# Упражнение 01: Streams topology через ksqlDB
#
# Цель: изучить, как ksqlDB строит Kafka Streams топологии при создании
# потоков и persistent queries. Визуально увидеть Source/Processor/Sink узлы.
#
# Что вы сделаете:
#   - Создадите STREAM из Kafka-топика orders
#   - Создадите фильтрованный STREAM через CSAS (persistent query)
#   - Исследуете топологию через EXPLAIN
#   - Убедитесь, что выходной топик создан автоматически
#   - Завершите persistent query через TERMINATE
#
# Запуск: bash exercises/01_streams_topology.sh
# Требования: docker compose up -d, seed-data.sh выполнен
#
# Ожидаемый результат:
#   EXPLAIN покажет граф топологии: Source -> Filter -> Sink
#   Выходной топик HIGH_VALUE_ORDERS виден в Kafka

set -euo pipefail

KAFKA_CONTAINER="kafka-streams-lab"

echo "=== Упражнение 01: Streams topology через ksqlDB ==="
echo ""
echo "Это упражнение выполняется интерактивно в ksqlDB CLI."
echo "Скрипт показывает команды, объясняет каждый шаг и"
echo "запускает вспомогательные проверки через Docker."
echo ""

# --- Шаг 1: Подключение к ksqlDB CLI ---
# ksqlDB CLI — интерактивный SQL-клиент. Подключается к ksqlDB-серверу
# по адресу http://ksqldb-server:8088 (имя сервиса из docker-compose.yml)
echo "=== Шаг 1: Подключение к ksqlDB CLI ==="
echo ""
echo "Откройте новый терминал и выполните:"
echo ""
echo "  docker compose exec ksqldb-cli ksql http://ksqldb-server:8088"
echo ""
echo "Вы увидите приглашение ksql>"
echo "Нажмите Enter для продолжения..."
read -r

# --- Шаг 2: Создание STREAM из топика orders ---
# CREATE STREAM регистрирует существующий Kafka-топик 'orders' в ksqlDB
# как поток событий (KStream-семантика).
# Параметры WITH():
#   kafka_topic — имя существующего Kafka-топика
#   value_format — формат сериализации значений (JSON без Schema Registry)
echo "=== Шаг 2: Создание STREAM из топика orders ==="
echo ""
echo "В ksqlDB CLI выполните:"
echo ""
cat << 'STEP2_EOF'
CREATE STREAM orders_stream (
  order_id VARCHAR KEY,
  customer_id VARCHAR,
  amount DOUBLE,
  product VARCHAR,
  ts BIGINT
) WITH (
  kafka_topic = 'orders',
  value_format = 'JSON'
);
STEP2_EOF
echo ""
echo "Ожидаемый результат: 'Stream created'"
echo ""
echo "EXPLAIN:"
echo "  CREATE STREAM регистрирует топик 'orders' как STREAM в ksqlDB."
echo "  Новый Kafka-топик НЕ создаётся — используется существующий."
echo "  Это прямой аналог builder.stream(\"orders\") в Kafka Streams Java DSL."
echo ""
echo "Нажмите Enter для продолжения..."
read -r

# --- Шаг 3: Создание фильтрованного STREAM через CSAS ---
# CSAS (CREATE STREAM AS SELECT) создаёт persistent query:
# - Читает из orders_stream непрерывно
# - Фильтрует заказы с amount > 100
# - Пишет результат в новый Kafka-топик HIGH_VALUE_ORDERS (создаётся автоматически)
# Под капотом: Kafka Streams топология Source(orders) -> Filter(amount>100) -> Sink(HIGH_VALUE_ORDERS)
echo "=== Шаг 3: Создание фильтрованного STREAM через CSAS ==="
echo ""
echo "В ksqlDB CLI выполните:"
echo ""
cat << 'STEP3_EOF'
CREATE STREAM high_value_orders AS
  SELECT
    order_id,
    customer_id,
    amount,
    product
  FROM orders_stream
  WHERE amount > 100
  EMIT CHANGES;
STEP3_EOF
echo ""
echo "Ожидаемый результат: 'Stream created'"
echo ""
echo "EXPLAIN:"
echo "  CSAS создаёт persistent query — он работает непрерывно независимо"
echo "  от вашего подключения. Kafka-топик HIGH_VALUE_ORDERS создан автоматически."
echo "  Это эквивалент stream.filter(amount > 100).to(\"high-value-orders\") в Java."
echo ""
echo "Нажмите Enter для продолжения..."
read -r

# --- Шаг 4: Просмотр активных queries ---
# SHOW QUERIES показывает все persistent queries (CSAS/CTAS).
# Каждый query имеет уникальный ID (например, CSAS_HIGH_VALUE_ORDERS_0).
# Запомните query ID — он понадобится для EXPLAIN и TERMINATE.
echo "=== Шаг 4: Просмотр активных persistent queries ==="
echo ""
echo "В ksqlDB CLI выполните:"
echo ""
echo "  SHOW QUERIES;"
echo ""
echo "Ожидаемый вывод:"
echo "  Query ID                     | Status  | Sink Name         | Sink Kafka Topic"
echo "  CSAS_HIGH_VALUE_ORDERS_0     | RUNNING | HIGH_VALUE_ORDERS | HIGH_VALUE_ORDERS"
echo ""
echo "Запомните точный Query ID (он может отличаться — например, CSAS_HIGH_VALUE_ORDERS_1)."
echo ""
echo "Нажмите Enter для продолжения..."
read -r

# --- Шаг 5: Исследование топологии через EXPLAIN ---
# EXPLAIN <query_id> возвращает описание Kafka Streams топологии:
# - Source processors (читают из Kafka-топиков)
# - Stream processors (фильтрация, трансформация)
# - Sink processors (пишут в Kafka-топики)
# Это текстовый аналог topology.describe() в Kafka Streams Java.
echo "=== Шаг 5: Исследование топологии через EXPLAIN ==="
echo ""
echo "В ksqlDB CLI выполните (замените ID на ваш из SHOW QUERIES):"
echo ""
echo "  EXPLAIN CSAS_HIGH_VALUE_ORDERS_0;"
echo ""
echo "Ожидаемый вывод содержит описание топологии:"
echo ""
echo "  Sub-topologies:"
echo "  Sub-topology: 0"
echo "    Source: KSTREAM-SOURCE-0000000000 (topics: [orders])"
echo "      --> KSTREAM-FILTER-0000000001"
echo "    Processor: KSTREAM-FILTER-0000000001 (stores: [])"
echo "      --> KSTREAM-SINK-0000000002"
echo "      <-- KSTREAM-SOURCE-0000000000"
echo "    Sink: KSTREAM-SINK-0000000002 (topic: HIGH_VALUE_ORDERS)"
echo "      <-- KSTREAM-FILTER-0000000001"
echo ""
echo "EXPLAIN показывает три узла:"
echo "  - Source: читает из топика 'orders'"
echo "  - Filter: применяет WHERE amount > 100"
echo "  - Sink: пишет в топик 'HIGH_VALUE_ORDERS'"
echo ""
echo "Это Kafka Streams DAG (directed acyclic graph) — та же концепция из Модуля 07."
echo ""
echo "Нажмите Enter для продолжения..."
read -r

# --- Шаг 6: Проверка выходного топика ---
# Убеждаемся, что ksqlDB автоматически создал топик HIGH_VALUE_ORDERS
# и данные туда записываются (заказы с amount > 100).
echo "=== Шаг 6: Проверка выходного топика HIGH_VALUE_ORDERS ==="
echo ""
echo "Проверяем наличие топика через Kafka CLI (автоматически)..."
sleep 2

TOPICS=$(docker compose exec "${KAFKA_CONTAINER}" \
    kafka-topics \
    --bootstrap-server localhost:9092 \
    --list 2>/dev/null | grep -i "HIGH_VALUE_ORDERS" || echo "")

if [ -n "$TOPICS" ]; then
    echo "  Топик HIGH_VALUE_ORDERS СУЩЕСТВУЕТ в Kafka."
    echo ""
    echo "  Читаем сообщения из выходного топика (5 секунд):"
    docker compose exec "${KAFKA_CONTAINER}" \
        kafka-console-consumer \
        --bootstrap-server localhost:9092 \
        --topic HIGH_VALUE_ORDERS \
        --from-beginning \
        --timeout-ms 5000 2>/dev/null || true
else
    echo "  Топик ещё не создан — выполните CSAS в ksqlDB CLI (Шаг 3) и повторите."
fi
echo ""

# --- Шаг 7: Push query для наблюдения в реальном времени ---
# SELECT ... EMIT CHANGES — transient push query.
# Новые события из HIGH_VALUE_ORDERS появляются сразу.
# Нажмите Ctrl+C для остановки push query.
echo "=== Шаг 7: Push query — наблюдение фильтрованных заказов ==="
echo ""
echo "В ksqlDB CLI выполните push query для наблюдения всех событий:"
echo ""
echo "  SELECT * FROM high_value_orders EMIT CHANGES LIMIT 10;"
echo ""
echo "Ожидаемый вывод: заказы с amount > 100 (250.50, 1500.00, 320.00, и т.д.)"
echo ""
echo "LIMIT 10 останавливает query после 10 записей. Без LIMIT — query открыт бессрочно."
echo ""
echo "Нажмите Enter для продолжения..."
read -r

# --- Шаг 8: Завершение persistent query ---
# TERMINATE останавливает persistent query — запись в выходной топик прекращается.
# Топик HIGH_VALUE_ORDERS остаётся в Kafka с уже записанными данными.
echo "=== Шаг 8: Завершение persistent query ==="
echo ""
echo "В ksqlDB CLI выполните (замените ID на ваш):"
echo ""
echo "  TERMINATE CSAS_HIGH_VALUE_ORDERS_0;"
echo ""
echo "Ожидаемый результат: 'Query terminated.'"
echo ""
echo "Проверьте, что query больше не активен:"
echo ""
echo "  SHOW QUERIES;"
echo ""
echo "Список должен быть пуст или не содержать CSAS_HIGH_VALUE_ORDERS."
echo ""
echo "Для удаления STREAM и топика:"
echo ""
echo "  DROP STREAM IF EXISTS high_value_orders DELETE TOPIC;"
echo "  DROP STREAM IF EXISTS orders_stream;"
echo ""

echo "=== Итог упражнения 01 ==="
echo ""
echo "Вы изучили:"
echo "  1. CREATE STREAM регистрирует Kafka-топик как STREAM (KStream-семантика)"
echo "  2. CSAS создаёт persistent query = Kafka Streams топология"
echo "  3. EXPLAIN показывает граф топологии: Source -> Filter -> Sink"
echo "  4. Выходной топик создаётся ksqlDB автоматически при CSAS"
echo "  5. TERMINATE останавливает persistent query"
echo ""
echo "Следующее упражнение: 02_ksqldb_queries.sh (CSAS/CTAS + push/pull)"
