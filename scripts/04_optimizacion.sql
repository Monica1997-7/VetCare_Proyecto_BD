-- ============================================================================
-- Proyecto Integrador · Bases de Datos II · VetCare DB
-- Equipo: Grupo 5
-- Archivo 04 de 04: optimizacion de consultas
-- Motor: PostgreSQL 14 o superior (probado en PostgreSQL 18)
-- ----------------------------------------------------------------------------
-- Alcance ajustado del profesor: 1 consulta con EXPLAIN antes y despues,
-- mejorada reescribiendola (y con un indice). La segunda consulta es bono.
--
-- Como no se entrega el archivo de datos del tema autonomo, este script
-- genera un dataset sintetico TEMPORAL con el volumen de la Clase 7:
--   2.000 duenos, 5.008 mascotas, 16 veterinarios y 30.010 citas.
-- Todo se crea dentro de BEGIN ... ROLLBACK: las mediciones quedan en la
-- salida, pero la base del negocio no se ensucia y el script se puede repetir.
-- Al final se crea el indice recomendado para la base real.
--
-- Ejecutar con:  psql -U postgres -d vetcare_db -f 04_optimizacion.sql
-- ============================================================================

-- El indice se elimina al inicio para que el "ANTES" siempre se mida sin el.
DROP INDEX IF EXISTS ix_cita_fecha_hora;

BEGIN;

-- ----------------------------------------------------------------------------
-- 1. Dataset sintetico temporal (volumen de la Clase 7).
-- ----------------------------------------------------------------------------
-- El disparador de auditoria se desactiva solo durante la carga masiva.
-- El ALTER se revierte con el ROLLBACK, asi que la tabla vuelve a quedar igual.
ALTER TABLE cita DISABLE TRIGGER trg_auditoria_cita;

-- 2.000 duenos: ids 1001 a 3000.
INSERT INTO dueno (id_dueno, nombre, telefono, correo, activa)
SELECT 1000 + g,
       'Dueno ' || g,
       '+57 300 000 ' || lpad(g::TEXT, 4, '0'),
       'dueno' || g || '@correo.com',
       'S'
FROM generate_series(1, 2000) AS g;

-- 5.008 mascotas repartidas entre esos duenos: ids 1001 a 6008.
INSERT INTO mascota (id_mascota, id_dueno, nombre, especie, activa)
SELECT 1000 + g,
       1001 + (g % 2000),
       'Mascota ' || g,
       CASE WHEN g % 2 = 0 THEN 'Perro' ELSE 'Gato' END,
       'S'
FROM generate_series(1, 5008) AS g;

-- 16 veterinarios para el periodo de alta demanda: ids 101 a 116.
INSERT INTO veterinario (id_veterinario, nombre, especialidad, activa)
SELECT 100 + g,
       'Veterinario ' || g,
       CASE g % 3 WHEN 0 THEN 'General'
                  WHEN 1 THEN 'Dermatologia'
                  ELSE 'Cirugia' END,
       'S'
FROM generate_series(1, 16) AS g;

-- 30.010 citas entre el 05/01/2026 y finales de julio de 2026.
-- Una cita cada 10 minutos; el veterinario rota para que no haya dos citas
-- vigentes a la misma hora (respeta ux_cita_agenda_vigente).
INSERT INTO cita (id_cita, id_mascota, id_veterinario, fecha_hora, servicio, estado, activa)
SELECT 1000 + g,
       1 + (g % 8),
       101 + (g % 16),
       TIMESTAMP '2026-01-05 08:00:00' + (g * INTERVAL '10 minutes'),
       CASE WHEN g % 2 = 0 THEN 'Revision' ELSE 'Desparasitacion' END,
       'A',
       'S'
FROM generate_series(1, 30010) AS g;

ALTER TABLE cita ENABLE TRIGGER trg_auditoria_cita;

-- Estadisticas frescas: sin esto el planificador adivina y la comparacion
-- de planes no seria justa.
ANALYZE dueno;
ANALYZE mascota;
ANALYZE veterinario;
ANALYZE cita;

-- ============================================================================
-- CONSULTA 1 · Cuantas citas hubo en julio de 2026.
-- Problema: EXTRACT(YEAR ...) y EXTRACT(MONTH ...) envuelven la columna
-- fecha_hora. Ningun indice normal sobre fecha_hora puede usarse porque la
-- funcion se evalua fila por fila: PostgreSQL solo puede hacer Seq Scan.
-- ============================================================================

-- ------------------------------ ANTES ---------------------------------------
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*) AS citas_julio
  FROM cita
 WHERE EXTRACT(YEAR  FROM fecha_hora) = 2026
   AND EXTRACT(MONTH FROM fecha_hora) = 7;

-- ============================================================================
-- CAMBIO: 1) indice sobre la columna real, 2) reescribir el filtro como un
-- rango de fechas (sargable), sin funciones sobre la columna.
-- ============================================================================
CREATE INDEX ix_cita_fecha_hora ON cita (fecha_hora);
ANALYZE cita;

-- ------------------------------ DESPUES -------------------------------------
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*) AS citas_julio
  FROM cita
 WHERE fecha_hora >= TIMESTAMP '2026-07-01 00:00:00'
   AND fecha_hora <  TIMESTAMP '2026-08-01 00:00:00';

-- ============================================================================
-- CONSULTA 2 (bono) · Cuantas mascotas tiene cada dueno.
-- Problema: subconsulta correlacionada; se ejecuta una vez por cada dueno.
-- Cambio: reescribirla como LEFT JOIN + GROUP BY (una sola pasada).
-- ============================================================================

-- ------------------------------ ANTES ---------------------------------------
EXPLAIN (ANALYZE, BUFFERS)
SELECT d.id_dueno,
       d.nombre,
       (SELECT count(*) FROM mascota m WHERE m.id_dueno = d.id_dueno) AS num_mascotas
  FROM dueno d
 WHERE d.id_dueno BETWEEN 1001 AND 3000
 ORDER BY d.id_dueno;

-- ------------------------------ DESPUES -------------------------------------
EXPLAIN (ANALYZE, BUFFERS)
SELECT d.id_dueno,
       d.nombre,
       count(m.id_mascota) AS num_mascotas
  FROM dueno d
  LEFT JOIN mascota m ON m.id_dueno = d.id_dueno
 WHERE d.id_dueno BETWEEN 1001 AND 3000
 GROUP BY d.id_dueno, d.nombre
 ORDER BY d.id_dueno;

-- Se revierte todo el dataset sintetico y el indice creado para la prueba.
ROLLBACK;

-- ============================================================================
-- 3. Indice definitivo para la base real.
--    Con 10 citas el planificador prefiere Seq Scan (es correcto: la tabla
--    cabe en una pagina). Con el volumen de la clinica, usa el indice.
-- ============================================================================
CREATE INDEX IF NOT EXISTS ix_cita_fecha_hora ON cita (fecha_hora);
ANALYZE cita;

-- ============================================================================
-- Resultado medido en PostgreSQL 18 (dataset de 30.010 citas):
--
--   CONSULTA 1 ANTES   : Seq Scan sobre 30.010 citas, filtro por fila.
--                        Execution Time 21,468 ms.
--   CONSULTA 1 DESPUES : Index Only Scan usando ix_cita_fecha_hora.
--                        Execution Time 4,639 ms (unas 4,6 veces menos).
--                        Se leen solo las filas de julio; el rango es
--                        sargable y el indice se usa.
--
--   CONSULTA 2 ANTES   : 2.000 ejecuciones de la subconsulta (una por dueno).
--                        Execution Time 42,303 ms.
--   CONSULTA 2 DESPUES : un solo Hash Left Join + Aggregate.
--                        Execution Time 9,018 ms (unas 4,7 veces menos).
--
-- Por que mejora:
--   * Una funcion sobre la columna (EXTRACT, DATE_TRUNC, TO_CHAR) impide usar
--     el indice: se evalua en cada fila. Un rango >= / < si lo permite.
--   * Una subconsulta correlacionada se paga una vez por fila externa; el
--     JOIN + GROUP BY recorre cada tabla una sola vez.
-- ============================================================================
