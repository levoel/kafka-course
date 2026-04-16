#!/bin/bash
# Упражнение 01: Репликация топиков через MirrorMaker 2
#
# Цель: убедиться что MirrorMaker 2 реплицирует топики и сообщения
# из DC-1 (Primary) в DC-2 (DR) с префиксом 'dc1.' в имени топика.
#
# Что изучите:
#   - Как MM2 автоматически создаёт реплицированные топики на DC-2
#   - Соглашение об именовании DefaultReplicationPolicy (префикс dc1.)
#   - Как проверить репликацию и измерить задержку
#
# Требования: docker compose up -d, все сервисы healthy
#
# Запуск: bash exercises/01_mm2_replication.sh

set -euo pipefail

DC1="kafka-dc1"
DC2="kafka-dc2"

echo "=== Упражнение 01: Репликация топиков через MirrorMaker 2 ==="
echo ""

# --- Шаг 1: Проверка готовности обоих кластеров ---
# Kafka требует несколько секунд после старта для инициализации KRaft.
echo "=== Шаг 1: Проверка готовности DC-1 и DC-2 ==="
echo ""

echo "Ожидание DC-1..."
until docker exec "${DC1}" kafka-topics.sh \
  --bootstrap-server localhost:9092 --list >/dev/null 2>&1; do
  echo "  DC-1 ещё не готов, ждём 5 секунд..."
  sleep 5
done
echo "DC-1 готов."

echo "Ожидание DC-2..."
until docker exec "${DC2}" kafka-topics.sh \
  --bootstrap-server localhost:9092 --list >/dev/null 2>&1; do
  echo "  DC-2 ещё не готов, ждём 5 секунд..."
  sleep 5
done
echo "DC-2 готов."
echo ""

# --- Шаг 2: Создание тестового топика 'orders' на DC-1 ---
# MirrorMaker 2 автоматически реплицирует этот топик на DC-2.
# Согласно DefaultReplicationPolicy, на DC-2 топик будет называться 'dc1.orders'.
echo "=== Шаг 2: Создание топика 'orders' на DC-1 ==="
echo ""

docker exec "${DC1}" kafka-topics.sh \
  --bootstrap-server localhost:9092 \
  --create \
  --topic orders \
  --partitions 3 \
  --replication-factor 1 \
  --if-not-exists

echo ""
echo "Топик 'orders' создан на DC-1."
echo ""

# --- Шаг 3: Публикация 10 тестовых сообщений в топик 'orders' на DC-1 ---
# Каждое сообщение имеет формат: order-N
# Используем printf для совместимости с set -euo pipefail
echo "=== Шаг 3: Публикация 10 сообщений в топик 'orders' на DC-1 ==="
echo ""

# Генерируем 10 сообщений и передаём их в kafka-console-producer
printf '%s\n' \
  "order-001:created" \
  "order-002:created" \
  "order-003:payment_pending" \
  "order-004:created" \
  "order-005:confirmed" \
  "order-006:created" \
  "order-007:payment_pending" \
  "order-008:confirmed" \
  "order-009:created" \
  "order-010:cancelled" \
| docker exec -i "${DC1}" kafka-console-producer.sh \
    --bootstrap-server localhost:9092 \
    --topic orders

echo "10 сообщений опубликовано в 'orders' на DC-1."
echo ""

# --- Шаг 4: Ожидание репликации MM2 ---
# MirrorMaker 2 работает с небольшой задержкой (обычно 2-10 секунд).
# DefaultReplicationPolicy создаёт топик 'dc1.orders' на DC-2 автоматически.
echo "=== Шаг 4: Ожидание репликации MM2 (30 секунд) ==="
echo ""
echo "MirrorMaker 2 реплицирует данные с задержкой 2-10 секунд."
echo "В production это и есть RPO (Recovery Point Objective)."
echo "Ждём 30 секунд для надёжной репликации..."
echo ""
sleep 30

# --- Шаг 5: Проверка топиков на DC-2 ---
# Ожидаем увидеть топик 'dc1.orders' (DefaultReplicationPolicy добавляет префикс 'dc1.').
echo "=== Шаг 5: Список топиков на DC-2 ==="
echo ""
echo "Топики на DC-2 (должны включать 'dc1.orders'):"
docker exec "${DC2}" kafka-topics.sh \
  --bootstrap-server localhost:9092 \
  --list
echo ""

# Проверяем наличие реплицированного топика
if docker exec "${DC2}" kafka-topics.sh \
  --bootstrap-server localhost:9092 \
  --list 2>/dev/null | grep -q "^dc1\.orders$"; then
  echo "Топик 'dc1.orders' обнаружен на DC-2. Репликация работает."
else
  echo "ВНИМАНИЕ: Топик 'dc1.orders' не найден на DC-2."
  echo "Возможные причины:"
  echo "  1. MM2 ещё не запустился (подождите ещё 30 секунд)"
  echo "  2. Ошибка в конфигурации mm2.properties"
  echo "  3. Проблема с сетью между контейнерами"
  echo ""
  echo "Проверьте логи MM2: docker compose logs mirrormaker2"
fi
echo ""

# --- Шаг 6: Чтение реплицированных сообщений с DC-2 ---
# Consumer читает из 'dc1.orders' (не 'orders') на DC-2.
# После failover все consumers переключаются на топики с префиксом 'dc1.'.
echo "=== Шаг 6: Чтение реплицированных сообщений с DC-2 ==="
echo ""
echo "Читаем из топика 'dc1.orders' на DC-2 (ожидаем 10 сообщений):"
echo ""

docker exec "${DC2}" kafka-console-consumer.sh \
  --bootstrap-server localhost:9092 \
  --topic dc1.orders \
  --from-beginning \
  --max-messages 10 \
  --timeout-ms 10000 2>/dev/null || true

echo ""

# --- Шаг 7: Публикация в топик 'payments' и проверка репликации ---
# MM2 реплицирует ВСЕ топики (согласно topics = .* в mm2.properties).
echo "=== Шаг 7: Репликация второго топика 'payments' ==="
echo ""

echo "Создание топика 'payments' на DC-1..."
docker exec "${DC1}" kafka-topics.sh \
  --bootstrap-server localhost:9092 \
  --create \
  --topic payments \
  --partitions 3 \
  --replication-factor 1 \
  --if-not-exists

echo "Публикация 5 сообщений о платежах..."
printf '%s\n' \
  "payment-001:charged:99.99" \
  "payment-002:charged:149.50" \
  "payment-003:refunded:99.99" \
  "payment-004:charged:299.00" \
  "payment-005:charged:49.99" \
| docker exec -i "${DC1}" kafka-console-producer.sh \
    --bootstrap-server localhost:9092 \
    --topic payments

echo "Ожидание репликации (15 секунд)..."
sleep 15

echo ""
echo "Все топики на DC-2 после добавления 'payments':"
docker exec "${DC2}" kafka-topics.sh \
  --bootstrap-server localhost:9092 \
  --list | grep "^dc1\." | sort

echo ""

# --- Итог ---
echo "=== Итог упражнения 01 ==="
echo ""
echo "Вы изучили:"
echo "  1. MirrorMaker 2 автоматически реплицирует топики DC-1 -> DC-2"
echo "  2. DefaultReplicationPolicy добавляет префикс 'dc1.' к именам топиков"
echo "  3. Репликация происходит с задержкой 2-10 сек (RPO = replication lag)"
echo "  4. Consumer при failover читает из 'dc1.{topic}', не из '{topic}'"
echo ""
echo "Следующее упражнение: 02_offset_translation.sh"
echo "(перевод consumer group offsets при failover)"
