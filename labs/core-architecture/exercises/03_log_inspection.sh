#!/usr/bin/env bash
# Упражнение 03: Инспекция лог-сегментов Kafka
#
# Демонстрирует структуру хранения данных на диске:
#   .log       — файл с записями сообщений (последовательная запись)
#   .index     — разреженный индекс: offset -> позиция в .log файле
#   .timeindex — индекс по времени: timestamp -> offset
#
# Запуск с хостовой машины:
#   bash exercises/03_log_inspection.sh
#
# Или вручную внутри контейнера kafka:
#   docker compose exec kafka bash
#   kafka-topics.sh --bootstrap-server localhost:9092 --list
#
# Ожидаемый результат: список топиков, информация о лог-директориях,
# файлы .log/.index/.timeindex в директориях партиций.

set -euo pipefail

# Адрес брокера для команд с хостовой машины
BOOTSTRAP_SERVER="localhost:9092"

# Имя Kafka-контейнера (совпадает с container_name в docker-compose.yml)
KAFKA_CONTAINER="kafka-lab"

echo "=== Упражнение 03: Инспекция лог-сегментов ==="
echo ""

# --- Шаг 1: Список топиков ---
# kafka-topics.sh --bootstrap-server — стандартный способ в Kafka 4.0+.
# Флаг --zookeeper удалён в Kafka 4.0; используем только --bootstrap-server.
echo "Шаг 1: Список топиков (kafka-topics.sh --list):"
echo "---"
docker compose exec "${KAFKA_CONTAINER}" \
    kafka-topics.sh \
    --bootstrap-server localhost:9092 \
    --list
echo ""

# --- Шаг 2: Описание топика orders ---
# --describe показывает: количество партиций, replication factor,
# лидера каждой партиции, список ISR (In-Sync Replicas), список реплик.
echo "Шаг 2: Описание топика 'orders' (kafka-topics.sh --describe):"
echo "---"
docker compose exec "${KAFKA_CONTAINER}" \
    kafka-topics.sh \
    --bootstrap-server localhost:9092 \
    --describe \
    --topic orders 2>/dev/null || echo "  Топик 'orders' не найден. Сначала запустите 01_producer_basics.py"
echo ""

# --- Шаг 3: Инспекция директорий логов ---
# kafka-log-dirs.sh выводит информацию о размере каждого лог-сегмента
# и офсете (OffsetLag) для каждой партиции на каждом брокере.
echo "Шаг 3: Директории лог-сегментов (kafka-log-dirs.sh):"
echo "---"
docker compose exec "${KAFKA_CONTAINER}" \
    kafka-log-dirs.sh \
    --bootstrap-server localhost:9092 \
    --topic-list orders \
    --broker-list 1 2>/dev/null || echo "  Топик 'orders' не найден. Сначала запустите 01_producer_basics.py"
echo ""

# --- Шаг 4: Структура файлов лог-сегмента ---
# Каждая партиция хранится в отдельной директории: {topic}-{partition}/
# Внутри директории находятся файлы активного и закрытых сегментов.
#
# Структура файлов:
#   00000000000000000000.log       — бинарный файл с записями сообщений
#   00000000000000000000.index     — разреженный индекс offset -> byte offset в .log
#   00000000000000000000.timeindex — индекс timestamp -> offset (для поиска по времени)
#   leader-epoch-checkpoint        — KRaft: текущий epoch лидера партиции
#
# Имя файла (00000000000000000000) — это base offset сегмента (первый offset в сегменте).
echo "Шаг 4: Файлы лог-сегмента для партиции orders-0:"
echo "---"
docker compose exec "${KAFKA_CONTAINER}" \
    bash -c "ls -la /var/kafka/logs/orders-0/ 2>/dev/null || echo '  Директория orders-0 не найдена. Сначала запустите 01_producer_basics.py'"
echo ""

# --- Шаг 5: Просмотр всех директорий партиций ---
# /var/kafka/logs/ содержит директории для всех партиций всех топиков.
# Системные топики (например, __consumer_offsets) также видны здесь.
echo "Шаг 5: Все партиционные директории в /var/kafka/logs/:"
echo "---"
docker compose exec "${KAFKA_CONTAINER}" \
    bash -c "ls -la /var/kafka/logs/ | grep -v '^total' | grep '^d'"
echo ""

# --- Шаг 6: Декодирование лог-файла ---
# kafka-dump-log.sh позволяет читать содержимое .log файла в человекочитаемом формате.
# Показывает: offset, timestamp, key, value для каждой записи в сегменте.
echo "Шаг 6: Декодирование содержимого лог-сегмента orders-0 (первые 5 записей):"
echo "---"
docker compose exec "${KAFKA_CONTAINER}" \
    bash -c "
        LOG_FILE=\$(ls /var/kafka/logs/orders-0/*.log 2>/dev/null | head -1)
        if [ -n \"\$LOG_FILE\" ]; then
            kafka-dump-log.sh --files \"\$LOG_FILE\" --print-data-log 2>/dev/null | head -30
        else
            echo '  Лог-файл не найден. Сначала запустите 01_producer_basics.py'
        fi
    "
echo ""

echo "=== Итог ==="
echo "Структура хранения Kafka:"
echo "  /var/kafka/logs/{topic}-{partition}/"
echo "    *.log       — бинарные записи сообщений (последовательная запись)"
echo "    *.index     — разреженный индекс: offset -> позиция в .log"
echo "    *.timeindex — индекс по времени: timestamp -> offset"
echo ""
echo "Ключевые свойства:"
echo "  - Запись всегда идёт в конец активного сегмента (append-only)"
echo "  - Новый сегмент создаётся при достижении log.segment.bytes (по умолчанию 1 GB)"
echo "  - Потребители читают до High Watermark (HW), а не до Log End Offset (LEO)"
