"""
Упражнение 01: Основы Producer

Демонстрирует создание KafkaProducer с настройками надёжной доставки:
  - acks='all'  — подтверждение от всех ISR-реплик (максимальная надёжность)
  - compression_type='gzip' — сжатие батча перед отправкой (экономия трафика)

Запуск внутри контейнера lab:
  python exercises/01_producer_basics.py

Ожидаемый результат: 10 строк с partition, offset и timestamp для каждого сообщения.
"""

import json
import os
import time

from kafka import KafkaAdminClient, KafkaProducer
from kafka.admin import NewTopic
from kafka.errors import TopicAlreadyExistsError

# Адрес брокера берём из переменной окружения; по умолчанию localhost:9092
BOOTSTRAP_SERVERS = os.environ.get("KAFKA_BOOTSTRAP_SERVERS", "localhost:9092")

# --- Шаг 1: Создание топика 'orders' с 3 партициями ---
# Replication factor = 1, так как у нас одноброкерный кластер.
# В production-кластере используется replication.factor >= 3.
print("Шаг 1: Создание топика 'orders' (3 партиции, RF=1)...")
admin = KafkaAdminClient(bootstrap_servers=BOOTSTRAP_SERVERS)
try:
    admin.create_topics([
        NewTopic(name="orders", num_partitions=3, replication_factor=1)
    ])
    print("  Топик 'orders' создан.")
except TopicAlreadyExistsError:
    print("  Топик 'orders' уже существует — пропускаем создание.")
finally:
    admin.close()

# --- Шаг 2: Создание KafkaProducer ---
# acks='all' — продюсер ждёт подтверждения от лидера + всех ISR-фолловеров.
# compression_type='gzip' — Kafka сжимает батч целиком перед отправкой.
print("\nШаг 2: Инициализация KafkaProducer (acks=all, compression=gzip)...")
producer = KafkaProducer(
    bootstrap_servers=BOOTSTRAP_SERVERS,
    acks="all",
    compression_type="gzip",
    # key и value сериализуются в bytes; здесь используем простое UTF-8 кодирование
    key_serializer=lambda k: k.encode("utf-8"),
    value_serializer=lambda v: json.dumps(v).encode("utf-8"),
)

# --- Шаг 3: Отправка 10 сообщений ---
# Ключ сообщения (order-N) определяет партицию через hash(key) % num_partitions.
# Сообщения с одним ключом всегда попадают в одну партицию — гарантия упорядоченности.
print("\nШаг 3: Отправка 10 сообщений в топик 'orders'...")
for i in range(1, 11):
    key = f"order-{i}"
    value = {
        "order_id": i,
        "product": f"item-{i * 10}",
        "quantity": i,
        "timestamp": int(time.time() * 1000),
    }

    # send() возвращает FutureRecordMetadata; .get() блокирует до получения ACK
    future = producer.send("orders", key=key, value=value)
    record_metadata = future.get(timeout=10)

    # RecordMetadata содержит partition, offset и timestamp подтверждённой записи
    print(
        f"  Сообщение {key} доставлено: "
        f"partition={record_metadata.partition}, "
        f"offset={record_metadata.offset}, "
        f"timestamp={record_metadata.timestamp}"
    )

# --- Шаг 4: Завершение работы ---
# flush() отправляет все буферизованные сообщения перед закрытием.
# close() освобождает соединения с брокером.
print("\nШаг 4: Завершение работы producer...")
producer.flush()
producer.close()
print("Producer закрыт. Все 10 сообщений доставлены с подтверждением acks=all.")
