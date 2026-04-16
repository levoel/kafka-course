#!/usr/bin/env bash
# Упражнение 03: Windowed aggregations
#
# Цель: освоить оконные агрегации в ksqlDB:
#   - Создание STREAM с event time через timestamp поле
#   - TUMBLING window (фиксированные непересекающиеся окна)
#   - HOPPING window (фиксированные перекрывающиеся окна)
#   - Сравнение количества строк в tumbling vs hopping результатах
#   - Pull query с window bounds для конкретного пользователя
#   - SESSION window (динамические окна по пробелам активности)
#
# Данные в топике 'page-views' разнесены по трём часовым периодам:
#   10:00-10:10 UTC — 10 событий (окно 1)
#   11:00-11:10 UTC — 10 событий (окно 2)
#   12:00-12:10 UTC — 10 событий (окно 3)
#
# Запуск: bash exercises/03_windowed_aggregation.sh
# Требования: docker compose up -d, seed-data.sh выполнен

set -euo pipefail

echo "=== Упражнение 03: Windowed aggregations ==="
echo ""
echo "Убедитесь, что у вас открыт ksqlDB CLI в отдельном терминале:"
echo "  docker compose exec ksqldb-cli ksql http://ksqldb-server:8088"
echo ""
echo "Нажмите Enter для начала..."
read -r

# --- Шаг 1: Создание STREAM из page-views с event time ---
# Параметр timestamp='ts' указывает ksqlDB использовать поле ts из JSON
# как event time (время события), а не processing time (время обработки).
# Это критически важно для корректной windowing: событие попадает в окно
# согласно времени его создания, а не времени прибытия в Kafka.
echo "=== Шаг 1: Создание STREAM из page-views с event time ==="
echo ""
echo "В ksqlDB CLI выполните:"
echo ""
cat << 'STEP1_EOF'
CREATE STREAM pageviews_stream (
  user_id VARCHAR KEY,
  page VARCHAR,
  duration INT,
  ts BIGINT
) WITH (
  kafka_topic = 'page-views',
  value_format = 'JSON',
  timestamp = 'ts'
);
STEP1_EOF
echo ""
echo "Ожидаемый результат: 'Stream created'"
echo ""
echo "EXPLAIN:"
echo "  timestamp='ts' — ksqlDB извлекает event time из поля ts (BIGINT, ms)."
echo "  Без timestamp= ksqlDB использует processing time (время обработки)."
echo "  Для корректного windowing по историческим данным ВСЕГДА указывайте timestamp."
echo ""
echo "Нажмите Enter для продолжения..."
read -r

# --- Шаг 2: TUMBLING window — непересекающиеся часовые окна ---
# WINDOW TUMBLING (SIZE 1 HOUR): каждое событие попадает ровно в одно окно.
# Окна: [10:00, 11:00), [11:00, 12:00), [12:00, 13:00)
# Данные в топике разнесены по трём часовым периодам — каждый период = отдельное окно.
# WINDOWSTART и WINDOWEND — граничные метки окна (BIGINT ms).
echo "=== Шаг 2: TUMBLING window (SIZE 1 HOUR) ==="
echo ""
echo "В ksqlDB CLI выполните:"
echo ""
cat << 'STEP2_EOF'
CREATE TABLE pageviews_per_hour AS
  SELECT
    user_id,
    COUNT(*) AS view_count,
    SUM(duration) AS total_duration,
    WINDOWSTART AS window_start,
    WINDOWEND AS window_end
  FROM pageviews_stream
  WINDOW TUMBLING (SIZE 1 HOUR)
  GROUP BY user_id
  EMIT CHANGES;
STEP2_EOF
echo ""
echo "Ожидаемый результат: 'Table created'"
echo ""
echo "EXPLAIN:"
echo "  WINDOW TUMBLING (SIZE 1 HOUR) = TimeWindows.ofSizeWithNoGrace(Duration.ofHours(1)) в Kafka Streams."
echo "  30 событий из 3 часовых периодов → 3 окна × 5 пользователей = 15 строк в TABLE."
echo "  Каждая строка: (user_id, hour_window) → (view_count, total_duration)."
echo "  Составной ключ: (user_id + window_start_ms)."
echo ""
echo "Нажмите Enter для продолжения..."
read -r

# --- Шаг 3: Push query для наблюдения windowed результатов ---
# Push query показывает обновления TABLE по мере обработки событий.
# LIMIT 20 останавливает после 20 строк (5 пользователей × 3 часа = 15 строк + updateы).
echo "=== Шаг 3: Push query — наблюдение windowed результатов ==="
echo ""
echo "В ksqlDB CLI выполните:"
echo ""
echo "  SELECT user_id, view_count, total_duration, window_start, window_end"
echo "  FROM pageviews_per_hour EMIT CHANGES LIMIT 20;"
echo ""
echo "Ожидаемый вывод (15 строк — по одной на каждую (user, window) пару):"
echo "  user_id | view_count | total_duration | window_start      | window_end"
echo "  user_1  | 4          | 650            | 1705312800000     | 1705316400000"
echo "  user_2  | 2          | 330            | 1705312800000     | 1705316400000"
echo "  ...     | ...        | ...            | ... (11:00 UTC)   | ..."
echo "  user_1  | 3          | 700            | 1705316400000     | 1705320000000"
echo ""
echo "Нажмите Enter для продолжения..."
read -r

# --- Шаг 4: Pull query с указанием ключа ---
# Pull query на windowed TABLE возвращает все окна для данного user_id.
# Для конкретного окна нужно указать WINDOWSTART и WINDOWEND.
echo "=== Шаг 4: Pull query — все окна для конкретного пользователя ==="
echo ""
echo "В ksqlDB CLI выполните:"
echo ""
echo "  SELECT user_id, view_count, total_duration, window_start, window_end"
echo "  FROM pageviews_per_hour"
echo "  WHERE user_id = 'user_1';"
echo ""
echo "Ожидаемый вывод: 3 строки (3 часовых окна для user_1)"
echo "  user_1 | 4 | 650  | 1705312800000 | 1705316400000  (10:00-11:00)"
echo "  user_1 | 3 | 700  | 1705316400000 | 1705320000000  (11:00-12:00)"
echo "  user_1 | 3 | 555  | 1705320000000 | 1705323600000  (12:00-13:00)"
echo ""
echo "Нажмите Enter для продолжения..."
read -r

# --- Шаг 5: HOPPING window для сравнения ---
# WINDOW HOPPING (SIZE 1 HOUR, ADVANCE BY 15 MINUTES):
#   - Каждое событие принадлежит НЕСКОЛЬКИМ окнам одновременно
#   - Перекрытие = SIZE / ADVANCE = 60 / 15 = 4 окна на событие
#   - Результат: больше строк в TABLE, чем при TUMBLING
# Это позволяет получить "скользящие" агрегаты с обновлением каждые 15 минут.
echo "=== Шаг 5: HOPPING window (SIZE 1 HOUR, ADVANCE BY 15 MINUTES) ==="
echo ""
echo "В ksqlDB CLI выполните:"
echo ""
cat << 'STEP5_EOF'
CREATE TABLE pageviews_hopping AS
  SELECT
    user_id,
    COUNT(*) AS view_count,
    WINDOWSTART AS window_start,
    WINDOWEND AS window_end
  FROM pageviews_stream
  WINDOW HOPPING (SIZE 1 HOUR, ADVANCE BY 15 MINUTES)
  GROUP BY user_id
  EMIT CHANGES;
STEP5_EOF
echo ""
echo "Ожидаемый результат: 'Table created'"
echo ""
echo "EXPLAIN:"
echo "  HOPPING (SIZE 1h, ADVANCE 15m) = TimeWindows.ofSizeWithNoGrace(1h).advanceBy(15m) в Kafka Streams."
echo "  Каждое из 30 событий попадает в 4 окна (1 час / 15 минут)."
echo "  Ожидаемое количество строк: значительно больше чем в TUMBLING TABLE."
echo ""
echo "Нажмите Enter для продолжения..."
read -r

# --- Шаг 6: Сравнение tumbling vs hopping ---
# Демонстрируем ключевую разницу: hopping производит больше строк
# (больше перекрывающихся окон на одно событие).
echo "=== Шаг 6: Сравнение количества строк — tumbling vs hopping ==="
echo ""
echo "В ksqlDB CLI выполните оба pull query для user_1 и сравните:"
echo ""
echo "  -- TUMBLING: сколько окон у user_1?"
echo "  SELECT COUNT(*) AS window_count FROM pageviews_per_hour WHERE user_id = 'user_1';"
echo ""
echo "  -- HOPPING: сколько окон у user_1?"
echo "  SELECT COUNT(*) AS window_count FROM pageviews_hopping WHERE user_id = 'user_1';"
echo ""
echo "Ожидаемый результат:"
echo "  TUMBLING: window_count = 3 (ровно 3 непересекающихся часовых окна)"
echo "  HOPPING: window_count > 3 (несколько перекрывающихся окон с 15-минутным сдвигом)"
echo ""
echo "Вывод: TUMBLING для простых периодических агрегаций."
echo "       HOPPING для скользящих агрегатов с частым обновлением."
echo ""
echo "Нажмите Enter для продолжения..."
read -r

# --- Шаг 7: SESSION window (бонусное упражнение) ---
# SESSION window группирует события по пробелам активности.
# SESSION (30 MINUTES): если между событиями > 30 минут — новая сессия.
# В наших данных: user_1 имеет события в 10:00-10:10, 11:00-11:10, 12:00-12:10.
# Каждый "кластер" событий = отдельная сессия.
echo "=== Шаг 7: SESSION window (бонусное) ==="
echo ""
echo "В ksqlDB CLI выполните:"
echo ""
cat << 'STEP7_EOF'
CREATE TABLE user_sessions AS
  SELECT
    user_id,
    COUNT(*) AS events_in_session,
    SUM(duration) AS session_duration,
    WINDOWSTART AS session_start,
    WINDOWEND AS session_end
  FROM pageviews_stream
  WINDOW SESSION (30 MINUTES)
  GROUP BY user_id
  EMIT CHANGES;
STEP7_EOF
echo ""
echo "Проверьте результат (pull query):"
echo ""
echo "  SELECT user_id, events_in_session, session_start, session_end"
echo "  FROM user_sessions"
echo "  WHERE user_id = 'user_1';"
echo ""
echo "Ожидаемый вывод: несколько строк — каждый временной кластер = отдельная сессия."
echo "Пробел > 30 минут между кластерами означает конец одной сессии и начало новой."
echo ""
echo "Нажмите Enter для продолжения..."
read -r

# --- Шаг 8: Очистка ---
echo "=== Шаг 8: Очистка ==="
echo ""
echo "В ksqlDB CLI для очистки всех объектов упражнения:"
echo ""
echo "  -- Остановить persistent queries"
echo "  TERMINATE CTAS_PAGEVIEWS_PER_HOUR_0;"
echo "  TERMINATE CTAS_PAGEVIEWS_HOPPING_0;"
echo "  TERMINATE CTAS_USER_SESSIONS_0;"
echo ""
echo "  -- Удалить TABLE и STREAM"
echo "  DROP TABLE IF EXISTS pageviews_per_hour DELETE TOPIC;"
echo "  DROP TABLE IF EXISTS pageviews_hopping DELETE TOPIC;"
echo "  DROP TABLE IF EXISTS user_sessions DELETE TOPIC;"
echo "  DROP STREAM IF EXISTS pageviews_stream;"
echo ""
echo "  -- Остановить все оставшиеся queries"
echo "  SHOW QUERIES;"
echo "  -- для каждого: TERMINATE <query_id>;"
echo ""

echo "=== Итог упражнения 03 ==="
echo ""
echo "Вы освоили:"
echo "  1. timestamp='ts' — использование event time из поля данных для windowing"
echo "  2. WINDOW TUMBLING — фиксированные непересекающиеся окна"
echo "  3. WINDOWSTART / WINDOWEND — псевдостолбцы с границами окна (BIGINT ms)"
echo "  4. Pull query на windowed TABLE — указание ключа + опциональные window bounds"
echo "  5. WINDOW HOPPING — перекрывающиеся окна, больше строк чем TUMBLING"
echo "  6. Количественное сравнение: hopping = tumbling × (SIZE/ADVANCE) строк"
echo "  7. WINDOW SESSION — динамические окна по пробелам активности"
echo ""
echo "Завершите работу с лабораторией:"
echo "  docker compose down -v"
