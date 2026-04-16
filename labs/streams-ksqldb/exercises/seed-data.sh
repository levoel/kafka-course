#!/usr/bin/env bash
# seed-data.sh — Создание топиков и загрузка тестовых данных для лаборатории
#
# Создаёт три топика в Kafka:
#   orders     — 15 заказов (order_id, customer_id, amount, product, ts)
#   page-views — 30 просмотров страниц (user_id, page, duration, ts)
#   users      — 5 профилей пользователей (user_id как ключ, name, email, city)
#
# Запуск: bash exercises/seed-data.sh
# Требования: docker compose up -d (все сервисы healthy)

set -euo pipefail

KAFKA_CONTAINER="kafka-streams-lab"

echo "=== Инициализация тестовых данных ==="
echo ""

# --- Создание топиков ---
echo "Шаг 1: Создание топиков..."

# Топик orders — 3 партиции для параллельной обработки
docker compose exec "${KAFKA_CONTAINER}" \
    kafka-topics \
    --bootstrap-server localhost:9092 \
    --create \
    --if-not-exists \
    --topic orders \
    --partitions 3 \
    --replication-factor 1
echo "  Топик 'orders' создан (3 партиции)"

# Топик page-views — 3 партиции, будет использоваться для windowing упражнений
docker compose exec "${KAFKA_CONTAINER}" \
    kafka-topics \
    --bootstrap-server localhost:9092 \
    --create \
    --if-not-exists \
    --topic page-views \
    --partitions 3 \
    --replication-factor 1
echo "  Топик 'page-views' создан (3 партиции)"

# Топик users — 3 партиции, сообщения с ключами user_id (для KTable join)
docker compose exec "${KAFKA_CONTAINER}" \
    kafka-topics \
    --bootstrap-server localhost:9092 \
    --create \
    --if-not-exists \
    --topic users \
    --partitions 3 \
    --replication-factor 1
echo "  Топик 'users' создан (3 партиции)"
echo ""

# --- Загрузка данных пользователей (users) ---
# Формат: ключ:JSON-значение (parse.key=true, key.separator=:)
# Ключ = user_id (строка). В ksqlDB TABLE user_id будет PRIMARY KEY.
echo "Шаг 2: Загрузка профилей пользователей в топик 'users'..."
docker compose exec "${KAFKA_CONTAINER}" \
    bash -c "cat <<'USERS_EOF' | kafka-console-producer \
    --bootstrap-server localhost:9092 \
    --topic users \
    --property parse.key=true \
    --property key.separator=:
customer_1:{\"user_id\":\"customer_1\",\"name\":\"Иван Петров\",\"email\":\"ivan.petrov@example.com\",\"city\":\"Москва\"}
customer_2:{\"user_id\":\"customer_2\",\"name\":\"Мария Сидорова\",\"email\":\"m.sidorova@example.com\",\"city\":\"Санкт-Петербург\"}
customer_3:{\"user_id\":\"customer_3\",\"name\":\"Алексей Козлов\",\"email\":\"a.kozlov@example.com\",\"city\":\"Казань\"}
customer_4:{\"user_id\":\"customer_4\",\"name\":\"Елена Новикова\",\"email\":\"e.novikova@example.com\",\"city\":\"Новосибирск\"}
customer_5:{\"user_id\":\"customer_5\",\"name\":\"Дмитрий Волков\",\"email\":\"d.volkov@example.com\",\"city\":\"Екатеринбург\"}
USERS_EOF"
echo "  5 профилей пользователей загружено"
echo ""

# --- Загрузка данных заказов (orders) ---
# Временные метки разнесены — часть попадает в одно окно, часть в разные
# ts в миллисекундах Unix timestamp (2024-01-15)
echo "Шаг 3: Загрузка заказов в топик 'orders'..."
docker compose exec "${KAFKA_CONTAINER}" \
    bash -c "cat <<'ORDERS_EOF' | kafka-console-producer \
    --bootstrap-server localhost:9092 \
    --topic orders \
    --property parse.key=true \
    --property key.separator=:
order_001:{\"order_id\":\"order_001\",\"customer_id\":\"customer_1\",\"amount\":250.50,\"product\":\"Ноутбук\",\"ts\":1705312800000}
order_002:{\"order_id\":\"order_002\",\"customer_id\":\"customer_2\",\"amount\":89.99,\"product\":\"Мышь\",\"ts\":1705313100000}
order_003:{\"order_id\":\"order_003\",\"customer_id\":\"customer_1\",\"amount\":1500.00,\"product\":\"Монитор\",\"ts\":1705313400000}
order_004:{\"order_id\":\"order_004\",\"customer_id\":\"customer_3\",\"amount\":45.00,\"product\":\"Кабель USB-C\",\"ts\":1705313700000}
order_005:{\"order_id\":\"order_005\",\"customer_id\":\"customer_4\",\"amount\":320.00,\"product\":\"Клавиатура\",\"ts\":1705314000000}
order_006:{\"order_id\":\"order_006\",\"customer_id\":\"customer_2\",\"amount\":2100.00,\"product\":\"Телефон\",\"ts\":1705316400000}
order_007:{\"order_id\":\"order_007\",\"customer_id\":\"customer_5\",\"amount\":150.00,\"product\":\"Наушники\",\"ts\":1705316700000}
order_008:{\"order_id\":\"order_008\",\"customer_id\":\"customer_1\",\"amount\":75.50,\"product\":\"Коврик\",\"ts\":1705317000000}
order_009:{\"order_id\":\"order_009\",\"customer_id\":\"customer_3\",\"amount\":890.00,\"product\":\"Планшет\",\"ts\":1705317300000}
order_010:{\"order_id\":\"order_010\",\"customer_id\":\"customer_4\",\"amount\":199.00,\"product\":\"Веб-камера\",\"ts\":1705317600000}
order_011:{\"order_id\":\"order_011\",\"customer_id\":\"customer_5\",\"amount\":50.00,\"product\":\"Зарядник\",\"ts\":1705320000000}
order_012:{\"order_id\":\"order_012\",\"customer_id\":\"customer_1\",\"amount\":3500.00,\"product\":\"Принтер\",\"ts\":1705320300000}
order_013:{\"order_id\":\"order_013\",\"customer_id\":\"customer_2\",\"amount\":120.00,\"product\":\"Флешка\",\"ts\":1705320600000}
order_014:{\"order_id\":\"order_014\",\"customer_id\":\"customer_3\",\"amount\":440.00,\"product\":\"Колонки\",\"ts\":1705320900000}
order_015:{\"order_id\":\"order_015\",\"customer_id\":\"customer_4\",\"amount\":670.00,\"product\":\"Роутер\",\"ts\":1705321200000}
ORDERS_EOF"
echo "  15 заказов загружено"
echo ""

# --- Загрузка данных просмотров (page-views) ---
# Временные метки распределены по нескольким часам для демонстрации windowing
# ts соответствует 15.01.2024 10:00-13:00 UTC
echo "Шаг 4: Загрузка просмотров страниц в топик 'page-views'..."
docker compose exec "${KAFKA_CONTAINER}" \
    bash -c "cat <<'VIEWS_EOF' | kafka-console-producer \
    --bootstrap-server localhost:9092 \
    --topic page-views \
    --property parse.key=true \
    --property key.separator=:
user_1:{\"user_id\":\"user_1\",\"page\":\"/home\",\"duration\":45,\"ts\":1705312800000}
user_2:{\"user_id\":\"user_2\",\"page\":\"/catalog\",\"duration\":120,\"ts\":1705312860000}
user_1:{\"user_id\":\"user_1\",\"page\":\"/product/42\",\"duration\":300,\"ts\":1705312920000}
user_3:{\"user_id\":\"user_3\",\"page\":\"/home\",\"duration\":30,\"ts\":1705312980000}
user_2:{\"user_id\":\"user_2\",\"page\":\"/product/15\",\"duration\":210,\"ts\":1705313040000}
user_1:{\"user_id\":\"user_1\",\"page\":\"/cart\",\"duration\":90,\"ts\":1705313100000}
user_4:{\"user_id\":\"user_4\",\"page\":\"/home\",\"duration\":60,\"ts\":1705313160000}
user_3:{\"user_id\":\"user_3\",\"page\":\"/catalog\",\"duration\":180,\"ts\":1705313220000}
user_2:{\"user_id\":\"user_2\",\"page\":\"/checkout\",\"duration\":420,\"ts\":1705313280000}
user_1:{\"user_id\":\"user_1\",\"page\":\"/home\",\"duration\":15,\"ts\":1705313340000}
user_5:{\"user_id\":\"user_5\",\"page\":\"/catalog\",\"duration\":240,\"ts\":1705316400000}
user_1:{\"user_id\":\"user_1\",\"page\":\"/product/99\",\"duration\":180,\"ts\":1705316460000}
user_3:{\"user_id\":\"user_3\",\"page\":\"/home\",\"duration\":45,\"ts\":1705316520000}
user_4:{\"user_id\":\"user_4\",\"page\":\"/product/42\",\"duration\":300,\"ts\":1705316580000}
user_2:{\"user_id\":\"user_2\",\"page\":\"/home\",\"duration\":60,\"ts\":1705316640000}
user_5:{\"user_id\":\"user_5\",\"page\":\"/catalog\",\"duration\":150,\"ts\":1705316700000}
user_1:{\"user_id\":\"user_1\",\"page\":\"/cart\",\"duration\":200,\"ts\":1705316760000}
user_3:{\"user_id\":\"user_3\",\"page\":\"/product/15\",\"duration\":280,\"ts\":1705316820000}
user_4:{\"user_id\":\"user_4\",\"page\":\"/checkout\",\"duration\":360,\"ts\":1705316880000}
user_2:{\"user_id\":\"user_2\",\"page\":\"/home\",\"duration\":50,\"ts\":1705316940000}
user_1:{\"user_id\":\"user_1\",\"page\":\"/home\",\"duration\":35,\"ts\":1705320000000}
user_5:{\"user_id\":\"user_5\",\"page\":\"/product/99\",\"duration\":400,\"ts\":1705320060000}
user_2:{\"user_id\":\"user_2\",\"page\":\"/catalog\",\"duration\":110,\"ts\":1705320120000}
user_3:{\"user_id\":\"user_3\",\"page\":\"/cart\",\"duration\":160,\"ts\":1705320180000}
user_4:{\"user_id\":\"user_4\",\"page\":\"/home\",\"duration\":25,\"ts\":1705320240000}
user_1:{\"user_id\":\"user_1\",\"page\":\"/product/42\",\"duration\":320,\"ts\":1705320300000}
user_5:{\"user_id\":\"user_5\",\"page\":\"/checkout\",\"duration\":480,\"ts\":1705320360000}
user_2:{\"user_id\":\"user_2\",\"page\":\"/product/15\",\"duration\":190,\"ts\":1705320420000}
user_3:{\"user_id\":\"user_3\",\"page\":\"/home\",\"duration\":70,\"ts\":1705320480000}
user_4:{\"user_id\":\"user_4\",\"page\":\"/catalog\",\"duration\":230,\"ts\":1705320540000}
VIEWS_EOF"
echo "  30 просмотров страниц загружено"
echo ""

# --- Проверка создания топиков ---
echo "Шаг 5: Проверка топиков..."
docker compose exec "${KAFKA_CONTAINER}" \
    kafka-topics \
    --bootstrap-server localhost:9092 \
    --list | grep -E "^(orders|page-views|users)$" | sort
echo ""

echo "=== Данные загружены ==="
echo "Следующий шаг: подключитесь к ksqlDB CLI и выполните упражнения."
echo ""
echo "  docker compose exec ksqldb-cli ksql http://ksqldb-server:8088"
echo ""
echo "Упражнения:"
echo "  bash exercises/01_streams_topology.sh    — Streams topology"
echo "  bash exercises/02_ksqldb_queries.sh      — CSAS/CTAS, push/pull"
echo "  bash exercises/03_windowed_aggregation.sh — Windowed aggregations"
