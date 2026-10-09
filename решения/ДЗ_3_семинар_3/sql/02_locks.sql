-- =============================================================================
--  ДЗ (семинар 3). Q5: DDL и блокировки. Воспроизведение на двух сеансах.
--  PostgreSQL 16, демо-база demo.
-- =============================================================================
--  Часть опытов требует ДВУХ одновременных подключений.
--  Сеанс A — тот, что держит блокировку; сеанс B — тот, что в неё упирается.
-- =============================================================================

SET search_path = bookings, public;


-- =============================================================================
--  Q5.1. ALTER TABLE упирается в открытую транзакцию с SELECT
-- =============================================================================

-- СЕАНС A — открывает транзакцию и не закрывает её:
--     BEGIN;
--     SELECT count(*) FROM flights;
--     SELECT pg_sleep(25);
--     COMMIT;

-- СЕАНС B — смотрит, какая блокировка уже выдана:
SELECT l.mode, l.granted, a.state, left(a.query, 45) AS запрос
FROM pg_locks l
JOIN pg_stat_activity a USING (pid)
WHERE l.relation = 'bookings.flights'::regclass
  AND a.pid <> pg_backend_pid();
--  → AccessShareLock | granted = true

-- СЕАНС B — пытается изменить схему. Без lock_timeout ждал бы бесконечно.
SET lock_timeout = '5s';
DO $$
BEGIN
    ALTER TABLE flights ADD COLUMN weather_data jsonb;
EXCEPTION WHEN lock_not_available THEN
    RAISE NOTICE 'ALTER TABLE не дождался: %', SQLERRM;
END $$;
--  → NOTICE: canceling statement due to lock timeout

-- СЕАНС C — видит очередь: кто кого ждёт
SELECT blocked.pid                      AS ждёт_pid,
       left(blocked.query, 40)          AS ждёт_запрос,
       blocking.pid                     AS блокирует_pid,
       left(blocking.query, 40)         AS блокирует_запрос
FROM pg_stat_activity blocked
JOIN pg_stat_activity blocking ON blocking.pid = ANY (pg_blocking_pids(blocked.pid));

-- и обе блокировки на таблице разом:
SELECT mode, granted, count(*)
FROM pg_locks
WHERE relation = 'bookings.flights'::regclass
GROUP BY 1, 2 ORDER BY granted DESC;
--  → AccessShareLock     | t  (аналитик держит)
--  → AccessExclusiveLock | f  (ALTER TABLE стоит в очереди)


-- =============================================================================
--  Q5.2. ADD COLUMN ... DEFAULT выполняется мгновенно (PostgreSQL 11+)
-- =============================================================================
-- Таблица ticket_flights — 2 360 335 строк, 154 МБ.

\timing on
ALTER TABLE ticket_flights ADD COLUMN is_delayed boolean DEFAULT false;
\timing off
--  → Time: 3.016 ms

-- Размер не изменился: ни одна строка не переписана.
SELECT pg_size_pretty(pg_relation_size('ticket_flights')) AS размер;

-- Значение для СТАРЫХ строк лежит в системном каталоге, а не в самих строках:
SELECT attname, atthasmissing, attmissingval
FROM pg_attribute
WHERE attrelid = 'bookings.ticket_flights'::regclass AND attname = 'is_delayed';
--  → is_delayed | t | {f}

-- Меняем DEFAULT на true:
ALTER TABLE ticket_flights ALTER COLUMN is_delayed SET DEFAULT true;

-- attmissingval не изменился — старые строки по-прежнему читаются как false:
SELECT attname, atthasmissing, attmissingval
FROM pg_attribute
WHERE attrelid = 'bookings.ticket_flights'::regclass AND attname = 'is_delayed';
--  → is_delayed | t | {f}

-- А новая строка получает уже новый DEFAULT:
BEGIN;
INSERT INTO ticket_flights (ticket_no, flight_id, fare_conditions, amount)
SELECT t.ticket_no, f.flight_id, 'Economy', 100
FROM tickets t, flights f
WHERE f.flight_id = (SELECT max(flight_id) FROM flights)
  AND NOT EXISTS (SELECT 1 FROM ticket_flights tf
                  WHERE tf.ticket_no = t.ticket_no AND tf.flight_id = f.flight_id)
LIMIT 1;

SELECT is_delayed, count(*) FROM ticket_flights GROUP BY 1 ORDER BY 1;
--  → f | 2360335   (старые)
--  → t |       1   (новая)
ROLLBACK;

ALTER TABLE ticket_flights DROP COLUMN is_delayed;


-- =============================================================================
--  Q5.3. CREATE INDEX против CREATE INDEX CONCURRENTLY
-- =============================================================================

-- СЕАНС A — обычное построение индекса, транзакция не закрыта:
--     BEGIN;
--     CREATE INDEX idx_tmp_fare ON ticket_flights (fare_conditions);
--     SELECT pg_sleep(12);
--     ROLLBACK;

-- СЕАНС B — какая блокировка взята:
SELECT mode, granted
FROM pg_locks
WHERE relation = 'bookings.ticket_flights'::regclass AND pid <> pg_backend_pid();
--  → ShareLock | t

-- СЕАНС B — чтение проходит свободно:
SELECT count(*) FROM ticket_flights;
--  → 2360335

-- СЕАНС B — а запись встаёт в очередь:
SET lock_timeout = '3s';
DO $$
BEGIN
    UPDATE ticket_flights SET amount = amount
     WHERE ticket_no = (SELECT min(ticket_no) FROM ticket_flights);
    RAISE NOTICE 'UPDATE прошёл';
EXCEPTION WHEN lock_not_available THEN
    RAISE NOTICE 'UPDATE заблокирован: %', SQLERRM;
END $$;
--  → NOTICE: UPDATE заблокирован

-- Теперь то же самое, но с CONCURRENTLY.
-- СЕАНС A (вне транзакционного блока — CONCURRENTLY внутри BEGIN не работает):
--     CREATE INDEX CONCURRENTLY idx_tmp ON boarding_passes (ticket_no, seat_no);

-- СЕАНС B — блокировка слабее:
SELECT mode, granted
FROM pg_locks
WHERE relation = 'bookings.boarding_passes'::regclass AND pid <> pg_backend_pid();
--  → ShareUpdateExclusiveLock | t

-- СЕАНС B — запись при этом не блокируется:
SET lock_timeout = '3s';
DO $$
BEGIN
    UPDATE ticket_flights SET amount = amount
     WHERE ticket_no = (SELECT min(ticket_no) FROM ticket_flights);
    RAISE NOTICE 'UPDATE прошёл свободно';
EXCEPTION WHEN lock_not_available THEN
    RAISE NOTICE 'UPDATE заблокирован';
END $$;
--  → NOTICE: UPDATE прошёл свободно
