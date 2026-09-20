-- =============================================================================
--  ДЗ №2. Часть 1. Дополнение схемы: две новые таблицы
--  Вариант №2 — Служба доставки еды. PostgreSQL 16.
-- =============================================================================
--  Работает поверх схемы food_delivery, созданной в ДЗ №1 (01_schema.sql).
--  Скрипт идемпотентен: повторный запуск даёт тот же результат.
--
--      psql -U postgres -d postgres -f 01_hw2_tables.sql
-- =============================================================================

SET search_path = food_delivery, public;


-- =============================================================================
--  1. PROMO_CODES — промокоды и акции
-- =============================================================================
-- Зачем: скидки есть в любом сервисе доставки, а в модели ДЗ №1 их не было.
-- Промокод может действовать во всех ресторанах сразу (restaurant_id IS NULL)
-- либо только в одном — отсюда необязательный внешний ключ.

DROP TABLE IF EXISTS order_promotions CASCADE;
DROP TABLE IF EXISTS promo_codes CASCADE;
DROP TYPE  IF EXISTS discount_type CASCADE;

CREATE TYPE discount_type AS ENUM (
    'percent',        -- скидка в процентах от суммы блюд
    'fixed',          -- фиксированная скидка в рублях
    'free_delivery'   -- бесплатная доставка
);

CREATE TABLE promo_codes (
    promo_code_id    BIGINT        GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    -- Код, который вводит пользователь. Бизнес-ключ: двух акций с одним
    -- кодом быть не может, иначе непонятно, какую применять.
    code             VARCHAR(32)   NOT NULL UNIQUE,
    description      VARCHAR(200)  NOT NULL,
    discount_kind    discount_type NOT NULL,
    discount_value   NUMERIC(10,2) NOT NULL,
    -- Минимальная сумма заказа, при которой промокод срабатывает.
    min_order_amount NUMERIC(10,2) NOT NULL DEFAULT 0,
    -- NULL = акция действует во всех ресторанах сервиса.
    restaurant_id    BIGINT,
    valid_from       TIMESTAMPTZ   NOT NULL DEFAULT now(),
    valid_to         TIMESTAMPTZ   NOT NULL,
    -- NULL = число использований не ограничено.
    usage_limit      INTEGER,
    used_count       INTEGER       NOT NULL DEFAULT 0,
    is_active        BOOLEAN       NOT NULL DEFAULT TRUE,
    created_at       TIMESTAMPTZ   NOT NULL DEFAULT now(),

    CONSTRAINT fk_promo_codes_restaurant
        FOREIGN KEY (restaurant_id) REFERENCES restaurants (restaurant_id)
        ON UPDATE CASCADE
        -- Ресторан ушёл с платформы — его частные акции уходят вместе с ним.
        ON DELETE CASCADE,

    CONSTRAINT chk_promo_codes_code_format
        CHECK (code ~ '^[A-Z0-9_-]{4,32}$'),
    CONSTRAINT chk_promo_codes_value_positive
        CHECK (discount_value > 0),
    -- Сложный CHECK: ограничение зависит от значения соседней колонки.
    -- Процентная скидка больше 100% означала бы доплату клиенту.
    CONSTRAINT chk_promo_codes_percent_range
        CHECK (discount_kind <> 'percent' OR discount_value <= 100),
    CONSTRAINT chk_promo_codes_min_order
        CHECK (min_order_amount >= 0),
    CONSTRAINT chk_promo_codes_period
        CHECK (valid_to > valid_from),
    CONSTRAINT chk_promo_codes_usage_limit
        CHECK (usage_limit IS NULL OR usage_limit > 0),
    CONSTRAINT chk_promo_codes_used_count
        CHECK (used_count >= 0),
    CONSTRAINT chk_promo_codes_not_over_limit
        CHECK (usage_limit IS NULL OR used_count <= usage_limit)
);

COMMENT ON TABLE  promo_codes IS 'Промокоды и акции сервиса';
COMMENT ON COLUMN promo_codes.restaurant_id IS 'NULL = акция действует во всех ресторанах';


-- =============================================================================
--  2. ORDER_PROMOTIONS — применение промокодов к заказам (разрешение M:N)
-- =============================================================================
-- Связь «заказ ↔ промокод» логически многие-ко-многим:
--   * один промокод применяют тысячи пользователей к своим заказам;
--   * к одному заказу можно применить несколько промокодов одновременно
--     (например, «бесплатная доставка» и «300 рублей на первый заказ»).
-- Реляционная модель не выражает M:N напрямую, поэтому вводится
-- ассоциативная таблица с составным первичным ключом.

CREATE TABLE order_promotions (
    order_id        BIGINT        NOT NULL,
    promo_code_id   BIGINT        NOT NULL,
    -- Снимок: сколько рублей скидки дал этот промокод именно в этом заказе.
    -- Хранится, а не пересчитывается, потому что условия акции могли
    -- измениться после оформления заказа.
    discount_amount NUMERIC(10,2) NOT NULL,
    applied_at      TIMESTAMPTZ   NOT NULL DEFAULT now(),

    -- Составной PK: он же бизнес-правило «один промокод применяется
    -- к одному заказу не более одного раза».
    CONSTRAINT pk_order_promotions PRIMARY KEY (order_id, promo_code_id),

    CONSTRAINT fk_order_promotions_order
        FOREIGN KEY (order_id) REFERENCES orders (order_id)
        ON UPDATE CASCADE
        -- Применение скидки — часть заказа, отдельно от него не существует.
        ON DELETE CASCADE,
    CONSTRAINT fk_order_promotions_promo
        FOREIGN KEY (promo_code_id) REFERENCES promo_codes (promo_code_id)
        ON UPDATE CASCADE
        -- Промокод, который хоть раз применялся, удалять нельзя: это исказит
        -- финансовую историю. Для вывода из обращения есть is_active.
        ON DELETE RESTRICT,

    CONSTRAINT chk_order_promotions_amount
        CHECK (discount_amount > 0)
);

COMMENT ON TABLE order_promotions IS 'Ассоциативная таблица: разрешение M:N между orders и promo_codes';


-- =============================================================================
--  3. АКТУАЛИЗАЦИЯ СУЩЕСТВУЮЩЕЙ ТАБЛИЦЫ ORDERS
-- =============================================================================
-- Скидка, которая не влияет на сумму заказа, — фикция. Поэтому в orders
-- добавляется discount_total, а вычисляемый total_amount пересобирается
-- с его учётом.
--
-- Побочный эффект, который нужно учесть: total_amount входит в покрывающий
-- индекс idx_orders_restaurant_revenue (частый запрос №4 из ДЗ №1).
-- DROP COLUMN удаляет индекс вместе с колонкой, поэтому индекс создаётся
-- заново — иначе отчёт о выручке потерял бы Index Only Scan.

ALTER TABLE orders DROP COLUMN IF EXISTS total_amount;

ALTER TABLE orders ADD COLUMN IF NOT EXISTS
    discount_total NUMERIC(10,2) NOT NULL DEFAULT 0;

ALTER TABLE orders DROP CONSTRAINT IF EXISTS chk_orders_discount_nonneg;
ALTER TABLE orders ADD  CONSTRAINT chk_orders_discount_nonneg
    CHECK (discount_total >= 0);

-- Скидка не может превышать стоимость самого заказа: отрицательный чек
-- означал бы, что сервис доплачивает клиенту.
ALTER TABLE orders DROP CONSTRAINT IF EXISTS chk_orders_discount_not_over_total;
ALTER TABLE orders ADD  CONSTRAINT chk_orders_discount_not_over_total
    CHECK (discount_total <= items_total + delivery_fee);

ALTER TABLE orders ADD COLUMN total_amount NUMERIC(12,2)
    GENERATED ALWAYS AS (items_total + delivery_fee - discount_total) STORED;

CREATE INDEX IF NOT EXISTS idx_orders_restaurant_revenue
    ON orders (restaurant_id, created_at)
    INCLUDE (total_amount)
    WHERE status = 'delivered';


-- =============================================================================
--  4. ИНДЕКСЫ НОВЫХ ТАБЛИЦ
-- =============================================================================

-- Внешние ключи. PostgreSQL не индексирует их автоматически.
CREATE INDEX idx_promo_codes_restaurant_id      ON promo_codes (restaurant_id);
CREATE INDEX idx_order_promotions_promo_code_id ON order_promotions (promo_code_id);
-- order_promotions.order_id отдельного индекса не требует: он уже первый
-- столбец составного PK, поиск по нему покрыт индексом первичного ключа.

-- Витрина «какие акции идут прямо сейчас»: неактивные промокоды в неё
-- не попадают никогда, поэтому индекс частичный.
CREATE INDEX idx_promo_codes_active_period
    ON promo_codes (valid_from, valid_to)
    WHERE is_active;

-- Проверка промокода при оформлении заказа — поиск по коду среди
-- действующих. Уникальный индекс по code создан ограничением UNIQUE,
-- здесь добавляется частичный для самого горячего случая.
CREATE INDEX idx_promo_codes_lookup
    ON promo_codes (code)
    INCLUDE (discount_kind, discount_value, min_order_amount)
    WHERE is_active;

-- «Сколько раз использован промокод» и «какие заказы прошли по акции» —
-- обслуживаются idx_order_promotions_promo_code_id.


-- =============================================================================
DO $$
BEGIN
    RAISE NOTICE 'Часть 1 выполнена: добавлено % таблицы',
        (SELECT count(*) FROM information_schema.tables
          WHERE table_schema = 'food_delivery'
            AND table_name IN ('promo_codes', 'order_promotions'));
END $$;
