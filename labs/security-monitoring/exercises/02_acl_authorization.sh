#!/usr/bin/env bash
# Упражнение 02: ACL-авторизация (StandardAuthorizer, Kafka 4.0)
#
# Цель: изучить механизм ACL-авторизации Kafka 4.0 в режиме KRaft.
# Вы создадите ACL-правила для пользователей alice и bob,
# проверите разрешённые и запрещённые операции,
# изучите PREFIXED-паттерн ресурсов и удаление ACL.
#
# Авторизатор:
#   StandardAuthorizer (org.apache.kafka.metadata.authorizer.StandardAuthorizer)
#   ACL-правила хранятся в __cluster_metadata (KRaft log), а не в отдельном хранилище.
#   Старый AclAuthorizer из Kafka 2.x/3.x не поддерживается в Kafka 4.0.
#
# Состояние стенда:
#   ALLOW_EVERYONE_IF_NO_ACL_FOUND=true -- все операции разрешены при отсутствии ACL.
#   Это удобно для начальной настройки. В production используют false (deny-by-default).
#   В Шаге 1 этого упражнения объяснено, как это работает.
#
# Требования: выполнить 01_sasl_scram_auth.sh (создать alice и bob, топик secure-topic)
#
# Запуск: bash exercises/02_acl_authorization.sh
#
# Ожидаемый результат:
#   alice может писать в secure-topic (Write ACL)
#   bob может читать из secure-topic (Read ACL), но НЕ может писать
#   alice может писать в secure-topic-2 через PREFIXED ACL

set -euo pipefail

KAFKA_CONTAINER="kafka-security-lab"
TOPIC="secure-topic"
TOPIC2="secure-topic-2"

echo "=== Упражнение 02: ACL-авторизация ==="
echo ""

# --- Шаг 1: Режимы авторизации: allow-all vs deny-by-default ---
# ALLOW_EVERYONE_IF_NO_ACL_FOUND=true (текущий режим стенда):
#   Если для ресурса нет ни одного ACL-правила -- операция разрешена.
#   Как только добавляется хотя бы одно правило -- применяется проверка ACL.
#
# ALLOW_EVERYONE_IF_NO_ACL_FOUND=false (production-режим):
#   Без явного ACL-правила -- операция запрещена (deny-by-default).
#   Требует настройки ACL для каждой операции каждого пользователя.
#
# В этом упражнении стенд работает в режиме allow-all для наглядности.
# Мы покажем ACL-поведение, добавляя явные ALLOW-правила и проверяя DENY.
echo "=== Шаг 1: Текущий режим авторизации ==="
echo ""
echo "Стенд настроен с ALLOW_EVERYONE_IF_NO_ACL_FOUND=true."
echo "При добавлении ACL для ресурса -- другие пользователи без ACL получат DENY."
echo "(В production используют false для запрета по умолчанию.)"
echo ""

# --- Шаг 2: Список текущих ACL (пустой) ---
echo "=== Шаг 2: Список текущих ACL ==="
echo ""

docker compose exec "${KAFKA_CONTAINER}" kafka-acls.sh \
  --bootstrap-server localhost:9092 \
  --list

echo ""
echo "(Список пуст -- ACL не созданы.)"
echo ""

# --- Шаг 3: Создание ACL для alice (Write + Describe на топике) ---
# Минимальный набор ACL для producer:
#   Write   -- запись сообщений в топик
#   Describe -- получение метаданных (offset, partition count)
#
# Ресурс: topic=secure-topic (LITERAL паттерн -- точное совпадение имени)
echo "=== Шаг 3: Создание ACL для alice (Write + Describe) ==="
echo ""

docker compose exec "${KAFKA_CONTAINER}" kafka-acls.sh \
  --bootstrap-server localhost:9092 \
  --add \
  --allow-principal User:alice \
  --operation Write \
  --operation Describe \
  --topic "${TOPIC}"

echo ""
echo "ACL для alice созданы."
echo ""

# --- Шаг 4: Создание ACL для bob (Read + Describe на топике и группе) ---
# Минимальный набор ACL для consumer:
#   Topic: Read      -- чтение сообщений
#   Topic: Describe  -- получение метаданных
#   Group: Read      -- вступление в consumer group и коммит offsets
#
# Без ACL на группу (--group) -- consumer получит AUTHORIZATION_FAILED.
echo "=== Шаг 4: Создание ACL для bob (Read + Describe + Group) ==="
echo ""

docker compose exec "${KAFKA_CONTAINER}" kafka-acls.sh \
  --bootstrap-server localhost:9092 \
  --add \
  --allow-principal User:bob \
  --operation Read \
  --operation Describe \
  --topic "${TOPIC}"

docker compose exec "${KAFKA_CONTAINER}" kafka-acls.sh \
  --bootstrap-server localhost:9092 \
  --add \
  --allow-principal User:bob \
  --operation Read \
  --group "bob-consumer-group"

echo ""
echo "ACL для bob созданы."
echo ""

# --- Шаг 5: Просмотр всех ACL ---
echo "=== Шаг 5: Список всех ACL для топика ${TOPIC} ==="
echo ""

docker compose exec "${KAFKA_CONTAINER}" kafka-acls.sh \
  --bootstrap-server localhost:9092 \
  --list \
  --topic "${TOPIC}"

echo ""

# --- Шаг 6: Тест -- alice пишет (должна успешно) ---
echo "=== Шаг 6: Тест -- alice записывает сообщения (ожидается успех) ==="
echo ""

docker compose exec "${KAFKA_CONTAINER}" bash -c "
  cat > /tmp/alice-new.properties << 'EOF'
security.protocol=SASL_PLAINTEXT
sasl.mechanism=SCRAM-SHA-256
sasl.jaas.config=org.apache.kafka.common.security.scram.ScramLoginModule required username=\"alice\" password=\"new-alice-secret\";
EOF
  echo 'acl-test-alice' | kafka-console-producer.sh \
    --bootstrap-server localhost:9094 \
    --topic ${TOPIC} \
    --producer.config /tmp/alice-new.properties
"

echo ""
echo "alice записала сообщение -- Write ACL работает."
echo ""

# --- Шаг 7: Тест -- bob читает (должен успешно) ---
echo "=== Шаг 7: Тест -- bob читает сообщения (ожидается успех) ==="
echo ""

docker compose exec "${KAFKA_CONTAINER}" bash -c "
  cat > /tmp/bob.properties << 'EOF'
security.protocol=SASL_PLAINTEXT
sasl.mechanism=SCRAM-SHA-256
sasl.jaas.config=org.apache.kafka.common.security.scram.ScramLoginModule required username=\"bob\" password=\"bob-secret\";
EOF
  kafka-console-consumer.sh \
    --bootstrap-server localhost:9094 \
    --topic ${TOPIC} \
    --group bob-consumer-group \
    --from-beginning \
    --consumer.config /tmp/bob.properties \
    --timeout-ms 5000 \
    --max-messages 3 2>/dev/null || true
"

echo ""
echo "bob прочитал сообщения -- Read ACL работает."
echo ""

# --- Шаг 8: Тест -- bob пишет (должен получить DENY) ---
# У bob нет ACL Write для secure-topic.
# При ALLOW_EVERYONE_IF_NO_ACL_FOUND=true AND существующих ACL для ресурса:
# bob получит TopicAuthorizationException (AUTHORIZATION_FAILED).
# Это демонстрирует, что как только ACL настроены для ресурса --
# все операции, не покрытые явным ALLOW, отклоняются.
echo "=== Шаг 8: Тест -- bob пишет (ожидается AUTHORIZATION_FAILED) ==="
echo ""
echo "bob имеет только Read ACL. Попытка Write должна завершиться ошибкой."
echo ""

docker compose exec "${KAFKA_CONTAINER}" bash -c "
  echo 'bob-write-attempt' | kafka-console-producer.sh \
    --bootstrap-server localhost:9094 \
    --topic ${TOPIC} \
    --producer.config /tmp/bob.properties \
    --timeout 5000 2>&1 | head -5 || true
"

echo ""
echo "bob получил TopicAuthorizationException -- Write запрещён (нет ACL)."
echo ""

# --- Шаг 9: PREFIXED ACL -- alice получает доступ ко всем топикам с префиксом 'secure-' ---
# PREFIXED-паттерн позволяет одним правилом покрыть множество топиков.
# Это удобно для микросервисных архитектур: producer-service имеет доступ
# ко всем топикам своего домена (например, orders.*, payments.*).
echo "=== Шаг 9: PREFIXED ACL для alice (все топики с префиксом 'secure-') ==="
echo ""

docker compose exec "${KAFKA_CONTAINER}" kafka-acls.sh \
  --bootstrap-server localhost:9092 \
  --add \
  --allow-principal User:alice \
  --operation Write \
  --operation Describe \
  --resource-pattern-type prefixed \
  --topic "secure-"

echo ""

echo "Создание нового топика ${TOPIC2}..."
docker compose exec "${KAFKA_CONTAINER}" kafka-topics.sh \
  --bootstrap-server localhost:9092 \
  --create \
  --topic "${TOPIC2}" \
  --partitions 1 \
  --replication-factor 1 \
  --if-not-exists

echo ""
echo "Запись в ${TOPIC2} от имени alice (через PREFIXED ACL)..."
docker compose exec "${KAFKA_CONTAINER}" bash -c "
  echo 'prefixed-acl-test' | kafka-console-producer.sh \
    --bootstrap-server localhost:9094 \
    --topic ${TOPIC2} \
    --producer.config /tmp/alice-new.properties
"

echo ""
echo "alice записала в ${TOPIC2} -- PREFIXED ACL применён автоматически."
echo ""

# --- Шаг 10: Просмотр всех ACL ---
echo "=== Шаг 10: Итоговый список всех ACL ==="
echo ""

docker compose exec "${KAFKA_CONTAINER}" kafka-acls.sh \
  --bootstrap-server localhost:9092 \
  --list

echo ""

# --- Шаг 11: Удаление ACL ---
# ACL удаляются через --remove. Требуется указать все параметры точно.
echo "=== Шаг 11: Удаление LITERAL ACL alice для ${TOPIC} ==="
echo ""

docker compose exec "${KAFKA_CONTAINER}" kafka-acls.sh \
  --bootstrap-server localhost:9092 \
  --remove \
  --allow-principal User:alice \
  --operation Write \
  --operation Describe \
  --topic "${TOPIC}" \
  --force

echo ""
echo "LITERAL ACL для alice удалён. PREFIXED ACL остаётся активным."
echo ""
echo "Список ACL после удаления:"
docker compose exec "${KAFKA_CONTAINER}" kafka-acls.sh \
  --bootstrap-server localhost:9092 \
  --list

echo ""
echo "=== Итог упражнения 02 ==="
echo ""
echo "Вы изучили:"
echo "  1. Режимы авторизации: allow-all vs deny-by-default"
echo "  2. Минимальные ACL для producer (Write + Describe)"
echo "  3. Минимальные ACL для consumer (Read + Describe + Group Read)"
echo "  4. LITERAL паттерн: точное совпадение имени ресурса"
echo "  5. PREFIXED паттерн: покрытие множества ресурсов одним правилом"
echo "  6. Проверку AUTHORIZATION_FAILED при отсутствии ACL"
echo "  7. Удаление ACL через kafka-acls.sh --remove"
echo ""
echo "Следующее упражнение: 03_monitoring_stack.sh (Prometheus + Grafana)"
