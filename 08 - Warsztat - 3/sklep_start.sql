-- =====================================================================
--  sklep_start.sql  –  dane startowe do warsztatu
--  "Drugi tydzień administratora PostgreSQL"
--
--  Uruchomienie (przed warsztatem, na świeżym klastrze):
--
--    sudo -u postgres psql -f /tmp/sklep_start.sql
--
--  Skrypt jest powtarzalny: usuwa bazę "sklep" i tworzy ją od nowa.
-- =====================================================================
\set ON_ERROR_STOP on
SET client_min_messages = warning;

DROP DATABASE IF EXISTS sklep;
CREATE DATABASE sklep;
\connect sklep
SET client_min_messages = warning;

CREATE SCHEMA sprzedaz;

-- Stałe ziarno generatora: każdy kursant dostaje identyczne dane
DO $$ BEGIN PERFORM setseed(0.42); END $$;

-- ---------------------------------------------------------------------
-- 1. Klienci (10 000 wierszy)
-- ---------------------------------------------------------------------
CREATE TABLE sprzedaz.klienci (
    klient_id         integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    imie              text NOT NULL,
    nazwisko          text NOT NULL,
    email             text NOT NULL UNIQUE,
    miasto            text NOT NULL,
    data_rejestracji  date NOT NULL
);

INSERT INTO sprzedaz.klienci (imie, nazwisko, email, miasto, data_rejestracji)
SELECT (ARRAY['Anna','Piotr','Katarzyna','Tomasz','Magdalena',
              'Marcin','Agnieszka','Krzysztof','Ewa','Jakub'])[1 + i % 10],
       (ARRAY['Nowak','Mazur','Kowalczyk','Krawczyk','Kaczmarek','Wieczorek',
              'Zając','Król','Wróbel','Stępień','Dudek','Pawlak'])[1 + i % 12],
       'klient' || i || '@example.com',
       (ARRAY['Warszawa','Kraków','Wrocław','Poznań','Gdańsk',
              'Łódź','Katowice','Lublin'])[1 + floor(random() * 8)::int],
       DATE '2023-01-01' + floor(random() * 1000)::int
FROM generate_series(1, 10000) AS i;

-- ---------------------------------------------------------------------
-- 2. Zamówienia (200 000 wierszy)
--    Kolumna "zaktualizowano" jest co noc nadpisywana przez zadanie
--    synchronizacji ze starym systemem magazynowym.
-- ---------------------------------------------------------------------
CREATE TABLE sprzedaz.zamowienia (
    zamowienie_id    integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    klient_id        integer NOT NULL REFERENCES sprzedaz.klienci,
    data_zamowienia  timestamptz NOT NULL,
    status           text NOT NULL
                     CHECK (status IN ('nowe','oplacone','wyslane','anulowane')),
    kwota            numeric(10,2) NOT NULL,
    uwagi            text,
    zaktualizowano   timestamptz NOT NULL DEFAULT now()
);

INSERT INTO sprzedaz.zamowienia (klient_id, data_zamowienia, status, kwota, uwagi)
SELECT 1 + floor(random() * 10000)::int,
       TIMESTAMPTZ '2026-01-01 00:00:00+01' + random() * INTERVAL '300 days',
       (ARRAY['nowe','oplacone','oplacone','wyslane','wyslane',
              'wyslane','wyslane','anulowane'])[1 + floor(random() * 8)::int],
       round((20 + random() * 1480)::numeric, 2),
       md5(i::text) || md5((i * 7)::text)
FROM generate_series(1, 200000) AS i;

CREATE INDEX zamowienia_klient_idx ON sprzedaz.zamowienia (klient_id);
CREATE INDEX zamowienia_data_idx   ON sprzedaz.zamowienia (data_zamowienia);

-- Ustawienie odziedziczone po poprzednim administratorze
ALTER TABLE sprzedaz.zamowienia SET (autovacuum_enabled = off);

ANALYZE sprzedaz.klienci, sprzedaz.zamowienia;

-- ---------------------------------------------------------------------
-- 3. Podsumowanie – oczekiwane: 10000 / 200000
-- ---------------------------------------------------------------------
SELECT 'klienci' AS tabela, count(*) AS wierszy FROM sprzedaz.klienci
UNION ALL SELECT 'zamowienia', count(*) FROM sprzedaz.zamowienia;
