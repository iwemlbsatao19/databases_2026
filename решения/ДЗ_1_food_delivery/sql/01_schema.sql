-- =============================================================================
--  Домашнее задание №1. Вариант №2 — Служба доставки еды (Food Delivery)
--  Задание 3. Физическая модель для PostgreSQL 16
-- =============================================================================
--  Скрипт ИДЕМПОТЕНТЕН: вся модель живёт в отдельной схеме food_delivery,
--  которая пересоздаётся при каждом прогоне. Повторный запуск даёт ровно тот
--  же результат (требование «SQL-скрипт должен быть воспроизводим»).
--
--  Запуск:
--      psql -U postgres -d postgres -f 01_schema.sql
-- =============================================================================

DROP SCHEMA IF EXISTS food_delivery CASCADE;
CREATE SCHEMA food_delivery;
SET search_path = food_delivery, public;


-- =============================================================================
--  0. ПЕРЕЧИСЛИМЫЕ ТИПЫ
-- =============================================================================
-- Бизнес-требование: «Продумайте, как хранить статус заказа».
-- Домен статусов маленький и меняется раз в год — это классический случай для
-- ENUM: значение хранится в 4 байтах, проверка корректности выполняется самим
-- типом (не нужен CHECK), опечатка вида 'delivred' отсекается на этапе INSERT.
CREATE TYPE order_status AS ENUM (
    'created',           -- заказ создан пользователем, ждёт подтверждения
    'confirmed',         -- ресторан подтвердил заказ
    'cooking',           -- готовится
    'ready_for_pickup',  -- готов, ждёт курьера
    'in_delivery',       -- передан курьеру
    'delivered',         -- доставлен (терминальный успешный статус)
    'cancelled'          -- отменён (терминальный неуспешный статус)
);

CREATE TYPE payment_method AS ENUM (
    'card_online',       -- картой на сайте
    'card_courier',      -- картой курьеру
    'cash',              -- наличными
    'sbp'                -- СБП
);


-- =============================================================================
--  1. USERS — пользователи сервиса
-- =============================================================================
-- Требование: «Пользователи могут просматривать рестораны, делать заказы,
-- оставлять отзывы» → пользователь является самостоятельной сущностью.
CREATE TABLE users (
    user_id     BIGINT       GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    full_name   VARCHAR(150) NOT NULL,
    -- Регистрация в сервисах доставки идёт по телефону → он обязателен и
    -- уникален (это фактический бизнес-ключ, естественный идентификатор).
    phone       VARCHAR(20)  NOT NULL UNIQUE,
    -- Email необязателен: пользователь может зарегистрироваться только по
    -- телефону. NULL допустим, но если указан — должен быть уникальным.
    email       VARCHAR(254) UNIQUE,
    created_at  TIMESTAMPTZ  NOT NULL DEFAULT now(),
    -- Пользователя не удаляют физически (у него есть заказы = финансовые
    -- документы), а деактивируют.
    is_active   BOOLEAN      NOT NULL DEFAULT TRUE,

    CONSTRAINT chk_users_full_name_not_blank
        CHECK (length(btrim(full_name)) > 0),
    CONSTRAINT chk_users_phone_format
        CHECK (phone ~ '^\+?[0-9]{10,15}$'),
    CONSTRAINT chk_users_email_format
        CHECK (email IS NULL OR email ~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$')
);

COMMENT ON TABLE  users IS 'Клиенты сервиса доставки';
COMMENT ON COLUMN users.phone IS 'Бизнес-ключ: регистрация и вход выполняются по номеру телефона';


-- =============================================================================
--  2. USER_ADDRESSES — адреса доставки пользователя
-- =============================================================================
-- Требование: заказ нужно куда-то доставить, а у пользователя обычно несколько
-- сохранённых адресов (дом, работа) → связь 1:N, отдельная сущность.
-- Поле district дополнительно обслуживает частый запрос №1 («рестораны,
-- работающие в этом районе»).
CREATE TABLE user_addresses (
    address_id  BIGINT       GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_id     BIGINT       NOT NULL,
    city        VARCHAR(100) NOT NULL,
    district    VARCHAR(100),
    street      VARCHAR(150) NOT NULL,
    building    VARCHAR(20)  NOT NULL,
    apartment   VARCHAR(20),
    -- Координаты нужны для подбора ближайшего ресторана и расчёта доставки.
    latitude    NUMERIC(9,6),
    longitude   NUMERIC(9,6),
    is_default  BOOLEAN      NOT NULL DEFAULT FALSE,

    CONSTRAINT fk_user_addresses_user
        FOREIGN KEY (user_id) REFERENCES users (user_id)
        ON UPDATE CASCADE
        -- Адрес не существует без пользователя (существование-зависимая
        -- сущность) → удаление пользователя удаляет его адреса.
        ON DELETE CASCADE,
    CONSTRAINT chk_user_addresses_latitude
        CHECK (latitude IS NULL OR latitude BETWEEN -90 AND 90),
    CONSTRAINT chk_user_addresses_longitude
        CHECK (longitude IS NULL OR longitude BETWEEN -180 AND 180),
    -- Один и тот же адрес не должен дублироваться в списке пользователя.
    CONSTRAINT uq_user_addresses_unique_per_user
        UNIQUE (user_id, city, street, building, apartment)
);

COMMENT ON TABLE user_addresses IS 'Сохранённые адреса доставки пользователя';


-- =============================================================================
--  3. RESTAURANTS — рестораны
-- =============================================================================
-- Требование: «Пользователи могут просматривать рестораны, их меню».
CREATE TABLE restaurants (
    restaurant_id BIGINT       GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name          VARCHAR(150) NOT NULL,
    -- district вынесен в отдельную колонку (а не спрятан в address_text),
    -- потому что по нему идёт частый запрос №1 и строится индекс.
    city          VARCHAR(100) NOT NULL,
    district      VARCHAR(100) NOT NULL,
    address_text  VARCHAR(300) NOT NULL,
    phone         VARCHAR(20)  NOT NULL,
    latitude      NUMERIC(9,6),
    longitude     NUMERIC(9,6),
    -- Денормализованный агрегат: средний рейтинг и число отзывов.
    -- Обоснование: запрос «рестораны с рейтингом выше 4.5» выполняется на
    -- каждой загрузке главной страницы. Считать AVG(rating) по всем отзывам
    -- при каждом открытии — это JOIN + GROUP BY по самой большой таблице.
    -- Поэтому агрегат материализуется здесь и обновляется триггером/джобой.
    rating        NUMERIC(2,1) NOT NULL DEFAULT 0,
    reviews_count INTEGER      NOT NULL DEFAULT 0,
    opens_at      TIME         NOT NULL,
    closes_at     TIME         NOT NULL,
    is_active     BOOLEAN      NOT NULL DEFAULT TRUE,
    created_at    TIMESTAMPTZ  NOT NULL DEFAULT now(),

    CONSTRAINT chk_restaurants_rating
        CHECK (rating BETWEEN 0 AND 5),
    CONSTRAINT chk_restaurants_reviews_count
        CHECK (reviews_count >= 0),
    CONSTRAINT chk_restaurants_phone_format
        CHECK (phone ~ '^\+?[0-9]{10,15}$'),
    CONSTRAINT chk_restaurants_latitude
        CHECK (latitude IS NULL OR latitude BETWEEN -90 AND 90),
    CONSTRAINT chk_restaurants_longitude
        CHECK (longitude IS NULL OR longitude BETWEEN -180 AND 180),
    -- Сеть ресторанов может иметь одно название, но не по одному адресу.
    CONSTRAINT uq_restaurants_name_address
        UNIQUE (name, address_text)
);

COMMENT ON COLUMN restaurants.rating IS 'Денормализованный средний рейтинг (0..5) для быстрой фильтрации витрины';


-- =============================================================================
--  4. DISHES — блюда меню
-- =============================================================================
-- Требование: «У каждого ресторана есть меню с блюдами» → связь 1:N.
-- Блюдо принадлежит ровно одному ресторану и не существует без него.
CREATE TABLE dishes (
    dish_id       BIGINT        GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    restaurant_id BIGINT        NOT NULL,
    name          VARCHAR(150)  NOT NULL,
    description   TEXT,
    category      VARCHAR(30)   NOT NULL,
    -- Деньги — только NUMERIC с фиксированной точностью. Тип money и
    -- float/double для валют использовать нельзя: ошибки округления.
    price         NUMERIC(10,2) NOT NULL,
    weight_grams  INTEGER,
    -- «Блюдо закончилось» — это не удаление блюда: на него уже ссылаются
    -- позиции прошлых заказов. Поэтому флаг доступности.
    is_available  BOOLEAN       NOT NULL DEFAULT TRUE,
    created_at    TIMESTAMPTZ   NOT NULL DEFAULT now(),

    CONSTRAINT fk_dishes_restaurant
        FOREIGN KEY (restaurant_id) REFERENCES restaurants (restaurant_id)
        ON UPDATE CASCADE
        ON DELETE CASCADE,
    CONSTRAINT chk_dishes_price_positive
        CHECK (price > 0),
    CONSTRAINT chk_dishes_weight_positive
        CHECK (weight_grams IS NULL OR weight_grams > 0),
    -- Демонстрация альтернативы ENUM: небольшой изменчивый домен на CHECK.
    -- Отличие от ENUM: менять список значений можно обычным ALTER ... CHECK
    -- внутри транзакции, но при этом проверяются все существующие строки.
    CONSTRAINT chk_dishes_category
        CHECK (category IN ('soup', 'main', 'salad', 'dessert', 'drink', 'snack')),
    -- В одном меню не может быть двух блюд с одинаковым названием.
    CONSTRAINT uq_dishes_restaurant_name
        UNIQUE (restaurant_id, name)
);

COMMENT ON COLUMN dishes.price IS 'Текущая цена. Историю цен хранит dish_price_history';


-- =============================================================================
--  5. DISH_PRICE_HISTORY — история цен блюда
-- =============================================================================
-- Дополнительная рекомендация задания: «Подумайте, как хранить актуальное меню
-- ресторана (изменение цен/состава со временем)».
-- Решение: интервальное версионирование (valid_from / valid_to).
-- Строка с valid_to IS NULL — цена, действующая прямо сейчас.
CREATE TABLE dish_price_history (
    price_history_id BIGINT        GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    dish_id          BIGINT        NOT NULL,
    price            NUMERIC(10,2) NOT NULL,
    valid_from       TIMESTAMPTZ   NOT NULL DEFAULT now(),
    valid_to         TIMESTAMPTZ,
    changed_by       VARCHAR(50)   NOT NULL DEFAULT 'system',

    CONSTRAINT fk_dish_price_history_dish
        FOREIGN KEY (dish_id) REFERENCES dishes (dish_id)
        ON UPDATE CASCADE
        ON DELETE CASCADE,
    CONSTRAINT chk_dish_price_history_price_positive
        CHECK (price > 0),
    CONSTRAINT chk_dish_price_history_period
        CHECK (valid_to IS NULL OR valid_to > valid_from)
);

COMMENT ON TABLE dish_price_history IS 'Версионирование цен: valid_to IS NULL = действующая цена';


-- =============================================================================
--  6. COURIERS — курьеры
-- =============================================================================
-- Требование: «Курьеры доставляют заказы» → отдельная сущность, потому что у
-- курьера свой жизненный цикл, рейтинг и статистика.
CREATE TABLE couriers (
    courier_id       BIGINT       GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    full_name        VARCHAR(150) NOT NULL,
    phone            VARCHAR(20)  NOT NULL UNIQUE,
    vehicle_type     VARCHAR(20)  NOT NULL,
    rating           NUMERIC(2,1) NOT NULL DEFAULT 0,
    -- Денормализованный счётчик под частый запрос №5 («курьеры, выполнившие
    -- более 100 заказов»): иначе на каждый вызов пришлось бы считать COUNT
    -- по всей таблице orders.
    completed_orders INTEGER      NOT NULL DEFAULT 0,
    is_active        BOOLEAN      NOT NULL DEFAULT TRUE,
    hired_at         DATE         NOT NULL DEFAULT CURRENT_DATE,

    CONSTRAINT chk_couriers_phone_format
        CHECK (phone ~ '^\+?[0-9]{10,15}$'),
    CONSTRAINT chk_couriers_vehicle_type
        CHECK (vehicle_type IN ('foot', 'bike', 'scooter', 'car')),
    CONSTRAINT chk_couriers_rating
        CHECK (rating BETWEEN 0 AND 5),
    CONSTRAINT chk_couriers_completed_orders
        CHECK (completed_orders >= 0)
);


-- =============================================================================
--  7. ORDERS — заказы
-- =============================================================================
-- Центральная сущность. Требование: «Пользователи делают заказы»,
-- «Курьеры доставляют заказы».
CREATE TABLE orders (
    order_id              BIGINT         GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_id               BIGINT         NOT NULL,
    restaurant_id         BIGINT         NOT NULL,
    -- Курьер назначается не сразу: сразу после создания заказа его ещё нет.
    -- Поэтому колонка NULLable — это отражает необязательность связи (0..1).
    courier_id            BIGINT,
    address_id            BIGINT,
    -- Снимок адреса на момент заказа: пользователь может потом изменить или
    -- удалить сохранённый адрес, но в истории заказа должно остаться то, куда
    -- реально везли.
    delivery_address_text VARCHAR(300)   NOT NULL,
    status                order_status   NOT NULL DEFAULT 'created',
    payment_method        payment_method NOT NULL,
    items_total           NUMERIC(12,2)  NOT NULL DEFAULT 0,
    delivery_fee          NUMERIC(10,2)  NOT NULL DEFAULT 0,
    -- Генерируемый столбец: итог всегда согласован с составляющими,
    -- рассинхронизация физически невозможна.
    total_amount          NUMERIC(12,2)  GENERATED ALWAYS AS (items_total + delivery_fee) STORED,
    created_at            TIMESTAMPTZ    NOT NULL DEFAULT now(),
    delivered_at          TIMESTAMPTZ,
    cancelled_at          TIMESTAMPTZ,

    CONSTRAINT fk_orders_user
        FOREIGN KEY (user_id) REFERENCES users (user_id)
        ON UPDATE CASCADE
        -- Заказ — финансовый документ. Удалить пользователя, у которого есть
        -- заказы, нельзя: сначала разберись с историей.
        ON DELETE RESTRICT,
    CONSTRAINT fk_orders_restaurant
        FOREIGN KEY (restaurant_id) REFERENCES restaurants (restaurant_id)
        ON UPDATE CASCADE
        ON DELETE RESTRICT,
    CONSTRAINT fk_orders_courier
        FOREIGN KEY (courier_id) REFERENCES couriers (courier_id)
        ON UPDATE CASCADE
        -- Курьер уволился — заказ остаётся, ссылка обнуляется.
        ON DELETE SET NULL,
    CONSTRAINT fk_orders_address
        FOREIGN KEY (address_id) REFERENCES user_addresses (address_id)
        ON UPDATE CASCADE
        -- Адрес удалён из справочника — заказ живёт дальше за счёт снимка
        -- в delivery_address_text.
        ON DELETE SET NULL,

    CONSTRAINT chk_orders_items_total
        CHECK (items_total >= 0),
    CONSTRAINT chk_orders_delivery_fee
        CHECK (delivery_fee >= 0),
    CONSTRAINT chk_orders_delivered_after_created
        CHECK (delivered_at IS NULL OR delivered_at >= created_at),
    CONSTRAINT chk_orders_cancelled_after_created
        CHECK (cancelled_at IS NULL OR cancelled_at >= created_at),
    -- Сложный CHECK: статус и отметки времени не могут противоречить друг
    -- другу. Заказ «доставлен» тогда и только тогда, когда есть время доставки.
    CONSTRAINT chk_orders_delivered_consistency
        CHECK ((status = 'delivered') = (delivered_at IS NOT NULL)),
    CONSTRAINT chk_orders_cancelled_consistency
        CHECK ((status = 'cancelled') = (cancelled_at IS NOT NULL))
);

COMMENT ON COLUMN orders.delivery_address_text IS 'Снимок адреса на момент оформления заказа';
COMMENT ON COLUMN orders.total_amount IS 'Генерируемый столбец: items_total + delivery_fee';


-- =============================================================================
--  8. ORDER_ITEMS — позиции заказа (разрешение связи M:N)
-- =============================================================================
-- Требование: «В заказе может быть несколько блюд с указанием количества».
-- Логически это связь many-to-many между orders и dishes. В реляционной модели
-- M:N не представима напрямую → вводится ассоциативная сущность с составным
-- первичным ключом (order_id, dish_id). Это ИДЕНТИФИЦИРУЮЩАЯ связь: позиция
-- заказа не имеет смысла и не может быть идентифицирована вне своего заказа.
CREATE TABLE order_items (
    order_id   BIGINT        NOT NULL,
    dish_id    BIGINT        NOT NULL,
    quantity   INTEGER       NOT NULL,
    -- Снимок цены на момент заказа. Ключевое решение: если брать цену
    -- JOIN-ом из dishes, то после подорожания блюда исторические чеки
    -- «задним числом» изменятся, и выручка за прошлый месяц перестанет
    -- сходиться с реально полученными деньгами.
    unit_price NUMERIC(10,2) NOT NULL,
    line_total NUMERIC(12,2) GENERATED ALWAYS AS (quantity * unit_price) STORED,

    CONSTRAINT pk_order_items PRIMARY KEY (order_id, dish_id),
    CONSTRAINT fk_order_items_order
        FOREIGN KEY (order_id) REFERENCES orders (order_id)
        ON UPDATE CASCADE
        -- Удаление заказа удаляет его позиции — они часть заказа.
        ON DELETE CASCADE,
    CONSTRAINT fk_order_items_dish
        FOREIGN KEY (dish_id) REFERENCES dishes (dish_id)
        ON UPDATE CASCADE
        -- Блюдо, которое хоть раз заказывали, удалять нельзя — иначе теряется
        -- история продаж. Снимать с продажи нужно через dishes.is_available.
        ON DELETE RESTRICT,
    CONSTRAINT chk_order_items_quantity_positive
        CHECK (quantity > 0),
    CONSTRAINT chk_order_items_unit_price_positive
        CHECK (unit_price > 0)
);

COMMENT ON TABLE order_items IS 'Ассоциативная сущность, разрешающая M:N между orders и dishes';


-- =============================================================================
--  9. ORDER_STATUS_HISTORY — история смены статусов заказа (аудит)
-- =============================================================================
-- Дополнительная рекомендация: «Продумайте, как хранить статус заказа».
-- Текущий статус лежит в orders.status (быстро читается), а полная история
-- переходов — здесь. Это позволяет отвечать на вопросы «сколько заказ ждал
-- курьера» и «кто отменил заказ».
CREATE TABLE order_status_history (
    status_history_id BIGINT       GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    order_id          BIGINT       NOT NULL,
    old_status        order_status,          -- NULL для самой первой записи
    new_status        order_status NOT NULL,
    changed_at        TIMESTAMPTZ  NOT NULL DEFAULT now(),
    -- Кто изменил: 'system', 'operator:15', 'courier:42'.
    changed_by        VARCHAR(50)  NOT NULL,
    reason            TEXT,

    CONSTRAINT fk_order_status_history_order
        FOREIGN KEY (order_id) REFERENCES orders (order_id)
        ON UPDATE CASCADE
        ON DELETE CASCADE,
    -- Запись в журнал имеет смысл только если статус действительно изменился.
    -- IS DISTINCT FROM корректно работает с NULL в old_status.
    CONSTRAINT chk_order_status_history_changed
        CHECK (old_status IS DISTINCT FROM new_status)
);


-- =============================================================================
--  10. REVIEWS — отзывы
-- =============================================================================
-- Требование: «Пользователи могут оставлять отзывы о ресторанах и доставке».
-- Отзыв привязан к КОНКРЕТНОМУ ЗАКАЗУ, а не просто к ресторану: так нельзя
-- оценить ресторан, в котором ты ничего не заказывал, и автоматически
-- выполняется правило «один заказ — один отзыв».
CREATE TABLE reviews (
    review_id         BIGINT      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    -- UNIQUE на order_id реализует кардинальность 1:1 между заказом и отзывом.
    order_id          BIGINT      NOT NULL UNIQUE,
    user_id           BIGINT      NOT NULL,
    restaurant_id     BIGINT      NOT NULL,
    courier_id        BIGINT,
    -- Две независимые оценки: еде и доставке. Обе необязательны по
    -- отдельности — пользователь может оценить только еду.
    restaurant_rating SMALLINT,
    courier_rating    SMALLINT,
    comment           TEXT,
    created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT fk_reviews_order
        FOREIGN KEY (order_id) REFERENCES orders (order_id)
        ON UPDATE CASCADE
        ON DELETE CASCADE,
    CONSTRAINT fk_reviews_user
        FOREIGN KEY (user_id) REFERENCES users (user_id)
        ON UPDATE CASCADE
        ON DELETE CASCADE,
    CONSTRAINT fk_reviews_restaurant
        FOREIGN KEY (restaurant_id) REFERENCES restaurants (restaurant_id)
        ON UPDATE CASCADE
        ON DELETE CASCADE,
    CONSTRAINT fk_reviews_courier
        FOREIGN KEY (courier_id) REFERENCES couriers (courier_id)
        ON UPDATE CASCADE
        ON DELETE SET NULL,

    -- Шкала оценок 1..5 — прямое бизнес-требование.
    CONSTRAINT chk_reviews_restaurant_rating
        CHECK (restaurant_rating IS NULL OR restaurant_rating BETWEEN 1 AND 5),
    CONSTRAINT chk_reviews_courier_rating
        CHECK (courier_rating IS NULL OR courier_rating BETWEEN 1 AND 5),
    -- Пустой отзыв (ни оценки, ни текста) смысла не имеет.
    CONSTRAINT chk_reviews_not_empty
        CHECK (restaurant_rating IS NOT NULL
               OR courier_rating IS NOT NULL
               OR length(btrim(coalesce(comment, ''))) > 0)
);


-- =============================================================================
--  ИНДЕКСЫ
-- =============================================================================
--  Правило 1: PostgreSQL НЕ создаёт индексы под внешние ключи автоматически
--  (в отличие от MySQL/InnoDB). Без них каждое удаление или обновление
--  родительской строки приводит к полному сканированию дочерней таблицы, а
--  JOIN по FK работает через Seq Scan. Поэтому индексируем все FK явно.
--  Правило 2: остальные индексы построены под 5 частых запросов из Задания 4.
-- =============================================================================

-- --- Индексы на внешние ключи (обязательное требование задания) -------------
CREATE INDEX idx_user_addresses_user_id       ON user_addresses (user_id);
CREATE INDEX idx_dishes_restaurant_id         ON dishes (restaurant_id);
CREATE INDEX idx_dish_price_history_dish_id   ON dish_price_history (dish_id);
CREATE INDEX idx_orders_user_id               ON orders (user_id);
CREATE INDEX idx_orders_restaurant_id         ON orders (restaurant_id);
CREATE INDEX idx_orders_courier_id            ON orders (courier_id);
CREATE INDEX idx_orders_address_id            ON orders (address_id);
-- order_items.order_id уже покрыт первым столбцом составного PK, поэтому
-- отдельный индекс для него был бы избыточен. А вот dish_id — второй столбец
-- PK, по нему поиск неэффективен, индексируем отдельно.
CREATE INDEX idx_order_items_dish_id          ON order_items (dish_id);
CREATE INDEX idx_order_status_history_order   ON order_status_history (order_id, changed_at);
CREATE INDEX idx_reviews_user_id              ON reviews (user_id);
CREATE INDEX idx_reviews_restaurant_id        ON reviews (restaurant_id);
CREATE INDEX idx_reviews_courier_id           ON reviews (courier_id);

-- --- Индексы под частые запросы ---------------------------------------------

-- Запрос №1: «рестораны с рейтингом выше 4.5, работающие в этом районе».
-- Частичный составной индекс: неактивные рестораны в витрину не попадают
-- никогда, поэтому их можно вообще не хранить в индексе.
CREATE INDEX idx_restaurants_district_rating
    ON restaurants (city, district, rating DESC)
    WHERE is_active;

-- Запрос №2: «топ-10 блюд по количеству заказов за последнюю неделю».
-- Фильтр по дате — по orders, группировка — по order_items.dish_id.
CREATE INDEX idx_orders_created_at ON orders (created_at DESC);

-- Запрос №4: «выручка каждого ресторана за текущий месяц».
-- INCLUDE делает индекс покрывающим: сумму можно посчитать, не заглядывая
-- в саму таблицу (Index Only Scan).
CREATE INDEX idx_orders_restaurant_revenue
    ON orders (restaurant_id, created_at)
    INCLUDE (total_amount)
    WHERE status = 'delivered';

-- Запрос №5: «курьеры, выполнившие более 100 заказов и с высоким рейтингом».
CREATE INDEX idx_couriers_stats
    ON couriers (completed_orders DESC, rating DESC)
    WHERE is_active;

-- Витрина меню: «показать доступные блюда ресторана по категориям».
CREATE INDEX idx_dishes_available_menu
    ON dishes (restaurant_id, category)
    WHERE is_available;

-- --- Уникальные частичные индексы (бизнес-правила) ---------------------------

-- У пользователя может быть только ОДИН адрес по умолчанию.
-- Обычный UNIQUE (user_id, is_default) это правило не выразит: он запретил бы
-- и два неосновных адреса тоже. Нужен именно частичный уникальный индекс.
CREATE UNIQUE INDEX uq_user_addresses_one_default
    ON user_addresses (user_id)
    WHERE is_default;

-- У блюда может быть только ОДНА действующая цена (valid_to IS NULL).
CREATE UNIQUE INDEX uq_dish_price_history_one_current
    ON dish_price_history (dish_id)
    WHERE valid_to IS NULL;


-- =============================================================================
--  ГОТОВО
-- =============================================================================
DO $$
BEGIN
    RAISE NOTICE 'Схема food_delivery создана: % таблиц',
        (SELECT count(*) FROM information_schema.tables
          WHERE table_schema = 'food_delivery' AND table_type = 'BASE TABLE');
END $$;
