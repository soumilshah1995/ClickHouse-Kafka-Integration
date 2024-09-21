-- Create separate databases for Kafka-related data and aggregated data
CREATE DATABASE IF NOT EXISTS kafka;
CREATE DATABASE IF NOT EXISTS shard;


-- Use the Kafka database
USE kafka;

-- Create the Kafka consumer table to capture raw data
CREATE TABLE IF NOT EXISTS kafka.customers_kafka_consumer
(
    data String  -- This column will store the raw JSON data from Kafka
) ENGINE = Kafka()
    SETTINGS
    kafka_broker_list = 'kafka1:9093,kafka2:9094',
    kafka_topic_list = 'customers',  -- Kafka topic to consume from
    kafka_group_name = 'clickhouse_customers_group',  -- Consumer group name
    kafka_format = 'JSONAsString',  -- Data format
    kafka_handle_error_mode = 'stream',  -- Error handling mode
    kafka_max_block_size = 1000,  -- Max block size
    kafka_num_consumers = 1;  -- Number of consumers

SET stream_like_engine_allow_direct_select = 1;

SELECT * from customers_kafka_consumer limit 1  FORMAT Vertical;


-- Switch to the 'shard' database to store the transformed data
USE shard;

-- DROP TABLE shard.customers ON CLUSTER '{cluster}' SYNC;
-- DROP TABLE IF EXISTS shard.customers ON CLUSTER '{cluster}' SYNC;

-- Create the customers table to store parsed data
CREATE TABLE IF NOT EXISTS shard.customers
(
    data String,
    customer_id LowCardinality(String) DEFAULT JSONExtract(data, 'customer_id', 'String'),
    name LowCardinality(String) DEFAULT JSONExtract(data, 'name', 'String'),
    state LowCardinality(String) DEFAULT JSONExtract(data, 'state', 'String'),
    city LowCardinality(String) DEFAULT JSONExtract(data, 'city', 'String'),
    email LowCardinality(String) DEFAULT JSONExtract(data, 'email', 'String'),
    created_at DateTime DEFAULT parseDateTimeBestEffort(JSONExtract(data, 'created_at', 'String')),
    ts Float64 DEFAULT toFloat64(JSONExtract(data, 'ts', 'String')),
    topic LowCardinality(String)  -- Assuming topic information is included in the data
    )
    ENGINE = ReplicatedReplacingMergeTree('/clickhouse/tables/{shard}/table_name', '{replica}', created_at)
    PARTITION BY toYYYYMMDD(created_at)
    ORDER BY (customer_id);



CREATE TABLE IF NOT EXISTS customers
AS shard.customers
    ENGINE = Distributed('{cluster}', 'shard', 'customers', xxHash64(customer_id));



-- Create a table to track errors while consuming Kafka messages
CREATE TABLE IF NOT EXISTS kafka.kafka_errors
(
    topic String,
    partition Int64,
    offset Int64,
    raw_message String,
    error String
)
    ENGINE = MergeTree()
    ORDER BY (topic, partition, offset);


-- Create a Materialized View to handle any Kafka errors
CREATE MATERIALIZED VIEW IF NOT EXISTS kafka.kafka_errors_mv
TO  kafka.kafka_errors AS
SELECT
    _topic AS topic,
    _partition AS partition,
    _offset AS offset,
    _raw_message AS raw_message,
    _error AS error
FROM kafka.customers_kafka_consumer
WHERE length(_error) > 0;



-- Create a Materialized View to move data from the Kafka consumer table to the customers table

CREATE MATERIALIZED VIEW IF NOT EXISTS kafka.customers_mv
TO shard.customers AS
SELECT
    data,
    JSONExtract(data, 'customer_id', 'String') AS customer_id,
    JSONExtract(data, 'name', 'String') AS name,
    JSONExtract(data, 'state', 'String') AS state,
    JSONExtract(data, 'city', 'String') AS city,
    JSONExtract(data, 'email', 'String') AS email,
    parseDateTimeBestEffort(JSONExtract(data, 'created_at', 'String')) AS created_at,
    toFloat64(JSONExtract(data, 'ts', 'String')) AS ts
FROM kafka.customers_kafka_consumer;


-- Query the customers table

-- Additional queries to extract data
SELECT COUNT(*) FROM shard.customers;
SELECT customer_id, name, city, state FROM shard.customers;
SELECT customer_id, name, city, state FROM kafka.customers_mv;

-- Optimize the customers table for performance
OPTIMIZE TABLE shard.customers FINAL;

-- Step 1: Create an AggregatingMergeTree table for state-wise customer count
CREATE TABLE IF NOT EXISTS shard.customer_count_by_state
(
    state LowCardinality(String),
    customer_count_state AggregateFunction(count, UInt32)
    )
    ENGINE = AggregatingMergeTree()
    PRIMARY KEY state;

-- Step 2: Create a Materialized View to update state-wise customer count
CREATE MATERIALIZED VIEW IF NOT EXISTS kafka.customer_count_state_mv
TO shard.customer_count_by_state AS
SELECT
    state,
    countState() AS customer_count_state
FROM shard.customers
GROUP BY state;

-- Insert state-wise count into the aggregating table
INSERT INTO shard.customer_count_by_state
SELECT state, countState() AS customer_count_state
FROM shard.customers
GROUP BY state;

-- Query to check the aggregated customer count by state
SELECT state, countMerge(customer_count_state) AS total_customer_count
FROM shard.customer_count_by_state
GROUP BY state
    FORMAT Vertical;
