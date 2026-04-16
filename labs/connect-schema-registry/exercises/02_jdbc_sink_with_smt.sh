#!/usr/bin/env bash
# Упражнение 02: JDBC Sink коннектор с SMT InsertField
#
# Демонстрирует:
#   - Продюсирование тестовых записей в топик
#   - Развёртывание JdbcSinkConnector с трансформацией InsertField$Value
#   - Проверку, что SMT добавил поле processed_at к каждой записи
#   - Просмотр данных в SQLite через sqlite3
#
# Важно: JdbcSinkConnector и SQLite JDBC Driver должны быть установлены.
# В образе confluentinc/cp-kafka-connect:7.9.0 JDBC коннектор может отсутствовать.
# Установка через Confluent Hub:
#   docker compose exec connect confluent-hub install confluentinc/kafka-connect-jdbc:latest
#
# Запуск: bash exercises/02_jdbc_sink_with_smt.sh
#
# Ожидаемый результат:
#   Записи в таблице file-events базы данных SQLite с добавленным полем processed_at.

set -euo pipefail

KAFKA_CONTAINER="kafka-connect-lab"
CONNECT_URL="http://localhost:8083"

echo "=== Упражнение 02: JDBC Sink с SMT InsertField ==="
echo ""

# --- Шаг 1: Продюсирование тестовых записей в топик ---
# Создаём топик и записываем несколько JSON-сообщений.
# JDBC Sink будет читать из этого топика и записывать в SQLite.
echo "Шаг 1: Создание топика file-events и продюсирование тестовых записей..."
docker compose exec "${KAFKA_CONTAINER}" \
    kafka-topics.sh \
    --bootstrap-server localhost:9092 \
    --create \
    --topic file-events \
    --partitions 1 \
    --replication-factor 1 2>/dev/null || echo "  Топик уже существует."

# Продюсируем несколько JSON-записей
docker compose exec "${KAFKA_CONTAINER}" \
    bash -c "printf '%s\n' \
        '{\"id\":1,\"message\":\"первая запись\"}' \
        '{\"id\":2,\"message\":\"вторая запись\"}' \
        '{\"id\":3,\"message\":\"третья запись\"}' | \
        kafka-console-producer.sh \
        --bootstrap-server localhost:9092 \
        --topic file-events"
echo "  Записи продюсированы."
echo ""

# --- Шаг 2: Развёртывание JDBC Sink коннектора с SMT ---
# InsertField$Value добавляет поле processed_at к каждой записи.
# Тип "timestamp" означает: вставить время обработки сообщения (wallclock time).
#
# auto.create=true — JDBC Sink автоматически создаёт таблицу по схеме сообщений.
# pk.mode=kafka — первичный ключ формируется из топика, партиции и офсета Kafka.
echo "Шаг 2: Развёртывание JDBC Sink коннектора с InsertField SMT..."
echo ""
echo "  Примечание: JdbcSinkConnector требует установки через Confluent Hub."
echo "  Проверяем, доступен ли плагин..."
curl -s "${CONNECT_URL}/connector-plugins" | \
    python3 -c "
import json, sys
plugins = json.load(sys.stdin)
jdbc_plugins = [p for p in plugins if 'jdbc' in p['class'].lower() or 'Jdbc' in p['class']]
if jdbc_plugins:
    print('  JDBC плагин найден:')
    for p in jdbc_plugins:
        print(f'    {p[\"class\"]}')
else:
    print('  JDBC плагин не найден.')
    print('  Установка: docker compose exec connect confluent-hub install confluentinc/kafka-connect-jdbc:latest')
    print('  После установки: docker compose restart connect')
"
echo ""

echo "  Конфигурация коннектора (из файла connector-configs/jdbc-sink.json):"
cat connector-configs/jdbc-sink.json | python3 -m json.tool
echo ""

# Попытка создать коннектор
echo "  Создание коннектора..."
HTTP_STATUS=$(curl -s -o /tmp/connect_response.json -w "%{http_code}" \
    -X POST "${CONNECT_URL}/connectors" \
    -H "Content-Type: application/json" \
    -d @connector-configs/jdbc-sink.json)

if [ "${HTTP_STATUS}" = "201" ]; then
    echo "  Коннектор создан (HTTP 201):"
    cat /tmp/connect_response.json | python3 -m json.tool
elif [ "${HTTP_STATUS}" = "409" ]; then
    echo "  Коннектор уже существует (HTTP 409). Используем существующий."
else
    echo "  Статус HTTP: ${HTTP_STATUS}"
    echo "  Ответ:"
    cat /tmp/connect_response.json | python3 -m json.tool 2>/dev/null || cat /tmp/connect_response.json
    echo ""
    echo "  Если коннектор не удалось создать, установите JDBC плагин:"
    echo "    docker compose exec connect confluent-hub install confluentinc/kafka-connect-jdbc:latest"
    echo "    docker compose restart connect"
fi
echo ""

sleep 5

# --- Шаг 3: Проверка статуса коннектора ---
echo "Шаг 3: Статус коннектора jdbc-sink-demo:"
curl -s "${CONNECT_URL}/connectors/jdbc-sink-demo/status" 2>/dev/null | \
    python3 -m json.tool 2>/dev/null || echo "  Коннектор не запущен."
echo ""

# --- Шаг 4: Просмотр данных в SQLite ---
# sqlite3 должен быть установлен в контейнере connect.
# Поле processed_at добавлено трансформацией InsertField$Value.
echo "Шаг 4: Просмотр данных в SQLite (поле processed_at добавлено SMT):"
docker compose exec kafka-connect-lab-worker \
    bash -c "
        if command -v sqlite3 &>/dev/null && [ -f /tmp/test-data/output.db ]; then
            echo 'Таблицы в базе данных:'
            sqlite3 /tmp/test-data/output.db '.tables'
            echo ''
            echo 'Содержимое таблицы file-events:'
            sqlite3 /tmp/test-data/output.db 'SELECT * FROM \"file-events\";'
        elif [ -f /tmp/test-data/output.db ]; then
            echo 'sqlite3 не найден в контейнере.'
            echo 'База данных существует: /tmp/test-data/output.db'
            echo 'Для просмотра: docker compose exec connect sqlite3 /tmp/test-data/output.db'
        else
            echo 'База данных /tmp/test-data/output.db не найдена.'
            echo 'Убедитесь, что коннектор jdbc-sink-demo запущен и обработал записи.'
        fi
    " 2>/dev/null || echo "  Контейнер недоступен или SQLite не установлен."
echo ""

# --- Шаг 5: SMT в действии — объяснение трансформации ---
# InsertField$Value добавляет новое поле к структуре данных.
# Тип "timestamp" вставляет время обработки в миллисекундах.
echo "Шаг 5: Как работает InsertField SMT:"
cat << 'EXPLANATION'
  Без SMT (исходная запись из топика):
    { "id": 1, "message": "первая запись" }

  После InsertField$Value (timestamp.field=processed_at):
    { "id": 1, "message": "первая запись", "processed_at": 1776323163000 }

  Конфигурация в коннекторе:
    "transforms": "addTimestamp",
    "transforms.addTimestamp.type": "org.apache.kafka.connect.transforms.InsertField$Value",
    "transforms.addTimestamp.timestamp.field": "processed_at"

  Другие типы значений для InsertField:
    "offset.field": "_offset"     -> офсет Kafka-сообщения
    "partition.field": "_part"    -> номер партиции
    "topic.field": "_topic"       -> имя топика
    "static.field": "_env", "static.value": "production" -> статическое значение
EXPLANATION
echo ""

# --- Шаг 6: Удаление коннектора ---
echo "Шаг 6: Удаление коннектора jdbc-sink-demo..."
curl -s -X DELETE "${CONNECT_URL}/connectors/jdbc-sink-demo" 2>/dev/null || true
echo "  Выполнено."
echo ""

echo "=== Итог ==="
echo "JDBC Sink коннектор записывает данные из Kafka в реляционные базы данных."
echo "SMT InsertField$Value добавляет поле к каждому сообщению перед записью."
echo "auto.create=true позволяет коннектору автоматически создавать таблицы."
echo "Тип pk.mode=kafka использует топик+партицию+офсет как первичный ключ."
