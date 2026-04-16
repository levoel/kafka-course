#!/usr/bin/env bash
# Упражнение 03: Цепочка SMT (Single Message Transforms)
#
# Демонстрирует применение нескольких трансформаций к сообщению в одном коннекторе:
#   1. InsertField$Value — добавить поле processed_at с текущим timestamp
#   2. ReplaceField$Value — исключить лишнее поле из сообщения
#   3. RegexRouter — изменить имя целевого топика по шаблону
#
# SMT применяются последовательно в порядке, указанном в поле "transforms".
# Каждая трансформация получает на вход результат предыдущей.
#
# Запуск: bash exercises/03_smt_chaining.sh
#
# Требования:
#   - docker compose up -d (все сервисы должны быть в статусе healthy)
#   - curl (для REST API запросов)
#
# Ожидаемый результат:
#   Коннектор с цепочкой из трёх SMT создан и запущен.
#   Каждое сообщение проходит три трансформации перед записью в Kafka.

set -euo pipefail

KAFKA_CONTAINER="kafka-connect-lab"
CONNECT_CONTAINER="kafka-connect-lab-worker"
CONNECT_URL="http://localhost:8083"

echo "=== Упражнение 03: Цепочка SMT ==="
echo ""

# --- Шаг 1: Создание тестового файла ---
# Файл содержит строки в формате CSV (имитация источника данных).
# FileStreamSourceConnector будет читать эти строки построчно.
echo "Шаг 1: Создание тестового файла с CSV-данными..."
docker compose exec "${CONNECT_CONTAINER}" \
    bash -c "printf 'order_001,книга,1500\norder_002,курс,3000\norder_003,подписка,500\n' > /tmp/test-data/smt_input.txt"
echo "  Файл создан. Содержимое:"
docker compose exec "${CONNECT_CONTAINER}" cat /tmp/test-data/smt_input.txt
echo ""

# --- Шаг 2: Создание коннектора с цепочкой SMT ---
# Поле "transforms" содержит список трансформаций через запятую.
# Порядок применения: слева направо.
#
# Цепочка: addTimestamp -> routeToArchive
#
# addTimestamp (InsertField$Value):
#   Добавляет поле processed_at к каждому сообщению.
#   Тип "timestamp" означает: взять время обработки сообщения Connect worker'ом.
#
# routeToArchive (RegexRouter):
#   Изменяет имя целевого топика по regex-шаблону.
#   Шаблон "(.*)" заменяется на "$1-archive" — к имени топика добавляется суффикс.
#   Результат: исходный топик "smt-events" -> "smt-events-archive".
echo "Шаг 2: Создание коннектора с цепочкой SMT (InsertField + RegexRouter)..."
curl -s -X POST "${CONNECT_URL}/connectors" \
    -H "Content-Type: application/json" \
    -d '{
  "name": "smt-chain-demo",
  "config": {
    "connector.class": "org.apache.kafka.connect.file.FileStreamSourceConnector",
    "tasks.max": "1",
    "file": "/tmp/test-data/smt_input.txt",
    "topic": "smt-events",
    "transforms": "addTimestamp,routeToArchive",
    "transforms.addTimestamp.type": "org.apache.kafka.connect.transforms.InsertField$Value",
    "transforms.addTimestamp.timestamp.field": "processed_at",
    "transforms.routeToArchive.type": "org.apache.kafka.connect.transforms.RegexRouter",
    "transforms.routeToArchive.regex": "(.*)",
    "transforms.routeToArchive.replacement": "$1-archive"
  }
}' | python3 -m json.tool
echo ""

sleep 5

# --- Шаг 3: Проверка статуса коннектора ---
# Убеждаемся, что коннектор и его задача находятся в статусе RUNNING.
# Если статус FAILED, смотрим поле tasks[0].trace для диагностики.
echo "Шаг 3: Статус коннектора smt-chain-demo:"
curl -s "${CONNECT_URL}/connectors/smt-chain-demo/status" | python3 -m json.tool
echo ""

# --- Шаг 4: Просмотр применённых трансформаций ---
# GET /connectors/{name} возвращает конфигурацию, включая все SMT.
# Обратите внимание на порядок в поле "transforms".
echo "Шаг 4: Конфигурация коннектора (включая цепочку SMT):"
curl -s "${CONNECT_URL}/connectors/smt-chain-demo" | python3 -m json.tool
echo ""

# --- Шаг 5: Чтение из целевого топика ---
# RegexRouter изменил имя топика: "smt-events" -> "smt-events-archive".
# Сообщения должны находиться в топике smt-events-archive, а не smt-events.
echo "Шаг 5: Чтение сообщений из топика smt-events-archive (после RegexRouter):"
docker compose exec "${KAFKA_CONTAINER}" \
    kafka-console-consumer.sh \
    --bootstrap-server localhost:9092 \
    --topic smt-events-archive \
    --from-beginning \
    --timeout-ms 5000 || true
echo ""
echo "  Ожидаемый результат: строки из файла (InsertField добавил processed_at,"
echo "  RegexRouter перенаправил в smt-events-archive)"
echo ""

# --- Шаг 6: Проверка, что исходный топик пуст ---
# Поскольку RegexRouter изменил маршрут, топик smt-events не должен содержать сообщений.
echo "Шаг 6: Проверка исходного топика smt-events (должен быть пуст):"
docker compose exec "${KAFKA_CONTAINER}" \
    kafka-console-consumer.sh \
    --bootstrap-server localhost:9092 \
    --topic smt-events \
    --from-beginning \
    --timeout-ms 3000 || true
echo "  (пустой результат или ошибка timeout — ожидаемо)"
echo ""

# --- Шаг 7: Создание коннектора с тремя SMT ---
# Расширенный пример с тремя трансформациями:
#   1. InsertField$Value — добавить поле processed_at
#   2. ValueToKey — использовать поля value как key сообщения (заменить null-ключ)
#   3. ExtractField$Key — извлечь одно поле из struct-ключа
#
# Примечание: ValueToKey и ExtractField работают корректно только со structured data.
# С FileStreamSource (строки в value) демонстрируем синтаксис конфигурации.
echo "Шаг 7: Пример конфигурации трёх SMT (синтаксис):"
cat << 'EXAMPLE_CONFIG'
{
  "name": "triple-smt-example",
  "config": {
    "connector.class": "...",
    "transforms": "addTimestamp,maskField,regexRoute",

    "transforms.addTimestamp.type":
      "org.apache.kafka.connect.transforms.InsertField$Value",
    "transforms.addTimestamp.timestamp.field": "processed_at",

    "transforms.maskField.type":
      "org.apache.kafka.connect.transforms.MaskField$Value",
    "transforms.maskField.fields": "password,credit_card",

    "transforms.regexRoute.type":
      "org.apache.kafka.connect.transforms.RegexRouter",
    "transforms.regexRoute.regex": "(.*)raw(.*)",
    "transforms.regexRoute.replacement": "$1processed$2"
  }
}
EXAMPLE_CONFIG
echo ""
echo "  Трансформации применяются по порядку: addTimestamp -> maskField -> regexRoute"
echo "  Каждая SMT получает на вход выход предыдущей."
echo ""

# --- Шаг 8: Удаление коннектора ---
echo "Шаг 8: Удаление коннектора smt-chain-demo..."
curl -s -X DELETE "${CONNECT_URL}/connectors/smt-chain-demo"
echo "  Коннектор удалён."
echo ""

echo "=== Итог ==="
echo "SMT (Single Message Transforms) применяются к каждому сообщению в порядке,"
echo "указанном в поле 'transforms' конфигурации коннектора."
echo ""
echo "Встроенные SMT (пакет org.apache.kafka.connect.transforms):"
echo "  InsertField  — добавить поле (статическое значение, метаданные или timestamp)"
echo "  ReplaceField — включить/исключить/переименовать поля"
echo "  MaskField    — обнулить значения полей (для маскирования PII)"
echo "  ValueToKey   — использовать поля value как key"
echo "  RegexRouter  — изменить имя целевого топика по regex-шаблону"
echo "  TimestampRouter — маршрутизация по временной метке (например, orders-20260416)"
echo "  Flatten      — распрямить вложенные структуры в плоский формат"
echo "  Cast         — преобразовать тип поля (int -> string и т.д.)"
