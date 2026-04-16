# Лабораторный стенд: Безопасность и мониторинг Kafka

Практический стенд для изучения SASL/SCRAM-аутентификации, ACL-авторизации
и стека мониторинга Prometheus + Grafana на базе Kafka 4.0 (режим KRaft, без ZooKeeper).

---

## Что включено

| Компонент | Образ | Порт | Описание |
|-----------|-------|------|----------|
| Kafka 4.0 (KRaft) | `apache/kafka:4.0.0` | 9092, 9094 | Брокер с SASL/SCRAM-SHA-256 |
| JMX Exporter | Java-агент 1.1.0 | 9404 | Экспорт JMX-метрик Kafka в формат Prometheus |
| Prometheus | `prom/prometheus:latest` | 9090 | Сбор и хранение метрик |
| Grafana | `grafana/grafana:latest` | 3000 | Визуализация метрик и алерты |

**Listeners Kafka:**
- `PLAINTEXT://kafka:9092` -- без аутентификации, для административных операций
  (`kafka-topics.sh`, `kafka-configs.sh`, `kafka-acls.sh`)
- `SASL_PLAINTEXT://kafka:9094` -- с аутентификацией SASL/SCRAM-SHA-256, для клиентов
  (producer, consumer в упражнениях)

**Авторизатор:** `org.apache.kafka.metadata.authorizer.StandardAuthorizer` (KRaft, Kafka 4.0).
ACL-правила хранятся в метаданных KRaft, а не в ZooKeeper.

---

## Требования

- Docker 24+ и Docker Compose v2
- Не менее 4 GB RAM доступной для Docker
- Свободные порты: 9092, 9094, 9404, 9090, 3000
- Доступ в интернет при первом запуске (загрузка JMX Exporter JAR)

---

## Запуск стенда

```bash
# Перейдите в директорию лабораторного стенда
cd labs/security-monitoring

# Запустите все сервисы в фоновом режиме
docker compose up -d

# Наблюдайте за запуском (особенно jmx-exporter-init)
docker compose logs -f jmx-exporter-init
```

При первом запуске `jmx-exporter-init` загружает JAR-файл (~800 KB) в Docker-том.
Это выполняется один раз -- при повторном запуске JAR уже присутствует в томе.

---

## Проверка готовности

### 1. Все сервисы запущены

```bash
docker compose ps
```

Ожидаемый результат: все сервисы в состоянии `Up (healthy)`.
Сервис `jmx-exporter-init` должен быть в состоянии `Exited (0)`.

### 2. Kafka доступна

```bash
# Через PLAINTEXT listener (без аутентификации)
docker compose exec kafka kafka-topics.sh \
  --bootstrap-server localhost:9092 \
  --list
```

Ожидаемый результат: пустой список (топики ещё не созданы) без ошибок.

### 3. Prometheus собирает метрики

Откройте в браузере: [http://localhost:9090/targets](http://localhost:9090/targets)

Ожидаемый результат:
- Цель `kafka-broker` (kafka:9404) -- состояние `UP`
- Цель `prometheus` (localhost:9090) -- состояние `UP`

Если `kafka-broker` в состоянии `DOWN` -- подождите 30 секунд после старта Kafka и обновите страницу.

### 4. Grafana доступна

Откройте в браузере: [http://localhost:3000](http://localhost:3000)

Учётные данные: `admin` / `admin`

Перейдите в **Connections > Data sources** -- источник данных `Prometheus` должен быть
настроен автоматически и показывать статус `Data source connected`.

---

## Упражнения

### Упражнение 01: SASL/SCRAM аутентификация

Файл: `exercises/01_sasl_scram_auth.sh`

Что изучите:
- Создание учётных записей SCRAM-SHA-256 без перезапуска брокера
- Подключение клиентов с аутентификацией
- Ротация пароля без остановки Kafka
- Поведение при неверных учётных данных

```bash
bash exercises/01_sasl_scram_auth.sh
```

### Упражнение 02: ACL-авторизация

Файл: `exercises/02_acl_authorization.sh`

Что изучите:
- Создание ACL-правил для пользователей alice и bob
- LITERAL и PREFIXED паттерны ресурсов
- Проверка разрешённых и запрещённых операций
- Минимальные ACL для producer и consumer

```bash
bash exercises/02_acl_authorization.sh
```

### Упражнение 03: Стек мониторинга

Файл: `exercises/03_monitoring_stack.sh`

Что изучите:
- Проверка Prometheus targets через API
- Запросы ключевых Kafka-метрик через PromQL
- Генерация нагрузки и наблюдение метрик
- Построение дашборда в Grafana

```bash
bash exercises/03_monitoring_stack.sh
```

---

## Ожидаемые результаты

| Упражнение | Ключевой результат |
|-----------|-------------------|
| 01 | `kafka-console-producer` успешно записывает с alice/alice-secret; `AuthenticationException` при неверном пароле |
| 02 | `kafka-acls.sh --list` показывает созданные правила; bob не может писать в топик (только читать) |
| 03 | Prometheus target kafka-broker UP; PromQL возвращает ненулевые метрики после генерации нагрузки |

---

## Остановка стенда

```bash
# Остановить и удалить контейнеры + тома с данными
docker compose down -v

# Остановить без удаления томов (данные сохраняются)
docker compose down
```

Флаг `-v` удаляет тома `kafka-data`, `jmx-exporter-jar`, `prometheus-data`, `grafana-data`.
При следующем запуске JMX Exporter JAR будет загружен повторно.

---

## Решение проблем

### JMX Exporter JAR не найден

Симптом: Kafka не запускается, в логах ошибка `javaagent path does not exist`.

Причина: `jmx-exporter-init` не завершил загрузку до старта Kafka.

Решение:
```bash
# Дождитесь завершения init-контейнера
docker compose logs jmx-exporter-init

# Перезапустите Kafka после успешного завершения init
docker compose restart kafka
```

### Prometheus не видит Kafka (target DOWN)

Симптом: в http://localhost:9090/targets цель `kafka-broker` в состоянии `DOWN`.

Причина: Kafka ещё не запустилась или JMX Exporter не инициализирован.

Решение:
```bash
# Проверьте, слушает ли JMX Exporter на порту 9404
docker compose exec kafka curl -s http://localhost:9404/metrics | head -5

# Если нет вывода -- проверьте KAFKA_OPTS в логах Kafka
docker compose logs kafka | grep -i "javaagent"
```

### Grafana: соединение с Prometheus отклонено

Симптом: в Grafana Explore ошибка `connection refused`.

Причина: Grafana запустилась раньше Prometheus.

Решение:
```bash
docker compose restart grafana
```

### Ошибка AuthenticationException при правильном пароле

Симптом: клиент использует `localhost:9094`, но получает `AuthenticationException`.

Причина: клиент подключается к SASL_PLAINTEXT listener, но учётная запись SCRAM ещё
не создана (команда `kafka-configs.sh` не выполнена).

Решение: Сначала выполните Шаг 1 в упражнении 01 для создания учётных записей.
