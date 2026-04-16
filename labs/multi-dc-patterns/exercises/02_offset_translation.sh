#!/bin/bash
# Упражнение 02: Перевод consumer group offsets при failover
#
# Цель: демонстрация того, как MirrorMaker 2 автоматически синхронизирует
# consumer group offsets между DC-1 и DC-2, позволяя consumer-группам
# продолжить обработку с правильного места после failover.
#
# Что изучите:
#   - Как sync.group.offsets.enabled=true переносит офсеты на DC-2
#   - Топик dc1.checkpoints.internal и его роль
#   - Почему consumer на DC-2 не начинает с начала после переключения
#   - Механику offset translation (offset в DC-1 != offset в DC-2)
#
# Требования:
#   - docker compose up -d, все сервисы healthy
#   - Упражнение 01 выполнено (топики 'orders' созданы на DC-1)
#
# Запуск: bash exercises/02_offset_translation.sh

set -euo pipefail

DC1="kafka-dc1"
DC2="kafka-dc2"
TOPIC="orders"
CONSUMER_GROUP="order-processor"

echo "=== Упражнение 02: Перевод consumer group offsets при failover ==="
echo ""

# --- Шаг 1: Создание топика и публикация 100 сообщений ---
# Если топик не существует -- создаём заново.
# 100 сообщений: consumer обработает 50, затем остановится для имитации failover.
echo "=== Шаг 1: Подготовка -- создание топика и публикация 100 сообщений ==="
echo ""

docker exec "${DC1}" kafka-topics.sh \
  --bootstrap-server localhost:9092 \
  --create \
  --topic "${TOPIC}" \
  --partitions 3 \
  --replication-factor 1 \
  --if-not-exists 2>/dev/null || true

echo "Публикация 100 сообщений в топик '${TOPIC}' на DC-1..."
seq 1 100 | awk '{print "order-" sprintf("%03d", $1) ":created"}' \
| docker exec -i "${DC1}" kafka-console-producer.sh \
    --bootstrap-server localhost:9092 \
    --topic "${TOPIC}"

echo "100 сообщений опубликовано."
echo ""

# --- Шаг 2: Обработка 50 сообщений группой 'order-processor' на DC-1 ---
# Consumer читает с DC-1, обрабатывает 50 сообщений, коммитит офсеты.
# После этого у consumer group будет offset ~50 по всем партициям.
echo "=== Шаг 2: Потребление 50 сообщений группой '${CONSUMER_GROUP}' на DC-1 ==="
echo ""

docker exec "${DC1}" kafka-console-consumer.sh \
  --bootstrap-server localhost:9092 \
  --topic "${TOPIC}" \
  --group "${CONSUMER_GROUP}" \
  --from-beginning \
  --max-messages 50 \
  --timeout-ms 15000 2>/dev/null || true

echo ""
echo "50 сообщений обработано. Consumer остановлен (имитация остановки DC-1)."
echo ""

# --- Шаг 3: Просмотр офсетов consumer group на DC-1 ---
# Ожидаем увидеть: партиции 0, 1, 2 с суммарным CURRENT-OFFSET ~50,
# LOG-END-OFFSET = 100, LAG = ~50.
echo "=== Шаг 3: Офсеты consumer group '${CONSUMER_GROUP}' на DC-1 ==="
echo ""

docker exec "${DC1}" kafka-consumer-groups.sh \
  --bootstrap-server localhost:9092 \
  --describe \
  --group "${CONSUMER_GROUP}"

echo ""

# --- Шаг 4: Ожидание синхронизации офсетов через MM2 ---
# MirrorCheckpointConnector записывает переведённые офсеты в
# топик dc1.checkpoints.internal на DC-2 каждые 10 секунд
# (sync.group.offsets.interval.seconds = 10 в mm2.properties).
# sync.group.offsets.enabled=true автоматически коммитит эти офсеты
# в consumer group 'order-processor' на DC-2.
echo "=== Шаг 4: Ожидание синхронизации офсетов через MM2 (30 секунд) ==="
echo ""
echo "MirrorCheckpointConnector переводит офсеты dc1 -> dc2 каждые 10 секунд."
echo "sync.group.offsets.enabled=true автоматически коммитит их на DC-2."
echo "Ждём 30 секунд для надёжной синхронизации..."
sleep 30

# --- Шаг 5: Просмотр checkpoint топика на DC-2 ---
# Топик dc1.checkpoints.internal содержит маппинг:
# (group, source_topic, source_partition) -> (source_offset, target_offset)
echo "=== Шаг 5: Содержимое dc1.checkpoints.internal на DC-2 ==="
echo ""
echo "Этот топик хранит переведённые офсеты:"
echo "(consumer-group, исходный-топик, партиция) -> (офсет_dc1, офсет_dc2)"
echo ""

docker exec "${DC2}" kafka-console-consumer.sh \
  --bootstrap-server localhost:9092 \
  --topic dc1.checkpoints.internal \
  --from-beginning \
  --max-messages 20 \
  --timeout-ms 5000 2>/dev/null || echo "(Checkpoint топик пока пуст или нет данных)"

echo ""

# --- Шаг 6: Проверка офсетов consumer group на DC-2 ---
# Если sync.group.offsets.enabled=true работает корректно,
# группа 'order-processor' на DC-2 должна иметь переведённые офсеты
# в топике 'dc1.orders' (DefaultReplicationPolicy).
echo "=== Шаг 6: Офсеты consumer group '${CONSUMER_GROUP}' на DC-2 ==="
echo ""
echo "Офсеты в топике 'dc1.orders' на DC-2:"

docker exec "${DC2}" kafka-consumer-groups.sh \
  --bootstrap-server localhost:9092 \
  --describe \
  --group "${CONSUMER_GROUP}" 2>/dev/null || echo "(Группа ещё не синхронизирована на DC-2)"

echo ""

# --- Шаг 7: Симуляция failover -- consumer продолжает на DC-2 ---
# Consumer переключается на DC-2 и читает из 'dc1.orders' (не 'orders').
# Если офсеты переведены корректно -- consumer получит сообщения 51-100,
# а не начнёт с начала (сообщения 1-100).
echo "=== Шаг 7: Failover -- consumer продолжает обработку на DC-2 ==="
echo ""
echo "Читаем из 'dc1.orders' на DC-2 с группой '${CONSUMER_GROUP}'."
echo "Ожидаем получить ~50 оставшихся сообщений (51-100), не всё с начала."
echo ""

docker exec "${DC2}" kafka-console-consumer.sh \
  --bootstrap-server localhost:9092 \
  --topic "dc1.${TOPIC}" \
  --group "${CONSUMER_GROUP}" \
  --max-messages 50 \
  --timeout-ms 15000 2>/dev/null || true

echo ""

# --- Шаг 8: Сравнение офсетов до и после failover ---
echo "=== Шаг 8: Состояние consumer group на DC-2 после failover ==="
echo ""

docker exec "${DC2}" kafka-consumer-groups.sh \
  --bootstrap-server localhost:9092 \
  --describe \
  --group "${CONSUMER_GROUP}" 2>/dev/null || echo "(нет данных)"

echo ""

# --- Итог ---
echo "=== Итог упражнения 02 ==="
echo ""
echo "Вы изучили:"
echo "  1. sync.group.offsets.enabled=true автоматически переносит офсеты DC-1 -> DC-2"
echo "  2. dc1.checkpoints.internal: топик с маппингом офсетов между кластерами"
echo "  3. Офсеты в DC-1 и DC-2 разные: MM2 переводит их через checkpoint маппинг"
echo "  4. После failover consumer продолжает с правильного места, не с начала"
echo "  5. Без sync.group.offsets consumer начинал бы с auto.offset.reset (обычно earliest)"
echo ""
echo "Следующее упражнение: 03_outbox_pattern.sh"
echo "(паттерн transactional outbox с PostgreSQL)"
