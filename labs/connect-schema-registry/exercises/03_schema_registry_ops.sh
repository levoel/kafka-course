#!/usr/bin/env bash
# Упражнение 03: Операции Schema Registry
#
# Демонстрирует полный набор операций со схемами через REST API:
#   - Регистрация Avro схемы (POST /subjects/{subject}/versions)
#   - Получение схемы по ID (GET /schemas/ids/{id})
#   - Список subjects (GET /subjects)
#   - Управление режимами совместимости (GET/PUT /config/{subject})
#   - Проверка совместимости перед регистрацией (POST /compatibility/...)
#   - Эволюция схемы: добавление опционального поля (совместимое изменение)
#   - Попытка несовместимого изменения (удаление обязательного поля -> HTTP 409)
#
# Запуск: bash exercises/03_schema_registry_ops.sh
#
# Требования:
#   - docker compose up -d (schema-registry должен быть в статусе healthy)
#   - curl
#
# Ожидаемый результат:
#   Схема зарегистрирована с ID 1.
#   Совместимое изменение (добавление опционального поля) принято.
#   Несовместимое изменение (удаление обязательного поля) отклонено с HTTP 409.

set -euo pipefail

REGISTRY_URL="http://localhost:8081"
SUBJECT="orders-value"

echo "=== Упражнение 03: Операции Schema Registry ==="
echo ""

# --- Шаг 1: Регистрация Avro схемы ---
# POST /subjects/{subject}/versions
# subject = "orders-value" (TopicNameStrategy: {topic}-value, по умолчанию)
# Если схема уже зарегистрирована с таким же содержимым, вернётся существующий ID.
#
# Исходная схема Order: обязательные поля id (int), product (string), amount (double)
echo "Шаг 1: Регистрация Avro схемы для subject '${SUBJECT}'..."
REGISTER_RESPONSE=$(curl -s -o /tmp/sr_register.json -w "%{http_code}" \
    -X POST "${REGISTRY_URL}/subjects/${SUBJECT}/versions" \
    -H "Content-Type: application/vnd.schemaregistry.v1+json" \
    -d '{
  "schema": "{\"type\": \"record\", \"name\": \"Order\", \"namespace\": \"ru.kafka.lab\", \"fields\": [{\"name\": \"id\", \"type\": \"int\"}, {\"name\": \"product\", \"type\": \"string\"}, {\"name\": \"amount\", \"type\": \"double\"}]}"
}')

echo "  HTTP статус: ${REGISTER_RESPONSE}"
cat /tmp/sr_register.json | python3 -m json.tool
SCHEMA_ID=$(cat /tmp/sr_register.json | python3 -c "import json,sys; print(json.load(sys.stdin)['id'])")
echo "  Схема зарегистрирована. ID = ${SCHEMA_ID}"
echo ""

# --- Шаг 2: Получение схемы по ID ---
# GET /schemas/ids/{id}
# Десериализатор использует этот эндпоинт:
#   1. Читает 5-байтовый заголовок из сообщения (0x00 + 4-байтовый ID)
#   2. Запрашивает схему по ID
#   3. Декодирует Avro payload по полученной схеме
echo "Шаг 2: Получение схемы по ID ${SCHEMA_ID}..."
curl -s "${REGISTRY_URL}/schemas/ids/${SCHEMA_ID}" | python3 -m json.tool
echo ""

# --- Шаг 3: Список всех subjects ---
echo "Шаг 3: Список всех subjects в Schema Registry:"
curl -s "${REGISTRY_URL}/subjects"
echo ""
echo ""

# --- Шаг 4: Версии схемы для subject ---
echo "Шаг 4: Версии схемы для subject '${SUBJECT}':"
curl -s "${REGISTRY_URL}/subjects/${SUBJECT}/versions"
echo ""
echo ""

# --- Шаг 5: Текущий режим совместимости ---
# GET /config/{subject} — режим совместимости для конкретного subject
# GET /config — глобальный режим совместимости
# По умолчанию: BACKWARD (новая схема должна уметь читать старые данные)
echo "Шаг 5: Режим совместимости для subject '${SUBJECT}'..."
COMPAT_RESPONSE=$(curl -s -o /tmp/sr_compat.json -w "%{http_code}" \
    "${REGISTRY_URL}/config/${SUBJECT}")
echo "  HTTP статус: ${COMPAT_RESPONSE}"
if [ "${COMPAT_RESPONSE}" = "404" ]; then
    echo "  Subject-уровень не задан — используется глобальный режим:"
    curl -s "${REGISTRY_URL}/config" | python3 -m json.tool
else
    cat /tmp/sr_compat.json | python3 -m json.tool
fi
echo ""

# --- Шаг 6: Изменение режима совместимости на FORWARD ---
# FORWARD: старая схема должна уметь читать данные, записанные новой схемой.
# Это позволяет удалять поля из новой схемы (потребители со старой схемой их просто проигнорируют).
echo "Шаг 6: Изменение режима совместимости на FORWARD..."
curl -s -X PUT "${REGISTRY_URL}/config/${SUBJECT}" \
    -H "Content-Type: application/vnd.schemaregistry.v1+json" \
    -d '{"compatibility": "FORWARD"}' | python3 -m json.tool
echo ""

# --- Шаг 7: Проверка совместимости до регистрации ---
# POST /compatibility/subjects/{subject}/versions/{version}
# Проверяем, совместима ли новая схема с текущей (latest).
# Новая схема добавляет опциональное поле currency — совместимо с FORWARD.
echo "Шаг 7: Проверка совместимости (добавление опционального поля currency)..."
CHECK_RESPONSE=$(curl -s -o /tmp/sr_check.json -w "%{http_code}" \
    -X POST "${REGISTRY_URL}/compatibility/subjects/${SUBJECT}/versions/latest" \
    -H "Content-Type: application/vnd.schemaregistry.v1+json" \
    -d '{
  "schema": "{\"type\": \"record\", \"name\": \"Order\", \"namespace\": \"ru.kafka.lab\", \"fields\": [{\"name\": \"id\", \"type\": \"int\"}, {\"name\": \"product\", \"type\": \"string\"}, {\"name\": \"amount\", \"type\": \"double\"}, {\"name\": \"currency\", \"type\": [\"null\", \"string\"], \"default\": null}]}"
}')
echo "  HTTP статус: ${CHECK_RESPONSE}"
cat /tmp/sr_check.json | python3 -m json.tool
echo ""

# --- Шаг 8: Регистрация новой версии схемы (с опциональным полем) ---
# После успешной проверки совместимости регистрируем версию 2.
# Добавление nullable поля с default = null совместимо и с BACKWARD, и с FORWARD.
echo "Шаг 8: Регистрация версии 2 схемы (добавлено поле currency)..."
curl -s -X POST "${REGISTRY_URL}/subjects/${SUBJECT}/versions" \
    -H "Content-Type: application/vnd.schemaregistry.v1+json" \
    -d '{
  "schema": "{\"type\": \"record\", \"name\": \"Order\", \"namespace\": \"ru.kafka.lab\", \"fields\": [{\"name\": \"id\", \"type\": \"int\"}, {\"name\": \"product\", \"type\": \"string\"}, {\"name\": \"amount\", \"type\": \"double\"}, {\"name\": \"currency\", \"type\": [\"null\", \"string\"], \"default\": null}]}"
}' | python3 -m json.tool
echo ""
echo "  Текущие версии схемы:"
curl -s "${REGISTRY_URL}/subjects/${SUBJECT}/versions"
echo ""
echo ""

# --- Шаг 9: Попытка несовместимого изменения ---
# Удаление обязательного поля product — нарушает FORWARD совместимость:
# старая схема (v1) ожидает поле product, но новая схема его не содержит.
# Schema Registry вернёт HTTP 409 (Conflict) с описанием ошибки.
echo "Шаг 9: Попытка несовместимого изменения (удаление поля product)..."
INCOMPAT_STATUS=$(curl -s -o /tmp/sr_incompat.json -w "%{http_code}" \
    -X POST "${REGISTRY_URL}/subjects/${SUBJECT}/versions" \
    -H "Content-Type: application/vnd.schemaregistry.v1+json" \
    -d '{
  "schema": "{\"type\": \"record\", \"name\": \"Order\", \"namespace\": \"ru.kafka.lab\", \"fields\": [{\"name\": \"id\", \"type\": \"int\"}, {\"name\": \"amount\", \"type\": \"double\"}]}"
}')
echo "  HTTP статус: ${INCOMPAT_STATUS}"
cat /tmp/sr_incompat.json | python3 -m json.tool
if [ "${INCOMPAT_STATUS}" = "409" ]; then
    echo "  Несовместимое изменение отклонено (HTTP 409) — ожидаемо."
else
    echo "  Предупреждение: ожидался HTTP 409, получен ${INCOMPAT_STATUS}."
fi
echo ""

# --- Шаг 10: Восстановление режима BACKWARD ---
# Возвращаем глобальный режим совместимости BACKWARD как более строгий.
echo "Шаг 10: Восстановление режима совместимости BACKWARD для subject..."
curl -s -X PUT "${REGISTRY_URL}/config/${SUBJECT}" \
    -H "Content-Type: application/vnd.schemaregistry.v1+json" \
    -d '{"compatibility": "BACKWARD"}' | python3 -m json.tool
echo ""

# --- Шаг 11: Итоговое состояние Schema Registry ---
echo "Шаг 11: Итоговое состояние:"
echo "  Subjects:"
curl -s "${REGISTRY_URL}/subjects"
echo ""
echo "  Версии схемы ${SUBJECT}:"
curl -s "${REGISTRY_URL}/subjects/${SUBJECT}/versions"
echo ""
echo ""

echo "=== Итог ==="
echo "Schema Registry управляет версиями схем и проверяет совместимость."
echo ""
echo "Режимы совместимости:"
echo "  BACKWARD        — новая схема читает старые данные (по умолчанию)"
echo "  FORWARD         — старая схема читает новые данные"
echo "  FULL            — оба направления одновременно"
echo "  NONE            — без ограничений (только для разработки)"
echo "  *_TRANSITIVE    — то же, но проверяется против всех версий, а не только последней"
echo ""
echo "HTTP 409 означает нарушение условий совместимости — регистрация отклонена."
echo "Используйте POST /compatibility/... для предварительной проверки перед регистрацией."
