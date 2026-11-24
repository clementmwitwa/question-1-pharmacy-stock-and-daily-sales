-- ICT371 Advanced Database | Question 1: Pharmacy Stock and Daily Sales
-- Student: Clement Mwitwa | Student No: 202406171 | PostgreSQL
-- Run order: top to bottom in one session (psql -f or pgAdmin Query Tool).

DROP SCHEMA IF EXISTS q1_pharmacy CASCADE;
CREATE SCHEMA q1_pharmacy;
SET search_path = q1_pharmacy, public;

/* ===================== (a) Database and seed data ===================== */
CREATE TABLE medicines (
    medicine_id   SERIAL PRIMARY KEY,
    medicine_name VARCHAR(100)  NOT NULL UNIQUE,
    unit_price    NUMERIC(10,2) NOT NULL CHECK (unit_price > 0),
    stock_qty     INTEGER       NOT NULL CHECK (stock_qty >= 0)
);

CREATE TABLE sales (
    sale_id     SERIAL PRIMARY KEY,
    medicine_id INTEGER       NOT NULL REFERENCES medicines(medicine_id),
    quantity    INTEGER       NOT NULL CHECK (quantity > 0),
    unit_price  NUMERIC(10,2) NOT NULL CHECK (unit_price > 0),
    sold_on     DATE          NOT NULL DEFAULT CURRENT_DATE
);

CREATE TABLE stock_audit (
    audit_id    SERIAL PRIMARY KEY,
    medicine_id INTEGER   NOT NULL REFERENCES medicines(medicine_id),
    old_qty     INTEGER   NOT NULL,
    new_qty     INTEGER   NOT NULL,
    changed_at  TIMESTAMP NOT NULL DEFAULT now()
);

CREATE TABLE daily_sales (
    sales_date   DATE PRIMARY KEY,
    total_qty    INTEGER       NOT NULL,
    total_amount NUMERIC(12,2) NOT NULL
);

-- Medicines are seeded now; the six sales are loaded through pr_record_sale below.
INSERT INTO medicines (medicine_name, unit_price, stock_qty) VALUES
    ('Paracetamol 500mg', 2.50, 100),
    ('Amoxicillin 250mg', 8.00,  50),
    ('ORS Sachets',       1.50,  12);

/* ===================== (b) Function ===================== */
CREATE OR REPLACE FUNCTION fn_sale_value(p_medicine_id INTEGER, p_quantity INTEGER)
RETURNS NUMERIC
LANGUAGE plpgsql AS $$
DECLARE
    v_price NUMERIC(10,2);
BEGIN
    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        RAISE EXCEPTION 'Invalid quantity: % (must be a positive number)', p_quantity;
    END IF;

    SELECT unit_price INTO v_price FROM medicines WHERE medicine_id = p_medicine_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown medicine_id: %', p_medicine_id;
    END IF;

    RETURN v_price * p_quantity;
END;
$$;

/* ===================== (c) Procedure ===================== */
CREATE OR REPLACE PROCEDURE pr_record_sale(p_medicine_id INTEGER, p_quantity INTEGER, p_sold_on DATE DEFAULT CURRENT_DATE)
LANGUAGE plpgsql AS $$
DECLARE
    v_price NUMERIC(10,2);
    v_stock INTEGER;
BEGIN
    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        RAISE EXCEPTION 'Invalid quantity: % (must be a positive number)', p_quantity;
    END IF;
    IF p_sold_on IS NULL THEN
        RAISE EXCEPTION 'sold_on must not be NULL';
    END IF;

    -- Lock the medicine row so two concurrent sales cannot oversell the same stock.
    SELECT unit_price, stock_qty INTO v_price, v_stock
    FROM medicines WHERE medicine_id = p_medicine_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown medicine_id: %', p_medicine_id;
    END IF;

    IF v_stock < p_quantity THEN
        RAISE EXCEPTION 'Insufficient stock for medicine %: requested %, available %',
                        p_medicine_id, p_quantity, v_stock;
    END IF;

    -- Current price is stored in the sale; stock is deducted exactly once.
    INSERT INTO sales (medicine_id, quantity, unit_price, sold_on)
    VALUES (p_medicine_id, p_quantity, v_price, p_sold_on);

    UPDATE medicines SET stock_qty = stock_qty - p_quantity WHERE medicine_id = p_medicine_id;
    -- Any exception above aborts the CALL, so both tables stay unchanged.
END;
$$;

/* ===================== (d) Trigger ===================== */
CREATE OR REPLACE FUNCTION trg_fn_stock_audit()
RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO stock_audit (medicine_id, old_qty, new_qty)
    VALUES (NEW.medicine_id, OLD.stock_qty, NEW.stock_qty);
    RETURN NULL;  -- AFTER trigger: return value is ignored
END;
$$;

CREATE TRIGGER trg_medicines_stock_audit
AFTER UPDATE ON medicines
FOR EACH ROW
WHEN (OLD.stock_qty IS DISTINCT FROM NEW.stock_qty)
EXECUTE FUNCTION trg_fn_stock_audit();

/* ---- (a) continued: load six valid sales through the procedure ---- */
CALL pr_record_sale(1, 10, CURRENT_DATE - 2);
CALL pr_record_sale(1,  5, CURRENT_DATE - 1);
CALL pr_record_sale(2,  4, CURRENT_DATE - 1);
CALL pr_record_sale(2,  6, CURRENT_DATE - 1);
CALL pr_record_sale(3,  5, CURRENT_DATE);
CALL pr_record_sale(1, 20, CURRENT_DATE);

SELECT * FROM medicines ORDER BY medicine_id;
SELECT * FROM sales ORDER BY sale_id;
SELECT * FROM stock_audit ORDER BY audit_id;   -- one row per stock change

-- Function tests
SELECT fn_sale_value(2, 3) AS value_of_3_amoxicillin;   -- 24.00
DO $$ BEGIN PERFORM fn_sale_value(99, 1);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END $$;
DO $$ BEGIN PERFORM fn_sale_value(1, 0);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END $$;

-- Invalid sale (oversell) must leave both tables unchanged
DO $$ BEGIN CALL pr_record_sale(3, 500, CURRENT_DATE);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END $$;
SELECT (SELECT count(*) FROM sales) AS sales_rows, (SELECT stock_qty FROM medicines WHERE medicine_id = 3) AS ors_stock;

-- Trigger test: an UPDATE that does not change stock_qty creates no audit row
UPDATE medicines SET unit_price = unit_price WHERE medicine_id = 1;
SELECT count(*) AS audit_rows_unchanged_by_price_update FROM stock_audit;

/* ===================== (e) View ===================== */
CREATE OR REPLACE VIEW v_low_stock AS
SELECT medicine_id, medicine_name, unit_price, stock_qty AS remaining_stock
FROM medicines
WHERE stock_qty < 10;

CALL pr_record_sale(3, 2, CURRENT_DATE);   -- ORS now 12-5-2 = 5
SELECT * FROM v_low_stock;

/* ===================== (f) Index ===================== */
-- Justification: the query filters on equality of medicine_id and a RANGE on sold_on.
-- A composite B-tree (medicine_id, sold_on) lets PostgreSQL jump straight to one medicine
-- and scan only the matching date range, in order, instead of reading the whole sales table.
CREATE INDEX idx_sales_medicine_sold_on ON sales (medicine_id, sold_on);
ANALYZE sales;

SET enable_seqscan = off;   -- the demo table is tiny; this forces the planner to show the index
EXPLAIN
SELECT * FROM sales
WHERE medicine_id = 1 AND sold_on BETWEEN CURRENT_DATE - 7 AND CURRENT_DATE;
RESET enable_seqscan;

/* ===================== (g) Scheduled job ===================== */
CREATE OR REPLACE PROCEDURE pr_refresh_sales(p_day DATE)
LANGUAGE plpgsql AS $$
BEGIN
    IF p_day IS NULL THEN
        RAISE EXCEPTION 'p_day must not be NULL';
    END IF;

    -- Recomputed from the sales table and REPLACED (not added), so reruns never double-count.
    INSERT INTO daily_sales (sales_date, total_qty, total_amount)
    SELECT p_day, COALESCE(SUM(quantity), 0), COALESCE(SUM(quantity * unit_price), 0)
    FROM sales WHERE sold_on = p_day
    ON CONFLICT (sales_date) DO UPDATE
        SET total_qty = EXCLUDED.total_qty, total_amount = EXCLUDED.total_amount;
END;
$$;

CREATE EXTENSION IF NOT EXISTS pg_cron;
-- Every day at 00:15 (server/pg_cron time zone), summarise the previous day.
SELECT cron.schedule('q1_refresh_sales_daily', '15 0 * * *',
                     $$CALL q1_pharmacy.pr_refresh_sales(CURRENT_DATE - 1)$$);

-- Rerun test: both runs give the same single row
CALL pr_refresh_sales(CURRENT_DATE - 1);
CALL pr_refresh_sales(CURRENT_DATE - 1);
SELECT * FROM daily_sales;   -- expected: qty 15, amount 5*2.50 + 10*8.00 = 92.50
SELECT jobid, jobname, schedule, command FROM cron.job WHERE jobname = 'q1_refresh_sales_daily';
