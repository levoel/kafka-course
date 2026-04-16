"""
Упражнение 02: Consumer Groups

Демонстрирует механику Consumer Group в Kafka:
  - Партиции распределяются между consumer'ами одной группы
  - Каждая партиция назначается ровно одному consumer'у в группе
  - При 4 партициях и 2 consumer'ах каждый получает по 2 партиции

Запуск внутри контейнера lab:
  python exercises/02_consumer_groups.py

Ожидаемый результат: назначение партиций для каждого consumer'а группы
и полученные сообщения.

Примечание: в однопоточном Python невозможно одновременно запустить двух
consumer'ов. Упражнение последовательно демонстрирует поведение через
отправку сообщений, подписку первого consumer'а, затем второго.
"""

import os
import time

from kafka import KafkaAdminClient, KafkaConsumer, KafkaProducer
from kafka.admin import NewTopic
from kafka.errors import TopicAlreadyExistsError

# Адрес брокера берём из переменной окружения; по умолчанию localhost:9092
BOOTSTRAP_SERVERS = os.environ.get("KAFKA_BOOTSTRAP_SERVERS", "localhost:9092")

GROUP_ID = "analytics-group"
TOPIC = "events"
NUM_PARTITIONS = 4

# --- Шаг 1: Создание топика 'events' с 4 партициями ---
# 4 партиции позволяют равномерно распределить нагрузку между 2 consumer'ами:
# Consumer 1 получит партиции 0 и 1; Consumer 2 — партиции 2 и 3 (или схожее распределение).
print(f"Шаг 1: Создание топика '{TOPIC}' (4 партиции, RF=1)...")
admin = KafkaAdminClient(bootstrap_servers=BOOTSTRAP_SERVERS)
try:
    admin.create_topics([
        NewTopic(name=TOPIC, num_partitions=NUM_PARTITIONS, replication_factor=1)
    ])
    print(f"  Топик '{TOPIC}' создан.")
except TopicAlreadyExistsError:
    print(f"  Топик '{TOPIC}' уже существует — пропускаем создание.")
finally:
    admin.close()

# --- Шаг 2: Публикация тестовых сообщений ---
# Отправляем 20 сообщений; ключи распределят их по всем 4 партициям.
print(f"\nШаг 2: Публикация 20 тестовых сообщений в топик '{TOPIC}'...")
producer = KafkaProducer(
    bootstrap_servers=BOOTSTRAP_SERVERS,
    key_serializer=lambda k: k.encode("utf-8"),
    value_serializer=lambda v: v.encode("utf-8"),
)
for i in range(20):
    # hash("event-N") % 4 равномерно распределяет сообщения по партициям
    key = f"event-{i}"
    producer.send(TOPIC, key=key, value=f"payload-{i}")
producer.flush()
producer.close()
print("  20 сообщений отправлено.")

# --- Шаг 3: Consumer 1 подписывается на топик ---
# auto_offset_reset='earliest' — читаем с самого начала топика.
# enable_auto_commit=True — офсеты фиксируются автоматически.
# consumer_timeout_ms=5000 — poll завершается через 5 секунд без новых сообщений.
print(f"\nШаг 3: Consumer 1 (группа '{GROUP_ID}') подписывается на '{TOPIC}'...")
consumer1 = KafkaConsumer(
    TOPIC,
    bootstrap_servers=BOOTSTRAP_SERVERS,
    group_id=GROUP_ID,
    auto_offset_reset="earliest",
    enable_auto_commit=True,
    consumer_timeout_ms=5000,
    # client.id помогает различать consumer'ов в логах брокера
    client_id="consumer-1",
)

# Даём время на rebalance — брокер назначает партиции
# В реальном коде используют on_assign callback вместо sleep
time.sleep(2)

# partitions_for_topic() возвращает набор партиций топика, известных этому consumer'у
assigned1 = consumer1.assignment()
print(f"  Consumer 1 назначены партиции: {sorted(p.partition for p in assigned1)}")

# Читаем сообщения: Consumer 1 получит все 4 партиции, так как он один в группе
messages1 = {}
print("  Чтение сообщений Consumer 1...")
for msg in consumer1:
    partition = msg.partition
    messages1[partition] = messages1.get(partition, 0) + 1

# Выводим статистику по партициям
for part in sorted(messages1.keys()):
    print(f"    Партиция {part}: {messages1[part]} сообщений")
total1 = sum(messages1.values())
print(f"  Итого Consumer 1: {total1} сообщений из {NUM_PARTITIONS} партиций")
consumer1.close()

# --- Шаг 4: Два consumer'а в той же группе ---
# Пояснение: при запуске второго consumer'а в той же группе происходит rebalance.
# Брокер перераспределяет партиции между обоими consumer'ами.
# В однопоточном Python реальный параллельный rebalance показать невозможно,
# поэтому демонстрируем поведение последовательно: каждый consumer читает
# оставшиеся после первого (незафиксированные) сообщения.
#
# Для наблюдения реального rebalance запустите два экземпляра скрипта одновременно
# в двух терминалах внутри контейнера lab.

print(f"\nШаг 4: Consumer 2 (группа '{GROUP_ID}') — демонстрация rebalance...")
print("  (В однопоточном режиме Consumer 2 читает из той же группы после Consumer 1)")

# Публикуем новые сообщения для Consumer 2
producer2 = KafkaProducer(
    bootstrap_servers=BOOTSTRAP_SERVERS,
    key_serializer=lambda k: k.encode("utf-8"),
    value_serializer=lambda v: v.encode("utf-8"),
)
for i in range(20, 40):
    producer2.send(TOPIC, key=f"event-{i}", value=f"payload-{i}")
producer2.flush()
producer2.close()

consumer2 = KafkaConsumer(
    TOPIC,
    bootstrap_servers=BOOTSTRAP_SERVERS,
    group_id=GROUP_ID,
    auto_offset_reset="earliest",
    enable_auto_commit=True,
    consumer_timeout_ms=5000,
    client_id="consumer-2",
)

time.sleep(2)
assigned2 = consumer2.assignment()
print(f"  Consumer 2 назначены партиции: {sorted(p.partition for p in assigned2)}")

messages2 = {}
for msg in consumer2:
    partition = msg.partition
    messages2[partition] = messages2.get(partition, 0) + 1

for part in sorted(messages2.keys()):
    print(f"    Партиция {part}: {messages2[part]} сообщений")
total2 = sum(messages2.values())
print(f"  Итого Consumer 2: {total2} сообщений")
consumer2.close()

print("\nВывод:")
print("  Consumer Group распределяет партиции между участниками.")
print("  При 4 партициях и 2 consumer'ах каждый получает ~2 партиции.")
print("  Сообщение из одной партиции читает только один consumer группы.")
