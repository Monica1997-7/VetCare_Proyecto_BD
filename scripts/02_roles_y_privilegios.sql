-- ============================================================================
-- Proyecto Integrador · Bases de Datos II · VetCare DB
-- Equipo: Grupo 5
-- Archivo 02 de 04: roles y privilegios
-- Motor: PostgreSQL 14 o superior (probado en PostgreSQL 18)
-- ----------------------------------------------------------------------------
-- Alcance ajustado del profesor: SOLO dos roles.
--   rol_admin      -> dueno de la clinica / administrador de la aplicacion.
--   rol_operativo  -> recepcion y veterinarios (trabajo del dia a dia).
--
-- Decisiones de seguridad:
--   * Ningun rol puede borrar: no se concede DELETE ni TRUNCATE. La regla
--     "nada se borra" tambien se cumple por privilegios, no solo por codigo.
--   * Los precios y el stock de insumo solo los cambia rol_admin.
--   * La agenda (cita) NO se modifica directamente: se usan los procedimientos
--     sp_agendar_cita y sp_cancelar_cita (archivo 03), que validan las reglas
--     del negocio. Por eso rol_operativo solo tiene SELECT sobre cita.
--   * auditoria es de solo-anexar: nadie puede UPDATE ni DELETE sus filas.
--   * Los INSERT en auditoria los hacen los disparadores, no los usuarios.
--
-- Las contrasenas son de ejemplo academico: cambiarlas en un ambiente real.
-- ============================================================================

-- ============================================================================
-- 1. Creacion de los dos roles (idempotente: se puede volver a ejecutar).
-- ============================================================================
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'rol_admin') THEN
        CREATE ROLE rol_admin LOGIN PASSWORD 'VetAdmin#2026'
            NOSUPERUSER NOCREATEDB NOCREATEROLE;
    ELSE
        ALTER ROLE rol_admin WITH LOGIN PASSWORD 'VetAdmin#2026'
            NOSUPERUSER NOCREATEDB NOCREATEROLE;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'rol_operativo') THEN
        CREATE ROLE rol_operativo LOGIN PASSWORD 'VetOper#2026'
            NOSUPERUSER NOCREATEDB NOCREATEROLE;
    ELSE
        ALTER ROLE rol_operativo WITH LOGIN PASSWORD 'VetOper#2026'
            NOSUPERUSER NOCREATEDB NOCREATEROLE;
    END IF;
END
$$;

-- ============================================================================
-- 2. Limpiar privilegios previos (permite reejecutar el script sin duplicar).
--    PUBLIC no debe poder ver ni crear objetos en el esquema.
-- ============================================================================
REVOKE ALL PRIVILEGES ON ALL TABLES    IN SCHEMA public FROM rol_admin, rol_operativo;
REVOKE ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public FROM rol_admin, rol_operativo;
REVOKE ALL PRIVILEGES ON ALL FUNCTIONS IN SCHEMA public FROM rol_admin, rol_operativo;
REVOKE ALL PRIVILEGES ON ALL PROCEDURES IN SCHEMA public FROM rol_admin, rol_operativo;
REVOKE ALL ON SCHEMA public FROM rol_admin, rol_operativo;
REVOKE ALL ON SCHEMA public FROM PUBLIC;

GRANT USAGE ON SCHEMA public TO rol_admin, rol_operativo;

-- Solo los dos roles del proyecto pueden conectarse a esta base.
DO $$
BEGIN
    EXECUTE format('REVOKE CONNECT ON DATABASE %I FROM PUBLIC', current_database());
    EXECUTE format('GRANT  CONNECT ON DATABASE %I TO rol_admin, rol_operativo', current_database());
END
$$;

-- ============================================================================
-- 3. Privilegios de rol_admin (administrador de la aplicacion).
--    Puede leer, insertar y actualizar todo; NO puede borrar.
-- ============================================================================
GRANT SELECT, INSERT, UPDATE ON ALL TABLES IN SCHEMA public TO rol_admin;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO rol_admin;
GRANT EXECUTE ON ALL FUNCTIONS  IN SCHEMA public TO rol_admin;
GRANT EXECUTE ON ALL PROCEDURES IN SCHEMA public TO rol_admin;

-- Refuerzo explicito de "nada se borra" y de la auditoria de solo-anexar.
REVOKE DELETE, TRUNCATE ON ALL TABLES IN SCHEMA public FROM rol_admin;
REVOKE UPDATE, DELETE, TRUNCATE ON auditoria FROM rol_admin;

-- ============================================================================
-- 4. Privilegios de rol_operativo (recepcion / veterinarios).
--    Lectura general y escritura solo donde el negocio lo permite.
-- ============================================================================
-- Consulta de todo el modelo (incluye agenda, historial y facturas).
GRANT SELECT ON dueno, mascota, veterinario, cita, consulta,
                 insumo, factura, detalle_factura TO rol_operativo;

-- Registro y correccion de clientes y pacientes.
GRANT INSERT, UPDATE ON dueno, mascota TO rol_operativo;

-- Registro de la atencion y de la facturacion.
GRANT INSERT ON consulta, factura, detalle_factura TO rol_operativo;

-- La agenda se cambia SOLO con los procedimientos del archivo 03.
-- (No se concede INSERT ni UPDATE directo sobre cita.)
GRANT SELECT ON cita TO rol_operativo;

-- Los insumos se consultan, pero precio y stock son competencia del admin.
-- (No se concede INSERT ni UPDATE sobre insumo.)

-- Secuencias necesarias para los INSERT con columnas SERIAL.
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO rol_operativo;

-- Procedimientos y funciones del archivo 03.
GRANT EXECUTE ON ALL FUNCTIONS  IN SCHEMA public TO rol_operativo;
GRANT EXECUTE ON ALL PROCEDURES IN SCHEMA public TO rol_operativo;

-- Sin acceso a la auditoria: solo el administrador puede leerla.
-- Sin DELETE ni TRUNCATE en ninguna tabla.
REVOKE DELETE, TRUNCATE ON ALL TABLES IN SCHEMA public FROM rol_operativo;
REVOKE ALL ON auditoria FROM rol_operativo;

-- ============================================================================
-- 5. Resumen de la matriz de privilegios
-- ----------------------------------------------------------------------------
--   Objeto / accion                rol_admin        rol_operativo
--   ---------------------------    --------------   ------------------------
--   dueno, mascota                 SELECT/I/U       SELECT/I/U
--   cita                           SELECT/I/U       SELECT  (via procs)
--   consulta, factura, detalle     SELECT/I/U       SELECT/I
--   insumo                         SELECT/I/U       SELECT
--   auditoria                      SELECT/I         sin acceso
--   DELETE / TRUNCATE              prohibido        prohibido
--   secuencias                     USAGE/SELECT     USAGE/SELECT
--   procedimientos y funciones     EXECUTE          EXECUTE
-- ============================================================================

-- ============================================================================
-- 6. Prueba de la seguridad (se revierte al final con ROLLBACK).
--    Comprueba el catalogo de privilegios y ademas intenta un cambio real
--    actuando como rol_operativo.
-- ============================================================================
BEGIN;

DO $$
DECLARE
    v_bloqueado BOOLEAN := FALSE;
    v_mensaje   TEXT;
BEGIN
    -- 6.1 Lo que rol_operativo SI puede hacer.
    IF NOT has_table_privilege('rol_operativo', 'mascota', 'SELECT') THEN
        RAISE EXCEPTION 'FALLO: rol_operativo deberia poder leer mascota';
    END IF;
    IF NOT has_table_privilege('rol_operativo', 'mascota', 'INSERT') THEN
        RAISE EXCEPTION 'FALLO: rol_operativo deberia poder registrar mascotas';
    END IF;
    IF NOT has_table_privilege('rol_operativo', 'factura', 'INSERT') THEN
        RAISE EXCEPTION 'FALLO: rol_operativo deberia poder facturar';
    END IF;

    -- 6.2 Lo que rol_operativo NO puede hacer.
    IF has_table_privilege('rol_operativo', 'insumo', 'UPDATE') THEN
        RAISE EXCEPTION 'FALLO: rol_operativo no deberia cambiar precios';
    END IF;
    IF has_table_privilege('rol_operativo', 'cita', 'INSERT') THEN
        RAISE EXCEPTION 'FALLO: la agenda solo debe cambiarse con los procedimientos';
    END IF;
    IF has_table_privilege('rol_operativo', 'auditoria', 'SELECT') THEN
        RAISE EXCEPTION 'FALLO: rol_operativo no deberia leer la auditoria';
    END IF;
    IF has_table_privilege('rol_operativo', 'cita', 'DELETE') THEN
        RAISE EXCEPTION 'FALLO: nadie deberia poder borrar citas';
    END IF;

    -- 6.3 Prueba real: actuar como rol_operativo e intentar cambiar un precio.
    --     Solo se ejecuta si el usuario actual puede adoptar el rol.
    IF pg_has_role(current_user, 'rol_operativo', 'MEMBER') THEN
        BEGIN
            SET ROLE rol_operativo;
            UPDATE insumo SET precio = 99999.00 WHERE id_insumo = 1;
            RESET ROLE;
        EXCEPTION WHEN insufficient_privilege THEN
            RESET ROLE;
            v_bloqueado := TRUE;
            v_mensaje   := SQLERRM;
        END;

        IF NOT v_bloqueado THEN
            RAISE EXCEPTION 'FALLO: rol_operativo logro cambiar el precio de un insumo';
        END IF;
        RAISE NOTICE 'PRUEBA OK: rol_operativo no puede cambiar precios -> %', v_mensaje;
    ELSE
        RAISE NOTICE 'PRUEBA OK (catalogo): faltan privilegios; prueba real omitida porque % no es miembro de rol_operativo', current_user;
    END IF;

    -- 6.4 rol_admin si puede cambiar precios, pero tampoco puede borrar.
    IF NOT has_table_privilege('rol_admin', 'insumo', 'UPDATE') THEN
        RAISE EXCEPTION 'FALLO: rol_admin deberia poder actualizar precios';
    END IF;
    IF has_table_privilege('rol_admin', 'cita', 'DELETE') THEN
        RAISE EXCEPTION 'FALLO: rol_admin no deberia poder borrar citas';
    END IF;
    IF has_table_privilege('rol_admin', 'auditoria', 'UPDATE') THEN
        RAISE EXCEPTION 'FALLO: la auditoria es de solo-anexar';
    END IF;

    RAISE NOTICE 'PRUEBA OK: matriz de privilegios verificada (admin sin DELETE, auditoria de solo-anexar)';
END
$$;

ROLLBACK;

-- ============================================================================
-- 7. Verificacion manual (opcional, desde la terminal).
-- ----------------------------------------------------------------------------
--   psql -U rol_operativo -d vetcare_db
--     SELECT * FROM cita LIMIT 5;                       -- funciona
--     UPDATE insumo SET precio = 1 WHERE id_insumo = 1; -- ERROR: permiso denegado
--     DELETE FROM cita WHERE id_cita = 1;               -- ERROR: permiso denegado
--
--   psql -U rol_admin -d vetcare_db
--     UPDATE insumo SET precio = 47000 WHERE id_insumo = 1; -- funciona
--     SELECT * FROM auditoria ORDER BY id_auditoria DESC;   -- funciona
-- ============================================================================