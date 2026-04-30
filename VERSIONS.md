# Course versions — Apache Kafka Deep-Dive

Last review: 2026-04-30
Next review: 2026-07-30

## Cadence

Квартальный — Kafka 4.x релизит мажор каждые ~6 месяцев, KIP-848 / KIP-932 активно стабилизируются, экосистема (Strimzi, Confluent, Redpanda) движется вместе с upstream.

## Pinned baseline (April 2026)

| Component | Version | Released | Course depth |
|-----------|---------|----------|--------------|
| Apache Kafka | 4.0 | 2025-03 | full |
| Kafka 4.1 | 4.1 | 2025 (late) | partial |
| KRaft mode (single mode) | only mode in 4.0 | 2025-03 | full |
| KIP-848 (next-gen consumer rebalance) | GA | 2025 | full |
| KIP-932 (Share Groups) | preview 4.0 / GA 4.2 | 2025-03 (preview) | partial |
| ZooKeeper mode | удалён | — | mention (deprecated) |
| Kafka Streams | 4.0 | 2025-03 | full |
| Kafka Connect | 4.0 | 2025-03 | full |
| Schema Registry (Confluent) | 7.8+ | 2026-Q1 | full |
| Strimzi operator | 0.45+ | 2026-Q1 | partial |
| ksqlDB | 0.30 | 2026 | partial |
| Tiered Storage | GA (3.6+) | 2023-10 | full |

## Forthcoming (next review)

- Kafka 4.2 — KIP-932 Share Groups GA, KIP-1147 Queue semantics.
- Kafka 4.x JBOD recovery улучшения.
- Confluent Cloud / MSK Express новые фичи.
- Apache Iceberg как Kafka topic format (Tableflow / Iceberg materialization).
- Strimzi для Kafka 4.x — финальная стабилизация.

## Recent updates

- 2026-04-30 — Wave 1 P0 правки (Kafka 4.0 KRaft only, KIP-848, KIP-932 preview) + Wave 2 новые уроки (Share Groups, ZooKeeper-to-KRaft migration retrospective) + Wave 3 cross-refs (debezium-course, storage-formats, spark-course).
