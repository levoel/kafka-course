#!/usr/bin/env bash
# Упражнение 03: Стек мониторинга Prometheus + Grafana
#
# Цель: изучить конвейер сбора метрик Kafka через JMX Exporter + Prometheus + Grafana.
# Вы проверите, что Prometheus собирает метрики брокера,
# сделаете запросы к ключевым метрикам через PromQL,
# сгенерируете нагрузку и увидите изменение метрик в реальном времени,
# создадите простой дашборд в Grafana.
#
# Конвейер метрик:
#   Kafka JVM --[JMX MBeans]--> JMX Exporter Java Agent (порт 9404)
#     --[HTTP /metrics]--> Prometheus (scrape каждые 10 секунд)
#       --[PromQL API]--> Grafana
#
# Запуск: bash exercises/03_monitoring_stack.sh
# Требования: docker compose up -d, все сервисы healthy
#
# Ожидаемый результат:
#   Шаг 1: Prometheus target kafka-broker в состоянии UP
#   Шаг 2: PromQL возвращает метрики (некоторые могут быть 0 до генерации нагрузки)
#   Шаг 4: kafka_server_brokertopicmetrics_messagesinpersec показывает ненулевое значение
#   Шаг 5: Grafana Explore отображает метрики (инструкции для браузера)

set -euo pipefail

KAFKA_CONTAINER="kafka-security-lab"
TOPIC="secure-topic"

echo "=== Упражнение 03: Стек мониторинга Prometheus + Grafana ==="
echo ""

# --- Шаг 1: Проверка состояния Prometheus targets ---
# Prometheus опрашивает /metrics эндпоинт JMX Exporter на kafka:9404.
# Состояние "up" означает: Prometheus успешно получил метрики от брокера.
# "down" -- JMX Exporter недоступен (брокер не запустился, агент не загружен).
echo "=== Шаг 1: Проверка состояния Prometheus targets ==="
echo ""

echo "Запрос состояния targets через Prometheus HTTP API..."
TARGETS_RESPONSE=$(curl -s "http://localhost:9090/api/v1/targets" 2>/dev/null || echo "ERROR")

if [ "${TARGETS_RESPONSE}" = "ERROR" ]; then
  echo "ОШИБКА: Prometheus недоступен на http://localhost:9090"
  echo "Убедитесь, что стенд запущен: docker compose ps"
  exit 1
fi

echo "${TARGETS_RESPONSE}" | python3 -c "
import sys, json
data = json.load(sys.stdin)
targets = data.get('data', {}).get('activeTargets', [])
print(f'Количество активных targets: {len(targets)}')
for t in targets:
    job = t.get('labels', {}).get('job', '?')
    state = t.get('health', '?')
    url = t.get('scrapeUrl', '?')
    last_error = t.get('lastError', '')
    print(f'  job={job:20s} state={state:5s} url={url}')
    if last_error:
        print(f'    ошибка: {last_error}')
"

echo ""
echo "Ожидается: kafka-broker -> state=up, prometheus -> state=up"
echo ""
echo "Если kafka-broker в состоянии DOWN:"
echo "  - Подождите 30 секунд после старта Kafka"
echo "  - Проверьте: docker compose exec kafka-security-lab curl http://localhost:9404/metrics | head -3"
echo ""

# --- Шаг 2: Запрос ключевых метрик через Prometheus API ---
# PromQL (Prometheus Query Language) позволяет выполнять запросы к метрикам.
# Здесь мы используем HTTP API /api/v1/query для автоматизированной проверки.
# В Grafana те же запросы выполняются через интерфейс Explore.
echo "=== Шаг 2: Запрос ключевых метрик (PromQL) ==="
echo ""

# Функция для запроса одной метрики
query_metric() {
  local metric_name="$1"
  local description="$2"

  echo "Метрика: ${description}"
  echo "  PromQL: ${metric_name}"

  RESULT=$(curl -s "http://localhost:9090/api/v1/query?query=${metric_name}" 2>/dev/null || echo "ERROR")

  if [ "${RESULT}" = "ERROR" ]; then
    echo "  ОШИБКА: не удалось получить ответ от Prometheus"
    return
  fi

  VALUE=$(echo "${RESULT}" | python3 -c "
import sys, json
data = json.load(sys.stdin)
results = data.get('data', {}).get('result', [])
if results:
    for r in results[:3]:
        labels = r.get('metric', {})
        val = r.get('value', ['', '?'])[1]
        label_str = ', '.join(f'{k}={v}' for k,v in labels.items() if k != '__name__')
        if label_str:
            print(f'  Значение: {val} ({label_str})')
        else:
            print(f'  Значение: {val}')
else:
    print('  Нет данных (метрика ещё не собрана или равна 0)')
" 2>/dev/null || echo "  Ошибка разбора ответа")

  echo "${VALUE}"
  echo ""
}

# UnderReplicatedPartitions -- критическая метрика репликации
query_metric \
  "kafka_server_replicamanager_underreplicatedpartitions" \
  "UnderReplicatedPartitions (норма: 0)"

# ActiveControllerCount -- счётчик KRaft контроллера
query_metric \
  "kafka_controller_kafkacontroller_activecontrollercount" \
  "ActiveControllerCount (норма: 1)"

# BrokerState -- состояние брокера
query_metric \
  "kafka_server_kafkaserver_brokerstate" \
  "BrokerState (4 = RUNNING)"

# RequestHandlerAvgIdlePercent -- загрузка I/O потоков
query_metric \
  "kafka_server_kafkarequesthandlerpool_requesthandleravgidlepercent" \
  "RequestHandlerAvgIdlePercent (норма > 0.30)"

# MessagesInPerSec (может быть 0 до генерации нагрузки)
query_metric \
  "kafka_server_brokertopicmetrics_messagesinpersec" \
  "MessagesInPerSec (входящих сообщений/с)"

# --- Шаг 3: Просмотр сырых метрик от JMX Exporter ---
# /metrics эндпоинт JMX Exporter возвращает все метрики в формате Prometheus.
# Это помогает убедиться, что JMX Exporter работает и правила из kafka-broker.yml применены.
echo "=== Шаг 3: Первые 20 строк сырых метрик от JMX Exporter ==="
echo ""

RAW_METRICS=$(docker compose exec "${KAFKA_CONTAINER}" \
  curl -s "http://localhost:9404/metrics" 2>/dev/null | \
  grep -v "^#" | head -20 || echo "ERROR")

if [ "${RAW_METRICS}" = "ERROR" ]; then
  echo "ОШИБКА: JMX Exporter недоступен на порту 9404"
  echo "Проверьте: docker compose logs kafka-security-lab | grep -i javaagent"
else
  echo "${RAW_METRICS}"
fi

echo ""
echo "(Это те же метрики, которые Prometheus собирает каждые 10 секунд.)"
echo ""

# --- Шаг 4: Генерация нагрузки и наблюдение метрик ---
# Производим 500 сообщений для создания видимой нагрузки на брокер.
# После этого MessagesInPerSec должен показать ненулевое значение.
# Примечание: метрика OneMinuteRate -- скользящее среднее за минуту,
# поэтому значение нарастает постепенно (не мгновенно).
echo "=== Шаг 4: Генерация нагрузки (500 сообщений) ==="
echo ""

echo "Создание топика если не существует..."
docker compose exec "${KAFKA_CONTAINER}" kafka-topics.sh \
  --bootstrap-server localhost:9092 \
  --create \
  --topic "${TOPIC}" \
  --partitions 3 \
  --replication-factor 1 \
  --if-not-exists 2>/dev/null || true

echo ""
echo "Запись 500 сообщений через PLAINTEXT listener..."

docker compose exec "${KAFKA_CONTAINER}" bash -c "
  for i in \$(seq 1 500); do
    echo \"load-test-message-\$i\"
  done | kafka-console-producer.sh \
    --bootstrap-server localhost:9092 \
    --topic ${TOPIC}
"

echo ""
echo "500 сообщений записаны."
echo ""
echo "Ожидание 15 секунд (интервал scrape Prometheus)..."
sleep 15
echo ""

echo "Повторный запрос MessagesInPerSec..."
query_metric \
  "kafka_server_brokertopicmetrics_messagesinpersec" \
  "MessagesInPerSec после нагрузки"

echo "Запрос BytesInPerSec..."
query_metric \
  "kafka_server_brokertopicmetrics_bytesInPerSec_rate" \
  "BytesInPerSec (входящих байт/с)"

# --- Шаг 5: Примеры PromQL для Grafana ---
# Эти запросы можно вставить в Grafana Explore или использовать в панелях дашборда.
echo "=== Шаг 5: Примеры PromQL для Grafana ==="
echo ""
echo "Откройте в браузере: http://localhost:3000"
echo "Перейдите в: Explore -> выберите источник Prometheus -> введите запрос"
echo ""
echo "Рекомендуемые запросы:"
echo ""
echo "  1. Количество входящих сообщений в секунду (скользящее среднее за 5 минут):"
echo "     rate(kafka_server_brokertopicmetrics_messagesinpersec[5m])"
echo ""
echo "  2. Среднее время простоя I/O потоков:"
echo "     avg(kafka_server_kafkarequesthandlerpool_requesthandleravgidlepercent)"
echo ""
echo "  3. Количество under-replicated партиций (алертовая метрика):"
echo "     kafka_server_replicamanager_underreplicatedpartitions"
echo ""
echo "  4. Активный KRaft контроллер (должен быть ровно 1):"
echo "     kafka_controller_kafkacontroller_activecontrollercount"
echo ""
echo "  5. p99 latency Produce-запросов (мс):"
echo "     kafka_network_requestmetrics_totaltimems_p99{request=\"Produce\"}"
echo ""

# --- Шаг 6: Создание дашборда в Grafana (инструкции) ---
# Grafana API позволяет создавать дашборды программно.
# Здесь мы создаём простой дашборд через API с тремя панелями.
echo "=== Шаг 6: Создание простого дашборда через Grafana API ==="
echo ""

echo "Создание дашборда 'Kafka Security Lab' с 3 панелями..."

DASHBOARD_PAYLOAD='{
  "dashboard": {
    "title": "Kafka Security Lab",
    "tags": ["kafka", "security-lab"],
    "timezone": "browser",
    "panels": [
      {
        "id": 1,
        "title": "Messages In Per Sec",
        "type": "timeseries",
        "gridPos": {"h": 8, "w": 8, "x": 0, "y": 0},
        "targets": [{
          "expr": "kafka_server_brokertopicmetrics_messagesinpersec",
          "legendFormat": "msg/s",
          "datasource": {"type": "prometheus", "uid": "prometheus"}
        }]
      },
      {
        "id": 2,
        "title": "Request Handler Idle Percent",
        "type": "timeseries",
        "gridPos": {"h": 8, "w": 8, "x": 8, "y": 0},
        "targets": [{
          "expr": "kafka_server_kafkarequesthandlerpool_requesthandleravgidlepercent",
          "legendFormat": "idle %",
          "datasource": {"type": "prometheus", "uid": "prometheus"}
        }]
      },
      {
        "id": 3,
        "title": "Under Replicated Partitions",
        "type": "stat",
        "gridPos": {"h": 8, "w": 8, "x": 16, "y": 0},
        "targets": [{
          "expr": "kafka_server_replicamanager_underreplicatedpartitions",
          "legendFormat": "under-replicated",
          "datasource": {"type": "prometheus", "uid": "prometheus"}
        }],
        "options": {"colorMode": "background"},
        "fieldConfig": {
          "defaults": {
            "thresholds": {
              "steps": [
                {"color": "green", "value": null},
                {"color": "red", "value": 1}
              ]
            }
          }
        }
      }
    ],
    "schemaVersion": 36,
    "version": 1
  },
  "overwrite": true,
  "folderId": 0
}'

GRAFANA_RESPONSE=$(curl -s -X POST \
  -H "Content-Type: application/json" \
  -u "admin:admin" \
  "http://localhost:3000/api/dashboards/db" \
  -d "${DASHBOARD_PAYLOAD}" 2>/dev/null || echo "ERROR")

if [ "${GRAFANA_RESPONSE}" = "ERROR" ]; then
  echo "ОШИБКА: Grafana недоступна на http://localhost:3000"
else
  DASHBOARD_URL=$(echo "${GRAFANA_RESPONSE}" | python3 -c "
import sys, json
data = json.load(sys.stdin)
url = data.get('url', '')
status = data.get('status', 'error')
print(f'status={status}  url={url}')
" 2>/dev/null || echo "Ошибка разбора ответа")
  echo "Grafana API ответ: ${DASHBOARD_URL}"
  echo ""
  echo "Откройте дашборд: http://localhost:3000${GRAFANA_RESPONSE}"
  echo "Или: http://localhost:3000 -> Dashboards -> 'Kafka Security Lab'"
fi

echo ""

# --- Шаг 7: Проверка полноты метрик ---
echo "=== Шаг 7: Итоговая проверка метрик ==="
echo ""

echo "Список всех Kafka-метрик в Prometheus:"
METRIC_COUNT=$(curl -s "http://localhost:9090/api/v1/label/__name__/values" 2>/dev/null | \
  python3 -c "
import sys, json
data = json.load(sys.stdin)
names = [n for n in data.get('data', []) if n.startswith('kafka_')]
print(f'Количество Kafka-метрик: {len(names)}')
for n in sorted(names)[:15]:
    print(f'  {n}')
if len(names) > 15:
    print(f'  ... и ещё {len(names) - 15} метрик')
" 2>/dev/null || echo "Ошибка получения метрик")

echo "${METRIC_COUNT}"
echo ""

echo "=== Итог упражнения 03 ==="
echo ""
echo "Вы изучили:"
echo "  1. Конвейер метрик: Kafka JMX -> JMX Exporter -> Prometheus -> Grafana"
echo "  2. Проверку состояния Prometheus targets через API"
echo "  3. Запрос ключевых метрик: UnderReplicatedPartitions, MessagesInPerSec,"
echo "     RequestHandlerAvgIdlePercent, ActiveControllerCount, BrokerState"
echo "  4. Генерацию нагрузки и наблюдение изменения метрик"
echo "  5. PromQL: rate(), avg(), пороговые алерты"
echo "  6. Создание дашборда в Grafana через API"
echo ""
echo "Рекомендуемые следующие шаги:"
echo "  - Импортировать готовый дашборд Kafka Overview (ID 7589) из grafana.com"
echo "  - Настроить Grafana Alert Rule на UnderReplicatedPartitions > 0"
echo "  - Изучить kafka-exporter (danielqsj/kafka-exporter) для consumer lag метрик"
