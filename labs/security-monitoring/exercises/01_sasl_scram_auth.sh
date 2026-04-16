#!/usr/bin/env bash
# Упражнение 01: SASL/SCRAM-SHA-256 аутентификация
#
# Цель: изучить управление учётными записями SCRAM в Kafka 4.0 (KRaft).
# Вы создадите пользователей alice и bob, подключитесь к брокеру с аутентификацией,
# убедитесь в корректности отклонения неверных учётных данных
# и ротируете пароль без перезапуска брокера.
#
# Отличие SCRAM от PLAIN:
#   SCRAM-SHA-256 хранит учётные данные в виде хешей в метаданных KRaft.
#   Пользователей можно добавлять и удалять без перезапуска брокера.
#   PLAIN хранит пароли в JAAS-конфигурации брокера -- требует перезапуска.
#
# Архитектура listener'ов в этом стенде:
#   PLAINTEXT://kafka:9092  -- без аутентификации (admin-операции)
#   SASL_PLAINTEXT://kafka:9094 -- SCRAM-SHA-256 (клиентские подключения)
#
# Запуск: bash exercises/01_sasl_scram_auth.sh
# Требования: docker compose up -d, все сервисы healthy
#
# Ожидаемый результат:
#   Шаг 4: успешная запись с alice/alice-secret
#   Шаг 5: успешное чтение с alice/alice-secret
#   Шаг 6: AuthenticationException при неверном пароле
#   Шаг 7: успешная запись после ротации пароля

set -euo pipefail

KAFKA_CONTAINER="kafka-security-lab"
TOPIC="secure-topic"

echo "=== Упражнение 01: SASL/SCRAM-SHA-256 аутентификация ==="
echo ""

# --- Шаг 1: Создание учётных записей SCRAM ---
# kafka-configs.sh --alter --add-config 'SCRAM-SHA-256=[...]'
# сохраняет хеш пароля в метаданных KRaft (топик __cluster_metadata).
# Команда выполняется через PLAINTEXT listener (9092) -- без аутентификации.
# Это административная операция: создать пользователя может только суперпользователь
# или подключение без ACL (ALLOW_EVERYONE_IF_NO_ACL_FOUND=true в нашем стенде).
echo "=== Шаг 1: Создание учётных записей SCRAM для alice и bob ==="
echo ""

echo "Создание пользователя alice..."
docker compose exec "${KAFKA_CONTAINER}" kafka-configs.sh \
  --bootstrap-server localhost:9092 \
  --alter \
  --add-config 'SCRAM-SHA-256=[iterations=8192,password=alice-secret]' \
  --entity-type users \
  --entity-name alice

echo ""
echo "Создание пользователя bob..."
docker compose exec "${KAFKA_CONTAINER}" kafka-configs.sh \
  --bootstrap-server localhost:9092 \
  --alter \
  --add-config 'SCRAM-SHA-256=[iterations=8192,password=bob-secret]' \
  --entity-type users \
  --entity-name bob

echo ""
echo "Пользователи alice и bob созданы."
echo ""

# --- Шаг 2: Проверка сохранённых учётных записей ---
# --describe показывает, что учётная запись существует.
# Пароль НЕ отображается -- хранится только хеш (iterations + salt + stored_key + server_key).
echo "=== Шаг 2: Проверка учётных записей ==="
echo ""
echo "Учётные данные alice:"
docker compose exec "${KAFKA_CONTAINER}" kafka-configs.sh \
  --bootstrap-server localhost:9092 \
  --describe \
  --entity-type users \
  --entity-name alice

echo ""
echo "Все пользователи:"
docker compose exec "${KAFKA_CONTAINER}" kafka-configs.sh \
  --bootstrap-server localhost:9092 \
  --describe \
  --entity-type users

echo ""

# --- Шаг 3: Создание топика для тестирования ---
# Создаём через PLAINTEXT listener (9092) -- без аутентификации.
# Клиентские операции (produce/consume) будут через SASL_PLAINTEXT (9094).
echo "=== Шаг 3: Создание топика ${TOPIC} ==="
echo ""

docker compose exec "${KAFKA_CONTAINER}" kafka-topics.sh \
  --bootstrap-server localhost:9092 \
  --create \
  --topic "${TOPIC}" \
  --partitions 3 \
  --replication-factor 1 \
  --if-not-exists

echo ""
echo "Список топиков:"
docker compose exec "${KAFKA_CONTAINER}" kafka-topics.sh \
  --bootstrap-server localhost:9092 \
  --list

echo ""

# --- Шаг 4: Запись сообщений с SASL/SCRAM аутентификацией ---
# Клиент подключается к SASL_PLAINTEXT listener (порт 9094).
# JAAS-конфигурация передаётся через файл свойств.
# В production используют SASL_SSL (с шифрованием) -- здесь SASL_PLAINTEXT для наглядности.
echo "=== Шаг 4: Запись сообщений от имени alice ==="
echo ""

echo "Создание файла конфигурации alice внутри контейнера..."
docker compose exec "${KAFKA_CONTAINER}" bash -c "cat > /tmp/alice.properties << 'EOF'
security.protocol=SASL_PLAINTEXT
sasl.mechanism=SCRAM-SHA-256
sasl.jaas.config=org.apache.kafka.common.security.scram.ScramLoginModule required username=\"alice\" password=\"alice-secret\";
EOF"

echo ""
echo "Запись 3 сообщений от имени alice (через SASL_PLAINTEXT listener)..."
docker compose exec "${KAFKA_CONTAINER}" bash -c "
  for i in 1 2 3; do
    echo \"alice-message-\$i\"
  done | kafka-console-producer.sh \
    --bootstrap-server localhost:9094 \
    --topic ${TOPIC} \
    --producer.config /tmp/alice.properties
"

echo ""
echo "Сообщения записаны успешно. alice прошла аутентификацию через SCRAM-SHA-256."
echo ""

# --- Шаг 5: Чтение сообщений с SASL/SCRAM аутентификацией ---
# Тот же файл конфигурации, но теперь для consumer.
# --timeout-ms 5000 завершает consumer после 5 секунд ожидания новых сообщений.
echo "=== Шаг 5: Чтение сообщений от имени alice ==="
echo ""

docker compose exec "${KAFKA_CONTAINER}" bash -c "
  cat > /tmp/alice-consumer.properties << 'EOF'
security.protocol=SASL_PLAINTEXT
sasl.mechanism=SCRAM-SHA-256
sasl.jaas.config=org.apache.kafka.common.security.scram.ScramLoginModule required username=\"alice\" password=\"alice-secret\";
EOF
  kafka-console-consumer.sh \
    --bootstrap-server localhost:9094 \
    --topic ${TOPIC} \
    --from-beginning \
    --consumer.config /tmp/alice-consumer.properties \
    --timeout-ms 5000 \
    --max-messages 3 2>/dev/null || true
"

echo ""
echo "Чтение завершено. Должны отобразиться: alice-message-1, alice-message-2, alice-message-3"
echo ""

# --- Шаг 6: Тест с неверным паролем ---
# Kafka отклонит подключение с AuthenticationException.
# Это поведение SCRAM: брокер проверяет salted hash, несоответствие -> разрыв.
echo "=== Шаг 6: Попытка подключения с неверным паролем ==="
echo ""
echo "Ожидается ошибка: org.apache.kafka.common.errors.SaslAuthenticationException"
echo ""

docker compose exec "${KAFKA_CONTAINER}" bash -c "
  cat > /tmp/wrong.properties << 'EOF'
security.protocol=SASL_PLAINTEXT
sasl.mechanism=SCRAM-SHA-256
sasl.jaas.config=org.apache.kafka.common.security.scram.ScramLoginModule required username=\"alice\" password=\"wrong-password\";
EOF
  kafka-console-producer.sh \
    --bootstrap-server localhost:9094 \
    --topic ${TOPIC} \
    --producer.config /tmp/wrong.properties \
    --request-required-acks 1 \
    --timeout 5000 <<< 'test' 2>&1 | head -5 || true
"

echo ""
echo "Подключение отклонено -- SCRAM-аутентификация не прошла."
echo ""

# --- Шаг 7: Ротация пароля без перезапуска брокера ---
# Это ключевое преимущество SCRAM перед PLAIN:
# новые учётные данные вступают в силу немедленно --
# без перезапуска Kafka и без прерывания других подключений.
echo "=== Шаг 7: Ротация пароля alice ==="
echo ""

echo "Изменение пароля alice на new-alice-secret..."
docker compose exec "${KAFKA_CONTAINER}" kafka-configs.sh \
  --bootstrap-server localhost:9092 \
  --alter \
  --add-config 'SCRAM-SHA-256=[iterations=8192,password=new-alice-secret]' \
  --entity-type users \
  --entity-name alice

echo ""
echo "Проверка подключения с новым паролем..."
docker compose exec "${KAFKA_CONTAINER}" bash -c "
  cat > /tmp/alice-new.properties << 'EOF'
security.protocol=SASL_PLAINTEXT
sasl.mechanism=SCRAM-SHA-256
sasl.jaas.config=org.apache.kafka.common.security.scram.ScramLoginModule required username=\"alice\" password=\"new-alice-secret\";
EOF
  echo 'rotated-message' | kafka-console-producer.sh \
    --bootstrap-server localhost:9094 \
    --topic ${TOPIC} \
    --producer.config /tmp/alice-new.properties
"

echo ""
echo "Ротация пароля выполнена без перезапуска Kafka."
echo ""

# --- Шаг 8: Удаление учётной записи ---
# Удаление SCRAM-конфигурации для пользователя -- немедленный эффект.
echo "=== Шаг 8 (необязательный): Удаление учётной записи ==="
echo ""
echo "Чтобы удалить пользователя alice, выполните:"
echo ""
echo "  docker compose exec ${KAFKA_CONTAINER} kafka-configs.sh \\"
echo "    --bootstrap-server localhost:9092 \\"
echo "    --alter --delete-config 'SCRAM-SHA-256' \\"
echo "    --entity-type users --entity-name alice"
echo ""

echo "=== Итог упражнения 01 ==="
echo ""
echo "Вы изучили:"
echo "  1. Создание SCRAM-пользователей через kafka-configs.sh (без перезапуска брокера)"
echo "  2. Подключение producer и consumer с SASL_PLAINTEXT + SCRAM-SHA-256"
echo "  3. Отклонение AuthenticationException при неверном пароле"
echo "  4. Ротацию пароля в реальном времени"
echo ""
echo "Следующее упражнение: 02_acl_authorization.sh (ACL-правила: allow/deny по пользователю)"
