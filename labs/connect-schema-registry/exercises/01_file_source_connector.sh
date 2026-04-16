#!/usr/bin/env bash
# Упражнение 01: FileSource коннектор
#
# Демонстрирует полный жизненный цикл Source коннектора:
#   - Создание тестового файла внутри контейнера Connect
#   - Развёртывание FileStreamSourceConnector через REST API
#   - Проверка статуса коннектора и задач
#   - Чтение сообщений из топика, созданных коннектором
#   - Добавление новых строк и наблюдение за их появлением в топике
#   - Удаление коннектора
#
# Запуск: bash exercises/01_file_source_connector.sh
#
# Требования:
#   - docker compose up -d (все сервисы должны быть в статусе healthy)
#   - curl (для REST API запросов)
#
# Ожидаемый результат:
#   Три строки из input.txt появляются как отдельные сообщения в топике file-events.
#   Новые строки, добавленные в файл, также появляются в топике.

set -euo pipefail

# Имена контейнеров совпадают с container_name в docker-compose.yml
KAFKA_CONTAINER="kafka-connect-lab"
CONNECT_CONTAINER="kafka-connect-lab-worker"
CONNECT_URL="http://localhost:8083"

echo "=== Упражнение 01: FileSource коннектор ==="
echo ""

# --- Шаг 1: Создание тестового файла ---
# FileStreamSourceConnector читает файл построчно.
# Каждая строка файла становится отдельным сообщением в топике.
# Файл /tmp/test-data монтируется из хостовой директории ./test-data
echo "Шаг 1: Создание тестового файла /tmp/test-data/input.txt..."
docker compose exec "${CONNECT_CONTAINER}" \
    bash -c "printf 'событие-1\nсобытие-2\nсобытие-3\n' > /tmp/test-data/input.txt"
echo "  Файл создан. Содержимое:"
docker compose exec "${CONNECT_CONTAINER}" cat /tmp/test-data/input.txt
echo ""

# --- Шаг 2: Развёртывание коннектора через REST API ---
# POST /connectors — создать новый коннектор.
# Конфигурация из файла connector-configs/file-source.json:
#   connector.class — класс FileStreamSourceConnector (встроен в Kafka Connect)
#   file — путь к файлу внутри контейнера Connect
#   topic — имя топика для записи сообщений
echo "Шаг 2: Развёртывание FileSource коннектора..."
curl -s -X POST "${CONNECT_URL}/connectors" \
    -H "Content-Type: application/json" \
    -d @connector-configs/file-source.json | python3 -m json.tool
echo ""

# Небольшая пауза для инициализации задачи коннектора
sleep 5

# --- Шаг 3: Проверка статуса коннектора ---
# GET /connectors/{name}/status — статус коннектора и его задач.
# Статусы задач: RUNNING, PAUSED, FAILED, UNASSIGNED.
# Поле tasks[0].state должно быть RUNNING для нормальной работы.
echo "Шаг 3: Статус коннектора file-source-demo:"
curl -s "${CONNECT_URL}/connectors/file-source-demo/status" | python3 -m json.tool
echo ""

# --- Шаг 4: Чтение сообщений из топика ---
# kafka-console-consumer.sh читает сообщения из топика file-events.
# --from-beginning — читать с начала, включая уже записанные сообщения.
# --timeout-ms 5000 — завершить чтение через 5 секунд без новых сообщений.
# Каждая строка файла стала отдельным сообщением (ключ не задан, value = строка).
echo "Шаг 4: Чтение сообщений из топика file-events:"
docker compose exec "${KAFKA_CONTAINER}" \
    kafka-console-consumer.sh \
    --bootstrap-server localhost:9092 \
    --topic file-events \
    --from-beginning \
    --timeout-ms 5000 || true
echo ""
echo "  Ожидаемый результат: три строки из файла (событие-1, событие-2, событие-3)"
echo ""

# --- Шаг 5: Добавление новых строк в файл ---
# FileStreamSourceConnector непрерывно следит за файлом (tail-like behaviour).
# Новые строки, добавленные после старта коннектора, будут прочитаны и отправлены в топик.
echo "Шаг 5: Добавление новой строки в файл..."
docker compose exec "${CONNECT_CONTAINER}" \
    bash -c "echo 'событие-4-новое' >> /tmp/test-data/input.txt"
echo "  Строка добавлена. Ожидание 3 секунды..."
sleep 3

echo "  Повторное чтение топика (должно появиться событие-4-новое):"
docker compose exec "${KAFKA_CONTAINER}" \
    kafka-console-consumer.sh \
    --bootstrap-server localhost:9092 \
    --topic file-events \
    --from-beginning \
    --timeout-ms 5000 || true
echo ""

# --- Шаг 6: Конфигурация коннектора ---
# GET /connectors/{name} — получить полную конфигурацию коннектора.
# Конфигурацию можно изменить через PUT /connectors/{name}/config.
echo "Шаг 6: Полная конфигурация коннектора:"
curl -s "${CONNECT_URL}/connectors/file-source-demo" | python3 -m json.tool
echo ""

# --- Шаг 7: Удаление коннектора ---
# DELETE /connectors/{name} — удалить коннектор и остановить все его задачи.
# Данные в топике остаются. Офсеты сохраняются в топике connect-offsets.
echo "Шаг 7: Удаление коннектора file-source-demo..."
curl -s -X DELETE "${CONNECT_URL}/connectors/file-source-demo"
echo "  Коннектор удалён."
echo ""

# Проверка: список коннекторов должен быть пустым
echo "  Текущий список коннекторов:"
curl -s "${CONNECT_URL}/connectors"
echo ""

echo "=== Итог ==="
echo "FileStreamSourceConnector читает файл построчно и отправляет строки в Kafka."
echo "Коннектор следит за файлом непрерывно — новые строки появляются в топике автоматически."
echo "Офсеты (позиция в файле) хранятся в топике connect-offsets на брокере."
echo "После удаления коннектора и повторного создания чтение начнётся с начала файла."
