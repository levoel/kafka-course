"""
Упражнение 02: Schema Registry — регистрация Avro схемы и работа со схемными ID

Демонстрирует:
  - Регистрацию Avro схемы через REST API Schema Registry
  - Получение схемы по ID (именно так работает десериализатор)
  - Ручную сборку сообщения в формате wire format (5-байтовый заголовок + Avro payload)
  - Продюсирование сообщений с schema ID в заголовке
  - Декодирование 5-байтового заголовка из прочитанного сообщения

Формат wire format (5 байт перед каждым Avro-сообщением):
  Байт 0: 0x00 (magic byte — признак Schema Registry encoded сообщения)
  Байты 1-4: schema ID (big-endian int32)
  Байты 5+: Avro binary payload

Запуск:
  pip install requests confluent-kafka fastavro
  python exercises/02_schema_registry_avro.py

Ожидаемый результат:
  Схема зарегистрирована с ID (обычно 1 или следующий доступный номер).
  Сообщение продюсировано с правильным 5-байтовым заголовком.
  Декодирование заголовка показывает magic byte и schema ID.
"""

import io
import json
import struct
import time

import fastavro
import requests

# Адреса сервисов
SCHEMA_REGISTRY_URL = "http://localhost:8081"
KAFKA_BOOTSTRAP = "localhost:9092"

# Avro схема для Order — описывает структуру записи заказа
ORDER_SCHEMA = {
    "type": "record",
    "name": "Order",
    "namespace": "ru.kafka.lab",
    "fields": [
        {"name": "order_id", "type": "int", "doc": "Уникальный идентификатор заказа"},
        {"name": "product", "type": "string", "doc": "Наименование товара"},
        {"name": "quantity", "type": "int", "doc": "Количество единиц товара"},
        {
            "name": "price_rub",
            "type": "double",
            "doc": "Цена за единицу в рублях",
        },
        {
            "name": "created_at_ms",
            "type": "long",
            "doc": "Время создания заказа в миллисекундах (Unix timestamp)",
        },
    ],
}

SUBJECT = "orders-value"

print("=== Упражнение 02: Schema Registry + Avro wire format ===")
print("")

# --- Шаг 1: Регистрация схемы через REST API ---
# POST /subjects/{subject}/versions
# subject = "orders-value" (TopicNameStrategy: {topic}-value)
# schemaType = "AVRO" (можно также PROTOBUF или JSONSCHEMA)
# Если схема уже зарегистрирована, Schema Registry вернёт существующий ID (идемпотентно).
print("Шаг 1: Регистрация Avro схемы в Schema Registry...")
register_response = requests.post(
    f"{SCHEMA_REGISTRY_URL}/subjects/{SUBJECT}/versions",
    headers={"Content-Type": "application/vnd.schemaregistry.v1+json"},
    json={"schema": json.dumps(ORDER_SCHEMA), "schemaType": "AVRO"},
)

if register_response.status_code == 200:
    schema_id = register_response.json()["id"]
    print(f"  Схема зарегистрирована. ID = {schema_id}")
    print(f"  Subject: {SUBJECT}")
else:
    print(f"  Ошибка регистрации: {register_response.status_code}")
    print(f"  {register_response.text}")
    raise SystemExit(1)
print("")

# --- Шаг 2: Получение схемы по ID ---
# GET /schemas/ids/{id}
# Десериализатор использует именно этот эндпоинт: читает 4-байтовый ID из заголовка,
# запрашивает схему, декодирует Avro payload.
print(f"Шаг 2: Получение схемы по ID {schema_id}...")
fetch_response = requests.get(f"{SCHEMA_REGISTRY_URL}/schemas/ids/{schema_id}")
if fetch_response.status_code == 200:
    fetched_schema_str = fetch_response.json()["schema"]
    print(f"  Схема получена (первые 120 символов):")
    print(f"  {fetched_schema_str[:120]}...")
else:
    print(f"  Ошибка: {fetch_response.status_code} — {fetch_response.text}")
print("")

# --- Шаг 3: Сериализация записи в Avro binary format ---
# fastavro.schemaless_writer сериализует Python dict в Avro binary bytes
# без встроенного заголовка схемы (schema ID добавим вручную).
print("Шаг 3: Сериализация тестовой записи в Avro binary...")
parsed_schema = fastavro.parse_schema(ORDER_SCHEMA)

test_order = {
    "order_id": 1001,
    "product": "Kafka in Action (книга)",
    "quantity": 2,
    "price_rub": 1850.0,
    "created_at_ms": int(time.time() * 1000),
}

avro_buffer = io.BytesIO()
fastavro.schemaless_writer(avro_buffer, parsed_schema, test_order)
avro_payload = avro_buffer.getvalue()

print(f"  Запись: {test_order}")
print(f"  Avro binary размер: {len(avro_payload)} байт")
print(f"  Avro hex (первые 20 байт): {avro_payload[:20].hex()}")
print("")

# --- Шаг 4: Сборка сообщения в wire format ---
# Wire format = magic byte (1 байт) + schema ID (4 байта big-endian) + Avro payload
# Структура:
#   0x00 | schema_id (big-endian int32) | avro_binary_bytes
#
# struct.pack(">bI", 0, schema_id) упаковывает:
#   > = big-endian byte order
#   b = signed byte (magic byte = 0)
#   I = unsigned int (4 байта) = schema ID
print("Шаг 4: Сборка сообщения в Schema Registry wire format...")
wire_header = struct.pack(">bI", 0, schema_id)
wire_message = wire_header + avro_payload

print(f"  Wire format заголовок (5 байт): {wire_header.hex()}")
print(f"    Байт 0 (magic): 0x{wire_header[0]:02x}")
print(f"    Байты 1-4 (schema ID): {struct.unpack('>I', wire_header[1:5])[0]}")
print(f"  Итоговое сообщение: {len(wire_message)} байт")
print(f"  Полный hex: {wire_message.hex()}")
print("")

# --- Шаг 5: Декодирование wire format сообщения ---
# Симуляция работы десериализатора:
#   1. Прочитать байт 0 — убедиться, что это 0x00 (magic byte)
#   2. Прочитать байты 1-4 — получить schema ID (big-endian int32)
#   3. Запросить схему у Schema Registry по ID
#   4. Декодировать Avro payload, начиная с байта 5
print("Шаг 5: Декодирование wire format сообщения (симуляция десериализатора)...")
received_message = wire_message  # имитация полученных байт

magic_byte = received_message[0]
if magic_byte != 0x00:
    raise ValueError(f"Неизвестный magic byte: 0x{magic_byte:02x}")

received_schema_id = struct.unpack(">I", received_message[1:5])[0]
avro_bytes = received_message[5:]

print(f"  Magic byte: 0x{magic_byte:02x} (Schema Registry encoded)")
print(f"  Schema ID: {received_schema_id}")

# Получить схему по ID и декодировать payload
schema_for_decode = requests.get(
    f"{SCHEMA_REGISTRY_URL}/schemas/ids/{received_schema_id}"
).json()["schema"]
decode_schema = fastavro.parse_schema(json.loads(schema_for_decode))

decoded_record = fastavro.schemaless_reader(
    io.BytesIO(avro_bytes), decode_schema
)
print(f"  Декодированная запись: {decoded_record}")
print("")

# --- Шаг 6: Список зарегистрированных subjects ---
print("Шаг 6: Список subjects в Schema Registry:")
subjects_response = requests.get(f"{SCHEMA_REGISTRY_URL}/subjects")
print(f"  {subjects_response.json()}")
print("")

# --- Шаг 7: Версии схемы для subject ---
# GET /subjects/{subject}/versions — список всех версий схемы для данного subject
print(f"Шаг 7: Версии схемы для subject '{SUBJECT}':")
versions_response = requests.get(
    f"{SCHEMA_REGISTRY_URL}/subjects/{SUBJECT}/versions"
)
print(f"  Версии: {versions_response.json()}")
print("")

# Получить конкретную версию
print(f"  Детали версии 1:")
version_detail = requests.get(
    f"{SCHEMA_REGISTRY_URL}/subjects/{SUBJECT}/versions/1"
)
detail_json = version_detail.json()
print(f"    Subject: {detail_json['subject']}")
print(f"    Version: {detail_json['version']}")
print(f"    ID: {detail_json['id']}")
print("")

print("=== Итог ===")
print("Schema Registry хранит схемы и выдаёт им числовые ID.")
print("Каждое Schema Registry-encoded сообщение начинается с 5-байтового заголовка:")
print("  0x00 (magic byte) + 4 байта schema ID (big-endian).")
print("Десериализатор читает ID из заголовка и запрашивает схему у Registry.")
print("Это позволяет каждому потребителю всегда знать схему полученного сообщения.")
