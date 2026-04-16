# Лабораторная работа: Kafka Connect + Schema Registry

Практическая среда для изучения Kafka Connect в распределённом режиме и Confluent Schema Registry 7.9.

---

## Что включено

| Сервис | Образ | Порт | Назначение |
|--------|-------|------|-----------|
| kafka | apache/kafka:4.0.0 | 9092 | Брокер Kafka 4.0 в режиме KRaft (без ZooKeeper) |
| schema-registry | confluentinc/cp-schema-registry:7.9.0 | 8081 | Confluent Schema Registry — хранилище Avro/Protobuf/JSON Schema |
| connect | confluentinc/cp-kafka-connect:7.9.0 | 8083 | Connect worker в распределённом режиме — REST API управления коннекторами |

Режим KRaft — единственный поддерживаемый в Kafka 4.0+. ZooKeeper не используется.

---

## Требования

- Docker 24+ и Docker Compose v2
- Минимум 4 GB оперативной памяти для трёх контейнеров
- Свободные порты: 9092, 8081, 8083
- curl и python3 (для упражнений 02 и 03)

---

## Запуск

```bash
# Создать директорию для тестовых данных (монтируется в контейнер connect)
mkdir -p test-data

# Запустить все сервисы в фоновом режиме
docker compose up -d

# Следить за логами до полной готовности (займёт 1-2 минуты)
docker compose logs -f
```

Kafka Connect стартует медленнее всего — он ждёт, пока kafka и schema-registry пройдут healthcheck. Нормальное время готовности: 60-90 секунд.

---

## Проверка готовности

Выполните следующие команды, чтобы убедиться, что все три сервиса работают:

```bash
# Connect REST API — пустой список коннекторов означает, что worker готов
curl http://localhost:8083/connectors
# Ожидаемый результат: []

# Schema Registry — пустой список subjects означает, что реестр готов
curl http://localhost:8081/subjects
# Ожидаемый результат: []

# Статус Connect worker
curl http://localhost:8083/
# Ожидаемый результат: JSON с версией и commit hash

# Список доступных плагинов коннекторов
curl http://localhost:8083/connector-plugins | python3 -m json.tool | head -30
```

---

## Упражнения

### 01: FileSource коннектор

Файл: `exercises/01_file_source_connector.sh`

Демонстрирует:
- Создание тестового файла в монтированной директории
- Развёртывание FileStream Source коннектора через REST API
- Проверку статуса коннектора и задач
- Чтение сообщений из топика, которые создал коннектор
- Добавление новых строк в исходный файл и наблюдение за новыми сообщениями
- Удаление коннектора

Запуск:
```bash
bash exercises/01_file_source_connector.sh
```

Ожидаемый результат: строки из `test-data/input.txt` появляются как отдельные сообщения в топике `file-events`.

---

### 02: JDBC Sink с SMT InsertField

Файл: `exercises/02_jdbc_sink_with_smt.sh`

Демонстрирует:
- Продюсирование тестовых записей в топик
- Развёртывание JDBC Sink коннектора с трансформацией SMT InsertField
- Проверку, что SMT добавил поле `processed_at` к каждой записи
- Просмотр данных в SQLite через sqlite3

Запуск:
```bash
bash exercises/02_jdbc_sink_with_smt.sh
```

Ожидаемый результат: записи в таблице `file-events` базы данных SQLite с добавленным полем `processed_at`.

---

### 03: Операции Schema Registry

Файл: `exercises/03_schema_registry_ops.sh`

Демонстрирует:
- Регистрацию Avro схемы через REST API
- Получение схемы по ID (используется десериализаторами)
- Список всех subjects
- Управление режимами совместимости (BACKWARD / FORWARD / FULL / NONE)
- Проверку совместимости перед регистрацией новой версии
- Эволюцию схемы: добавление опционального поля (совместимое изменение)
- Попытку несовместимого изменения — удаление обязательного поля (ошибка 409)

Запуск:
```bash
bash exercises/03_schema_registry_ops.sh
```

Ожидаемый результат: схема зарегистрирована с ID, совместимое изменение принято, несовместимое изменение отклонено с HTTP 409.

---

## Архитектура взаимодействия

```
Внешний источник
    |
    v
FileStream Source Connector
    |  (FileStreamSourceConnector)
    |  читает строки из /tmp/test-data/input.txt
    v
Kafka (kafka:9092)
    |  топик: file-events
    v
JDBC Sink Connector
    |  (JdbcSinkConnector + InsertField SMT)
    |  записывает строки в /tmp/test-data/output.db
    v
SQLite база данных

Schema Registry (http://schema-registry:8081)
    ^
    |  Connect Avro converter регистрирует и получает схемы
    |
Connect Worker (http://localhost:8083)
```

Пять байт перед каждым Avro-сообщением: `0x00` (magic byte) + 4 байта ID схемы (big-endian int32).

---

## Полезные команды

```bash
# Список всех коннекторов
curl http://localhost:8083/connectors

# Статус конкретного коннектора
curl http://localhost:8083/connectors/file-source-demo/status | python3 -m json.tool

# Перезапуск упавшего коннектора
curl -X POST http://localhost:8083/connectors/file-source-demo/restart

# Пауза и возобновление
curl -X PUT http://localhost:8083/connectors/file-source-demo/pause
curl -X PUT http://localhost:8083/connectors/file-source-demo/resume

# Список subjects в Schema Registry
curl http://localhost:8081/subjects

# Получить схему по ID
curl http://localhost:8081/schemas/ids/1

# Глобальный режим совместимости
curl http://localhost:8081/config
```

---

## Остановка

```bash
# Остановить контейнеры и удалить volumes (брокер, схемы и коннекторы будут сброшены)
docker compose down -v

# Остановить контейнеры без удаления volumes (данные сохранятся)
docker compose down
```

---

## Решение проблем

**Connect worker не стартует:**
```bash
docker compose logs connect | tail -50
```
Убедитесь, что kafka и schema-registry прошли healthcheck перед стартом connect.

**Коннектор в статусе FAILED:**
```bash
curl http://localhost:8083/connectors/{name}/status | python3 -m json.tool
```
Поле `tasks[0].trace` содержит трассировку ошибки.

**Schema Registry недоступен:**
```bash
docker compose logs schema-registry | tail -30
```
Убедитесь, что брокер Kafka доступен по адресу `kafka:9092`.

**Директория test-data не существует:**
```bash
mkdir -p test-data
docker compose restart connect
```
Connect монтирует `./test-data` в `/tmp/test-data`. Если директории не было при первом запуске, контейнер не сможет записать файлы.
