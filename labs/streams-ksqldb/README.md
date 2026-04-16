# Лаборатория: Kafka Streams и ksqlDB

Практическая лаборатория для освоения Модулей 07 (Kafka Streams) и 08 (ksqlDB). Вы создадите потоки и таблицы, построите pipeline обогащения событий, выполните агрегации с оконными функциями и сравните tumbling vs hopping windows на реальных данных.

---

## Что включено

| Компонент | Образ | Версия | Назначение |
|-----------|-------|--------|-----------|
| Kafka | `confluentinc/cp-kafka` | 7.9.0 (Kafka 3.9, KRaft) | Брокер сообщений без ZooKeeper |
| Schema Registry | `confluentinc/cp-schema-registry` | 7.9.0 | Управление схемами Avro/Protobuf |
| ksqlDB Server | `confluentinc/cp-ksqldb-server` | 7.9.0 | Сервер SQL-обработки потоков |
| ksqlDB CLI | `confluentinc/cp-ksqldb-cli` | 7.9.0 | Интерактивный SQL-клиент |

---

## Требования

- Docker Engine >= 24.0
- Docker Compose >= 2.20
- Свободная RAM: минимум 6 GB (ksqlDB требователен к памяти)
- Свободные порты: 9092 (Kafka), 8081 (Schema Registry), 8088 (ksqlDB)

---

## Запуск лаборатории

### Шаг 1: Запустить все сервисы

```bash
cd labs/streams-ksqldb
docker compose up -d
```

### Шаг 2: Ожидать готовности всех сервисов

Запуск занимает 60-90 секунд из-за последовательных проверок здоровья.

```bash
# Проверить статус сервисов (все должны быть healthy)
docker compose ps

# Проверить ksqlDB server
curl http://localhost:8088/info

# Проверить Schema Registry
curl http://localhost:8081/subjects
```

Ожидаемый ответ `/info`:

```json
{"KsqlServerInfo": {"version": "7.9.0", "kafkaClusterId": "...", "ksqlServiceId": "streams-lab"}}
```

### Шаг 3: Подключиться к ksqlDB CLI

```bash
docker compose exec ksqldb-cli ksql http://ksqldb-server:8088
```

После подключения вы увидите приглашение:

```
ksql>
```

Проверить готовность (оба должны вернуть пустые списки):

```sql
SHOW STREAMS;
SHOW TABLES;
```

---

## Загрузка тестовых данных

Перед выполнением упражнений создайте топики и загрузите тестовые данные:

```bash
# Из директории labs/streams-ksqldb
bash exercises/seed-data.sh
```

Скрипт создаёт три топика:

| Топик | Партиции | Содержимое |
|-------|----------|-----------|
| `orders` | 3 | 15 заказов с полями order_id, customer_id, amount, product, timestamp |
| `page-views` | 3 | 30 просмотров с user_id, page, duration, timestamp (разные временные метки для windowing) |
| `users` | 3 | 5 профилей пользователей с ключом user_id |

---

## Упражнения

### Упражнение 01: Streams topology

Файл: `exercises/01_streams_topology.sh`

Изучение Kafka Streams топологии через ksqlDB:

1. Создание STREAM из топика `orders`
2. Создание фильтрованного STREAM через CSAS (persistent query)
3. Просмотр топологии через `EXPLAIN`
4. Чтение результатов из выходного топика
5. Завершение persistent query

Запуск:

```bash
bash exercises/01_streams_topology.sh
```

### Упражнение 02: ksqlDB queries — CSAS/CTAS, push/pull

Файл: `exercises/02_ksqldb_queries.sh`

Работа с основными паттернами ksqlDB:

1. Создание TABLE из топика `users`
2. KStream-KTable join через CSAS (обогащение заказов именами клиентов)
3. Push query для наблюдения обогащённых заказов в реальном времени
4. Материализация агрегации через CTAS (итоги заказов по клиентам)
5. Pull query — точечный lookup по customer_id

Запуск:

```bash
bash exercises/02_ksqldb_queries.sh
```

### Упражнение 03: Windowed aggregations

Файл: `exercises/03_windowed_aggregation.sh`

Оконные агрегации и сравнение типов окон:

1. Создание STREAM из топика `page-views` с event time через timestamp field
2. TUMBLING window (1 час) — подсчёт просмотров по пользователям
3. Push query для наблюдения windowed результатов
4. Pull query с window bounds
5. HOPPING window (1 час, advance 15 минут) для сравнения
6. Сравнение количества строк в tumbling vs hopping результатах

Запуск:

```bash
bash exercises/03_windowed_aggregation.sh
```

---

## Подключение к ksqlDB CLI вручную

Для интерактивной работы:

```bash
docker compose exec ksqldb-cli ksql http://ksqldb-server:8088
```

Полезные команды:

```sql
-- Список потоков
SHOW STREAMS;

-- Список таблиц
SHOW TABLES;

-- Активные persistent queries
SHOW QUERIES;

-- Детальное описание потока
DESCRIBE orders_stream EXTENDED;

-- Топология конкретного query
EXPLAIN <query_id>;

-- Остановить query
TERMINATE <query_id>;

-- Удалить поток
DROP STREAM IF EXISTS stream_name DELETE TOPIC;

-- Удалить таблицу
DROP TABLE IF EXISTS table_name DELETE TOPIC;
```

---

## Остановка лаборатории

```bash
# Остановить и удалить контейнеры + volumes (включая данные Kafka)
docker compose down -v
```

---

## Решение проблем

**ksqlDB не запускается (exit code 137):**
Недостаточно памяти. Выделите минимум 6 GB Docker Desktop. ksqlDB требователен: 3-4 GB для ksqlDB-server, 1-2 GB для Kafka.

**Ошибка при подключении CLI:**
Убедитесь, что ksqldb-server в статусе `healthy`: `docker compose ps`. ksqlDB-сервер стартует медленнее остальных — подождите 60-90 секунд.

**Топики не видны в ksqlDB:**
Запустите `seed-data.sh` перед выполнением упражнений. Проверьте создание топиков: `curl http://localhost:8088/v1/metadata/topics`.

**Schema Registry ошибки:**
Проверьте доступность: `curl http://localhost:8081/subjects`. Должен вернуть `[]`.

**Consumer lag растёт:**
Нормально при первом запуске — ksqlDB обрабатывает накопленные сообщения. Подождите несколько секунд.
