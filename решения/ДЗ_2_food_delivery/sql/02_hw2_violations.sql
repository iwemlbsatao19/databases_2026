-- =============================================================================
--  ДЗ №2. Часть 2. Демонстрация нарушений ограничений целостности
--  Вариант №2 — Служба доставки еды. PostgreSQL 16.
-- =============================================================================
--  Запускать после 01_schema.sql, 02_seed.sql (ДЗ №1) и 01_hw2_tables.sql.
--
--  Каждый блок намеренно выполняет некорректную операцию, перехватывает
--  ошибку и печатает сообщение на понятном пользователю языке вместе
--  с исходным текстом ошибки СУБД (SQLERRM).
--
--      psql -U postgres -d postgres -f 02_hw2_violations.sql
-- =============================================================================

SET search_path = food_delivery, public;


-- =============================================================================
--  ПОДГОТОВКА: рабочий промокод, применённый к настоящему заказу
-- =============================================================================

INSERT INTO promo_codes (code, description, discount_kind, discount_value,
                         min_order_amount, valid_to, usage_limit)
VALUES ('WELCOME300', 'Скидка 300 рублей на первый заказ', 'fixed', 300.00,
        1000.00, now() + interval '30 day', 1000)
ON CONFLICT (code) DO NOTHING;

INSERT INTO order_promotions (order_id, promo_code_id, discount_amount)
SELECT (SELECT min(order_id) FROM orders),
       promo_code_id,
       300.00
FROM promo_codes
WHERE code = 'WELCOME300'
ON CONFLICT DO NOTHING;

UPDATE orders
   SET discount_total = 300.00
 WHERE order_id = (SELECT min(order_id) FROM orders);

UPDATE promo_codes
   SET used_count = used_count + 1
 WHERE code = 'WELCOME300' AND used_count = 0;


-- =============================================================================
--  ДЕМОНСТРАЦИЯ 1 — нарушение CHECK
-- =============================================================================
-- Ограничение chk_promo_codes_percent_range зависит от соседней колонки:
-- процентная скидка не может превышать 100%.

DO $$
BEGIN
    -- попытка завести акцию со скидкой 150 процентов
    INSERT INTO promo_codes (code, description, discount_kind, discount_value, valid_to)
    VALUES ('MEGA150', 'Скидка 150 процентов', 'percent', 150.00, now() + interval '7 day');
EXCEPTION
    WHEN check_violation THEN
        RAISE NOTICE 'Скидка больше 100%% невозможна: сервис доплачивал бы клиенту за сделанный заказ. Текст ошибки: %', SQLERRM;
END;
$$;


-- =============================================================================
--  ДЕМОНСТРАЦИЯ 2 — нарушение FOREIGN KEY
-- =============================================================================

DO $$
BEGIN
    -- попытка применить промокод к заказу, которого не существует
    INSERT INTO order_promotions (order_id, promo_code_id, discount_amount)
    VALUES (999999,
            (SELECT promo_code_id FROM promo_codes WHERE code = 'WELCOME300'),
            300.00);
EXCEPTION
    WHEN foreign_key_violation THEN
        RAISE NOTICE 'Скидка привязана к несуществующему заказу: применить промокод можно только к оформленному заказу. Текст ошибки: %', SQLERRM;
END;
$$;


-- =============================================================================
--  ДЕМОНСТРАЦИЯ 3 — нарушение UNIQUE
-- =============================================================================

DO $$
BEGIN
    -- попытка завести вторую акцию с уже занятым кодом
    INSERT INTO promo_codes (code, description, discount_kind, discount_value, valid_to)
    VALUES ('WELCOME300', 'Ещё одна акция с тем же кодом', 'fixed', 500.00,
            now() + interval '7 day');
EXCEPTION
    WHEN unique_violation THEN
        RAISE NOTICE 'Такой промокод уже существует: при вводе кода было бы непонятно, какую из двух акций применять. Текст ошибки: %', SQLERRM;
END;
$$;


-- =============================================================================
--  ДЕМОНСТРАЦИЯ 4 — нарушение NOT NULL
-- =============================================================================

DO $$
BEGIN
    -- попытка завести акцию, не указав сам код
    INSERT INTO promo_codes (code, description, discount_kind, discount_value, valid_to)
    VALUES (NULL, 'Акция без кода', 'fixed', 200.00, now() + interval '7 day');
EXCEPTION
    WHEN not_null_violation THEN
        RAISE NOTICE 'Нельзя создать акцию без промокода: пользователю нечего будет ввести при оформлении заказа. Текст ошибки: %', SQLERRM;
END;
$$;


-- =============================================================================
--  ДЕМОНСТРАЦИЯ 5 — нарушение ссылочной целостности при удалении
--                    (FOREIGN KEY с ON DELETE RESTRICT)
-- =============================================================================

DO $$
BEGIN
    -- попытка удалить промокод, по которому уже были оформлены заказы
    DELETE FROM promo_codes WHERE code = 'WELCOME300';
EXCEPTION
    WHEN foreign_key_violation THEN
        RAISE NOTICE 'Нельзя удалить промокод: по нему уже прошли заказы, и суммы в старых чеках перестали бы сходиться. Текст ошибки: %', SQLERRM;
END;
$$;


-- =============================================================================
DO $$
BEGIN
    RAISE NOTICE 'Все пять демонстраций выполнены, данные остались целыми: промокодов — %, применений — %',
        (SELECT count(*) FROM promo_codes),
        (SELECT count(*) FROM order_promotions);
END $$;
