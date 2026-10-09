-- =============================================================================
--  ДЗ (семинар 3). Запросы к демо-базе авиаперевозок (demo-medium-en)
--  PostgreSQL 16. Схема bookings.
-- =============================================================================

SET search_path = bookings, public;


-- =============================================================================
--  Q1. Уникальные номера рейсов с сортировкой
-- =============================================================================
-- Два способа, дающие одинаковый результат (710 строк):

SELECT DISTINCT flight_no
FROM flights
ORDER BY flight_no;

SELECT flight_no
FROM flights
GROUP BY flight_no
ORDER BY flight_no;

-- Проверка, что наборы совпадают (должно вернуть 0):
SELECT count(*) AS расхождений FROM (
    (SELECT DISTINCT flight_no FROM flights)
    EXCEPT
    (SELECT flight_no FROM flights GROUP BY flight_no)
) x;

-- Сортировка строк разного регистра зависит от правила сравнения.
-- База создана с datcollate = C.UTF-8, то есть сравнение побайтовое.
WITH t(v) AS (VALUES ('PG0001'),('pg0001'),('PG0002'),('pg0002'),('Pg0001'))
SELECT string_agg(v, ' < ' ORDER BY v COLLATE "C")         AS "побайтово (C)",
       string_agg(v, ' < ' ORDER BY v COLLATE "und-x-icu") AS "лингвистически (ICU)"
FROM t;


-- =============================================================================
--  Q2. Выручка и число пассажиров по рейсам
-- =============================================================================
-- LEFT JOIN, чтобы рейсы без проданных билетов попали в выборку с нулями.
-- COUNT(DISTINCT t.passenger_id) вместо COUNT(*): один пассажир может купить
-- несколько билетов на один рейс, и COUNT(*) посчитал бы его дважды.
-- COALESCE нужен, потому что SUM по пустому множеству возвращает NULL.

SELECT f.flight_id,
       f.flight_no,
       f.status,
       coalesce(sum(tf.amount), 0)    AS выручка,
       count(DISTINCT t.passenger_id) AS пассажиров,
       count(tf.ticket_no)            AS проданных_билетов
FROM flights f
LEFT JOIN ticket_flights tf ON tf.flight_id = f.flight_id
LEFT JOIN tickets        t  ON t.ticket_no  = tf.ticket_no
GROUP BY f.flight_id, f.flight_no, f.status
ORDER BY выручка DESC
LIMIT 20;

-- Сколько рейсов теряется при INNER JOIN:
SELECT (SELECT count(*) FROM flights)                                        AS всего_рейсов,
       (SELECT count(DISTINCT flight_id) FROM ticket_flights)                AS с_билетами,
       (SELECT count(*) FROM flights) -
       (SELECT count(DISTINCT flight_id) FROM ticket_flights)                AS потерялось_бы;


-- =============================================================================
--  Q3. Города, из которых не было ни одного отменённого рейса
-- =============================================================================
-- NOT EXISTS, а не NOT IN: он устойчив к NULL в подзапросе и корректно
-- включает аэропорты, которых вообще нет в таблице flights.

SELECT DISTINCT a.city
FROM airports a
WHERE NOT EXISTS (
    SELECT 1
    FROM flights f
    WHERE f.departure_airport = a.airport_code
      AND f.status = 'Cancelled'
)
ORDER BY a.city;

-- Демонстрация ловушки NOT IN: тот же запрос, но в подзапрос добавлен один NULL.
-- Первый вернёт строки, второй — ноль строк.
SELECT count(*) AS "NOT IN без NULL"
FROM airports a
WHERE a.airport_code NOT IN (
    SELECT f.departure_airport FROM flights f WHERE f.status = 'Cancelled');

SELECT count(*) AS "NOT IN с одним NULL"
FROM airports a
WHERE a.airport_code NOT IN (
    SELECT f.departure_airport FROM flights f WHERE f.status = 'Cancelled'
    UNION ALL SELECT NULL);

SELECT count(*) AS "NOT EXISTS с тем же NULL"
FROM airports a
WHERE NOT EXISTS (
    SELECT 1 FROM (
        SELECT f.departure_airport AS code FROM flights f WHERE f.status = 'Cancelled'
        UNION ALL SELECT NULL
    ) s WHERE s.code = a.airport_code);


-- =============================================================================
--  Q4. Уникальные пассажиры на рейсе по посадочным талонам
-- =============================================================================
-- В демо-базе таблица называется boarding_passes.

SELECT DISTINCT t.passenger_id, t.passenger_name
FROM boarding_passes bp
JOIN tickets t USING (ticket_no)
WHERE bp.flight_id = 543
ORDER BY t.passenger_name;

-- Есть ли вообще пассажиры с двумя посадочными на один рейс:
SELECT count(*) AS случаев_дублирования FROM (
    SELECT bp.flight_id, t.passenger_id
    FROM boarding_passes bp
    JOIN tickets t USING (ticket_no)
    GROUP BY 1, 2
    HAVING count(*) > 1
) x;

-- Есть ли посадочный талон без проданного билета на этот рейс:
SELECT count(*) AS посадочных_без_билета
FROM boarding_passes bp
WHERE NOT EXISTS (
    SELECT 1 FROM ticket_flights tf
    WHERE tf.ticket_no = bp.ticket_no AND tf.flight_id = bp.flight_id);


-- =============================================================================
--  Q6. Агрегация и NULL
-- =============================================================================
-- AVG игнорирует NULL: строки без actual_departure просто не попадают
-- ни в сумму, ни в счётчик. Сравнение двух трактовок:

SELECT count(*)                                              AS строк_всего,
       count(actual_departure - scheduled_departure)         AS учтено_в_avg,
       avg(actual_departure - scheduled_departure)           AS "AVG (NULL пропущены)",
       avg(coalesce(actual_departure - scheduled_departure,
                    interval '0'))                           AS "AVG (NULL = 0)"
FROM flights;

-- Откуда берутся пропуски:
SELECT status,
       count(*)                AS рейсов,
       count(actual_departure) AS с_фактическим_вылетом
FROM flights
GROUP BY status
ORDER BY рейсов DESC;

-- COUNT(столбец) против COUNT(*):
SELECT count(*)              AS "COUNT(*)",
       count(aircraft_code)  AS "COUNT(aircraft_code)",
       count(actual_arrival) AS "COUNT(actual_arrival)"
FROM flights;

-- Почему первые два совпадают — столбец объявлен NOT NULL:
SELECT column_name, is_nullable
FROM information_schema.columns
WHERE table_schema = 'bookings' AND table_name = 'flights'
  AND column_name IN ('aircraft_code', 'status', 'actual_arrival');
