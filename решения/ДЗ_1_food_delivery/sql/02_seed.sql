-- =============================================================================
--  Тестовые данные для схемы food_delivery
--  Запуск ПОСЛЕ 01_schema.sql:
--      psql -U postgres -d postgres -f 02_seed.sql
-- =============================================================================
SET search_path = food_delivery, public;

-- --- Пользователи ------------------------------------------------------------
INSERT INTO users (full_name, phone, email) VALUES
    ('Иванов Иван Иванович',    '+79001112233', 'ivanov@example.com'),
    ('Петрова Анна Сергеевна',  '+79004445566', 'petrova@example.com'),
    ('Сидоров Пётр Алексеевич', '+79007778899', NULL);   -- регистрация без email

-- --- Адреса ------------------------------------------------------------------
INSERT INTO user_addresses (user_id, city, district, street, building, apartment, is_default) VALUES
    (1, 'Москва', 'Хамовники',   'Льва Толстого', '16', '5',  TRUE),
    (1, 'Москва', 'Пресненский', 'Пресненская наб.', '12', '301', FALSE),
    (2, 'Москва', 'Хамовники',   'Комсомольский пр-т', '28', '14', TRUE),
    (3, 'Москва', 'Басманный',   'Бауманская', '7', NULL, TRUE);

-- --- Рестораны ---------------------------------------------------------------
INSERT INTO restaurants (name, city, district, address_text, phone, rating, reviews_count, opens_at, closes_at) VALUES
    ('Тарелка',    'Москва', 'Хамовники',   'ул. Льва Толстого, 1',  '+74951112233', 4.8, 120, '10:00', '23:00'),
    ('Пельменная', 'Москва', 'Хамовники',   'Комсомольский пр-т, 5', '+74952223344', 4.2,  45, '09:00', '22:00'),
    ('Сакура',     'Москва', 'Басманный',   'ул. Бауманская, 10',    '+74953334455', 4.9, 310, '11:00', '23:30'),
    ('Бургер Хаус','Москва', 'Пресненский', 'Пресненская наб., 8',   '+74954445566', 3.9,  88, '00:00', '23:59');

-- --- Блюда -------------------------------------------------------------------
INSERT INTO dishes (restaurant_id, name, description, category, price, weight_grams) VALUES
    (1, 'Борщ',            'Классический борщ со сметаной', 'soup',    390.00, 350),
    (1, 'Котлета по-киевски','С картофельным пюре',         'main',    690.00, 320),
    (1, 'Компот',          'Из сухофруктов',                'drink',   150.00, 300),
    (2, 'Пельмени домашние','Со сметаной',                  'main',    450.00, 300),
    (2, 'Салат Цезарь',    'С курицей',                     'salad',   420.00, 220),
    (3, 'Филадельфия',     'Ролл с лососем, 8 шт.',         'main',    790.00, 250),
    (3, 'Мисо-суп',        'Классический',                  'soup',    290.00, 250),
    (3, 'Моти',            'Десерт, 3 шт.',                 'dessert', 350.00, 120),
    (4, 'Чизбургер',       'Двойной',                       'main',    550.00, 280),
    (4, 'Картофель фри',   'Большая порция',                'snack',   220.00, 150);

-- --- История цен (текущая цена = строка с valid_to IS NULL) -------------------
INSERT INTO dish_price_history (dish_id, price, valid_from, valid_to, changed_by) VALUES
    (1, 350.00, now() - interval '6 month', now() - interval '2 month', 'manager:3'),
    (1, 390.00, now() - interval '2 month', NULL,                       'manager:3'),
    (6, 720.00, now() - interval '1 year',  now() - interval '3 month', 'manager:7'),
    (6, 790.00, now() - interval '3 month', NULL,                       'manager:7');

-- --- Курьеры -----------------------------------------------------------------
INSERT INTO couriers (full_name, phone, vehicle_type, rating, completed_orders) VALUES
    ('Смирнов Алексей Викторович', '+79101112233', 'bike',    4.9, 412),
    ('Кузнецов Дмитрий Олегович',  '+79102223344', 'car',     4.6, 155),
    ('Новиков Сергей Павлович',    '+79103334455', 'scooter', 4.1,  37);

-- --- Заказы ------------------------------------------------------------------
-- доставленный заказ
INSERT INTO orders (user_id, restaurant_id, courier_id, address_id, delivery_address_text,
                    status, payment_method, items_total, delivery_fee, created_at, delivered_at)
VALUES (1, 1, 1, 1, 'Москва, ул. Льва Толстого, 16, кв. 5',
        'delivered', 'card_online', 1080.00, 99.00,
        now() - interval '3 day', now() - interval '3 day' + interval '47 minute');

-- заказ в пути
INSERT INTO orders (user_id, restaurant_id, courier_id, address_id, delivery_address_text,
                    status, payment_method, items_total, delivery_fee, created_at)
VALUES (2, 3, 2, 3, 'Москва, Комсомольский пр-т, 28, кв. 14',
        'in_delivery', 'sbp', 1080.00, 0.00, now() - interval '25 minute');

-- только что созданный заказ, курьер ещё не назначен (courier_id IS NULL)
INSERT INTO orders (user_id, restaurant_id, courier_id, address_id, delivery_address_text,
                    status, payment_method, items_total, delivery_fee)
VALUES (3, 4, NULL, 4, 'Москва, ул. Бауманская, 7',
        'created', 'cash', 770.00, 149.00);

-- отменённый заказ
INSERT INTO orders (user_id, restaurant_id, courier_id, address_id, delivery_address_text,
                    status, payment_method, items_total, delivery_fee, created_at, cancelled_at)
VALUES (1, 2, NULL, 2, 'Москва, Пресненская наб., 12, кв. 301',
        'cancelled', 'card_courier', 870.00, 99.00,
        now() - interval '10 day', now() - interval '10 day' + interval '4 minute');

-- --- Позиции заказов ---------------------------------------------------------
INSERT INTO order_items (order_id, dish_id, quantity, unit_price) VALUES
    (1, 1, 1, 390.00),
    (1, 2, 1, 690.00),
    (2, 6, 1, 790.00),
    (2, 7, 1, 290.00),
    (3, 9, 1, 550.00),
    (3, 10, 1, 220.00),
    (4, 4, 1, 450.00),
    (4, 5, 1, 420.00);

-- --- История статусов --------------------------------------------------------
INSERT INTO order_status_history (order_id, old_status, new_status, changed_at, changed_by, reason) VALUES
    (1, NULL,               'created',          now() - interval '3 day',                        'user:1',     NULL),
    (1, 'created',          'confirmed',        now() - interval '3 day' + interval '2 minute',  'system',     NULL),
    (1, 'confirmed',        'cooking',          now() - interval '3 day' + interval '5 minute',  'operator:2', NULL),
    (1, 'cooking',          'ready_for_pickup', now() - interval '3 day' + interval '25 minute', 'operator:2', NULL),
    (1, 'ready_for_pickup', 'in_delivery',      now() - interval '3 day' + interval '30 minute', 'courier:1',  NULL),
    (1, 'in_delivery',      'delivered',        now() - interval '3 day' + interval '47 minute', 'courier:1',  NULL),
    (4, NULL,               'created',          now() - interval '10 day',                       'user:1',     NULL),
    (4, 'created',          'cancelled',        now() - interval '10 day' + interval '4 minute', 'user:1',     'Передумал');

-- --- Отзывы ------------------------------------------------------------------
INSERT INTO reviews (order_id, user_id, restaurant_id, courier_id, restaurant_rating, courier_rating, comment) VALUES
    (1, 1, 1, 1, 5, 5, 'Всё быстро и вкусно');

SELECT 'Тестовые данные загружены' AS status;
