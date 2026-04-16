# Multi-DC и Design Patterns -- Docker Lab

Практический стенд для Модулей 11 и 12 курса Apache Kafka Deep-Dive.

Два независимых Kafka 4.0 KRaft-кластера, моделирующих два дата-центра (DC-1 Primary и DC-2 DR), соединённых через MirrorMaker 2. PostgreSQL для паттерна transactional outbox.

---

## Архитектура стенда

```
DC-1 (Primary)              DC-2 (DR)
kafka-dc1:9092   <---MM2--->  kafka-dc2:9092
                   (dc1->dc2)
                              (active-passive)

postgres-outbox:5432
(для упражнения 03)
```

Порты на хосте:
- `9092` -- Kafka DC-1 (Primary)
- `9094` -- Kafka DC-2 (DR, mapped to container port 9092)
- `5432` -- PostgreSQL

---

## Требования

- Docker Desktop 4.x или Docker Engine + Docker Compose Plugin
- Свободная оперативная память: не менее 4 ГБ для Docker
- Свободные порты: 9092, 9094, 5432

---

## Быстрый старт

```bash
# Запустить все сервисы в фоне
docker compose up -d

# Проверить статус сервисов (ожидать healthy для kafka-dc1, kafka-dc2, postgres-outbox)
docker compose ps

# Посмотреть логи MirrorMaker 2 в реальном времени
docker compose logs -f mirrormaker2

# Остановить стенд и удалить тома (полная очистка)
docker compose down -v
```

Первый запуск занимает 1-2 минуты: Kafka требует время для инициализации KRaft.

---

## Упражнения

### Упражнение 01: Репликация топиков через MirrorMaker 2

Цель: убедиться, что топики, созданные на DC-1, автоматически появляются на DC-2 с префиксом `dc1.`.

```bash
bash exercises/01_mm2_replication.sh
```

Что изучите:
- Как MM2 реплицирует топики между кластерами
- Соглашение об именовании при DefaultReplicationPolicy (префикс `dc1.`)
- Проверку успешной репликации

---

### Упражнение 02: Перевод consumer group offsets при failover

Цель: имитировать failover и убедиться, что consumer group на DC-2 продолжает с правильного офсета.

```bash
bash exercises/02_offset_translation.sh
```

Что изучите:
- Как `sync.group.offsets.enabled=true` автоматически синхронизирует офсеты
- Топик `dc1.checkpoints.internal` и его содержимое
- Почему consumer на DC-2 не начинает с начала после failover

---

### Упражнение 03: Паттерн transactional outbox

Цель: реализовать атомарную публикацию событий в Kafka через outbox-таблицу в PostgreSQL.

```bash
bash exercises/03_outbox_pattern.sh
```

Что изучите:
- Почему нельзя атомарно записать в БД и отправить в Kafka напрямую (dual write problem)
- Как outbox таблица решает эту проблему
- Реализацию polling publisher на bash

---

## Конфигурационные файлы

| Файл | Назначение |
|------|-----------|
| `config/mm2.properties` | MirrorMaker 2: active-passive конфигурация |
| `config/kafka-1.env` | Дополнительные настройки Kafka DC-1 |
| `config/kafka-2.env` | Дополнительные настройки Kafka DC-2 |
| `config/init.sql` | Инициализация PostgreSQL: таблицы orders и outbox |

---

## Полезные команды

```bash
# Список топиков DC-1
docker exec kafka-dc1 kafka-topics.sh --bootstrap-server localhost:9092 --list

# Список топиков DC-2 (реплицированные с префиксом dc1.)
docker exec kafka-dc2 kafka-topics.sh --bootstrap-server localhost:9092 --list

# Consumer groups на DC-2
docker exec kafka-dc2 kafka-consumer-groups.sh --bootstrap-server localhost:9092 --list

# Содержимое outbox в PostgreSQL
docker exec postgres-outbox psql -U admin -d orders -c "SELECT * FROM outbox ORDER BY created_at;"

# Логи конкретного сервиса
docker compose logs kafka-dc1
docker compose logs kafka-dc2
docker compose logs mirrormaker2
docker compose logs postgres-outbox
```

---

## Отладка

**MM2 не запускается:**
Убедитесь, что оба Kafka-кластера здоровы (`docker compose ps`). MM2 зависит от `condition: service_healthy` обоих брокеров.

**Топики не появляются на DC-2:**
MM2 требует 15-30 секунд после старта для инициализации коннекторов. Проверьте логи: `docker compose logs mirrormaker2 | grep -i error`.

**PostgreSQL не принимает подключения:**
Подождите завершения healthcheck (`docker compose ps` показывает `healthy` для postgres-outbox). Инициализация init.sql занимает несколько секунд.

---

## Очистка

```bash
# Остановить и удалить контейнеры + тома (начать с чистого листа)
docker compose down -v

# Удалить только контейнеры (сохранить данные в томах)
docker compose down
```

---

## Примечания о безопасности

Учётные данные PostgreSQL (`admin/admin`) предназначены исключительно для учебного стенда. Никогда не используйте упрощённые пароли в production-системах.

Kafka-кластеры в стенде работают без аутентификации (PLAINTEXT). В production всегда используйте SASL/SCRAM + TLS (Модуль 09 курса).
