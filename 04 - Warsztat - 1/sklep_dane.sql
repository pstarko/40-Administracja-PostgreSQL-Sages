-- =====================================================================
--  sklep_dane.sql  –  dane testowe do warsztatu
--  "Pierwszy dzień administratora PostgreSQL"
--
--  Uruchamiany w Module 4, PO utworzeniu bazy "sklep", roli
--  "sklep_admin" oraz schematów "sprzedaz" i "raporty":
--
--    sudo -u postgres psql -p 5433 -d sklep -f /tmp/sklep_dane.sql
--
--  Skrypt jest powtarzalny: usuwa i tworzy obiekty od nowa.
-- =====================================================================
\set ON_ERROR_STOP on

-- Kontrola wstępna: czytelny komunikat zamiast lawiny błędów
DO $$
BEGIN
  IF current_database() <> 'sklep' THEN
    RAISE EXCEPTION 'Skrypt uruchom w bazie "sklep" (teraz: "%")', current_database();
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'sklep_admin') THEN
    RAISE EXCEPTION 'Brak roli "sklep_admin" - wykonaj najpierw krok 4.1';
  END IF;
  IF to_regnamespace('sprzedaz') IS NULL OR to_regnamespace('raporty') IS NULL THEN
    RAISE EXCEPTION 'Brak schematu "sprzedaz" lub "raporty" - wykonaj najpierw krok 4.2';
  END IF;
END $$;

-- Bez komunikatów NOTICE przy pierwszym uruchomieniu
SET client_min_messages = warning;

-- Obiekty mają należeć do właściciela aplikacji, a nie do superusera
SET ROLE sklep_admin;

DROP VIEW  IF EXISTS raporty.sprzedaz_dzienna, raporty.sprzedaz_wg_kategorii;
DROP TABLE IF EXISTS sprzedaz.pozycje_zamowien, sprzedaz.zamowienia,
                     sprzedaz.produkty, sprzedaz.klienci;

-- Stałe ziarno generatora: każdy kursant dostaje identyczne dane
DO $$ BEGIN PERFORM setseed(0.42); END $$;

-- ---------------------------------------------------------------------
-- 1. Klienci (1 000 wierszy) – dane osobowe
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
FROM generate_series(1, 1000) AS i;

-- ---------------------------------------------------------------------
-- 2. Produkty (50 wierszy)
-- ---------------------------------------------------------------------
CREATE TABLE sprzedaz.produkty (
    produkt_id  integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    nazwa       text NOT NULL,
    kategoria   text NOT NULL,
    cena        numeric(10,2) NOT NULL CHECK (cena > 0)
);

INSERT INTO sprzedaz.produkty (nazwa, kategoria, cena)
SELECT 'Produkt ' || lpad(i::text, 3, '0'),
       (ARRAY['Elektronika','Książki','Dom i ogród','Sport','Zabawki'])[1 + i % 5],
       round((5 + random() * 495)::numeric, 2)
FROM generate_series(1, 50) AS i;

-- ---------------------------------------------------------------------
-- 3. Zamówienia (20 000 wierszy, 300 dni od 2026-01-01)
-- ---------------------------------------------------------------------
CREATE TABLE sprzedaz.zamowienia (
    zamowienie_id    integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    klient_id        integer NOT NULL REFERENCES sprzedaz.klienci,
    data_zamowienia  timestamptz NOT NULL,
    status           text NOT NULL
                     CHECK (status IN ('nowe','oplacone','wyslane','anulowane'))
);

INSERT INTO sprzedaz.zamowienia (klient_id, data_zamowienia, status)
SELECT 1 + floor(random() * 1000)::int,
       TIMESTAMPTZ '2026-01-01 00:00:00+01' + random() * INTERVAL '300 days',
       (ARRAY['nowe','oplacone','oplacone','wyslane','wyslane',
              'wyslane','wyslane','anulowane'])[1 + floor(random() * 8)::int]
FROM generate_series(1, 20000) AS i;

CREATE INDEX zamowienia_klient_idx ON sprzedaz.zamowienia (klient_id);
CREATE INDEX zamowienia_data_idx   ON sprzedaz.zamowienia (data_zamowienia);

-- ---------------------------------------------------------------------
-- 4. Pozycje zamówień (60 000 wierszy: po 3 na zamówienie)
-- ---------------------------------------------------------------------
CREATE TABLE sprzedaz.pozycje_zamowien (
    zamowienie_id      integer  NOT NULL REFERENCES sprzedaz.zamowienia,
    lp                 smallint NOT NULL,
    produkt_id         integer  NOT NULL REFERENCES sprzedaz.produkty,
    ilosc              integer  NOT NULL CHECK (ilosc > 0),
    cena_jednostkowa   numeric(10,2) NOT NULL,
    PRIMARY KEY (zamowienie_id, lp)
);

INSERT INTO sprzedaz.pozycje_zamowien
       (zamowienie_id, lp, produkt_id, ilosc, cena_jednostkowa)
SELECT x.zamowienie_id, x.lp, p.produkt_id, x.ilosc, p.cena
FROM (
    SELECT z.zamowienie_id,
           n                               AS lp,
           1 + floor(random() * 50)::int   AS produkt_id,
           1 + floor(random() * 5)::int    AS ilosc
    FROM sprzedaz.zamowienia AS z
    CROSS JOIN generate_series(1, 3) AS n
) AS x
JOIN sprzedaz.produkty AS p USING (produkt_id);

-- ---------------------------------------------------------------------
-- 5. Widoki raportowe (bez danych osobowych)
-- ---------------------------------------------------------------------
CREATE VIEW raporty.sprzedaz_dzienna AS
SELECT (z.data_zamowienia AT TIME ZONE 'Europe/Warsaw')::date AS dzien,
       count(DISTINCT z.zamowienie_id)                        AS liczba_zamowien,
       sum(p.ilosc * p.cena_jednostkowa)                      AS obrot
FROM sprzedaz.zamowienia AS z
JOIN sprzedaz.pozycje_zamowien AS p USING (zamowienie_id)
WHERE z.status <> 'anulowane'
GROUP BY 1;

CREATE VIEW raporty.sprzedaz_wg_kategorii AS
SELECT pr.kategoria,
       sum(p.ilosc)                        AS sztuk,
       sum(p.ilosc * p.cena_jednostkowa)   AS obrot
FROM sprzedaz.pozycje_zamowien AS p
JOIN sprzedaz.produkty   AS pr USING (produkt_id)
JOIN sprzedaz.zamowienia AS z  USING (zamowienie_id)
WHERE z.status <> 'anulowane'
GROUP BY pr.kategoria;

-- Świeże statystyki dla planisty
ANALYZE sprzedaz.klienci, sprzedaz.produkty,
        sprzedaz.zamowienia, sprzedaz.pozycje_zamowien;

RESET ROLE;
RESET client_min_messages;

-- ---------------------------------------------------------------------
-- 6. Podsumowanie – oczekiwane: 1000 / 50 / 20000 / 60000
-- ---------------------------------------------------------------------
SELECT 'klienci' AS tabela, count(*) AS wierszy FROM sprzedaz.klienci
UNION ALL SELECT 'produkty',          count(*) FROM sprzedaz.produkty
UNION ALL SELECT 'zamowienia',        count(*) FROM sprzedaz.zamowienia
UNION ALL SELECT 'pozycje_zamowien',  count(*) FROM sprzedaz.pozycje_zamowien;
