-- ============================================================================
-- Proyecto Integrador · Bases de Datos II · VetCare DB
-- Equipo: Grupo 5
-- Archivo 03 de 04: procedimientos, funcion, disparadores y pruebas
-- Motor: PostgreSQL 14 o superior (probado en PostgreSQL 18)
-- ----------------------------------------------------------------------------
-- Contenido (alcance ajustado del profesor):
--   Procedimiento 1  sp_agendar_cita       regla: mascota inactiva sin cita nueva
--   Procedimiento 2  sp_cancelar_cita      regla: cancelar deja rastro, no borra
--   Funcion 1        fn_total_factura      suma las lineas activas de una factura
--   Disparador 1     trg_auditoria_*       regla: precios y cancelaciones auditados
--   Disparador 2     trg_detalle_factura   BONO: stock nunca negativo + total
--
-- Las pruebas van al final, dentro de BEGIN ... ROLLBACK: se ve la salida,
-- pero no se ensucian los datos del negocio y se pueden repetir siempre.
-- ============================================================================


-- ============================================================================
-- PROCEDIMIENTO 1 · sp_agendar_cita
-- Que hace: agenda una cita despues de validar las reglas del negocio.
--   * La mascota debe existir y estar activa  -> regla 1 del caso.
--   * El veterinario debe existir y estar activo.
--   * La fecha debe ser futura.
--   * El servicio debe ser Revision o Desparasitacion.
--   * El veterinario no puede tener otra cita vigente a la misma hora.
-- Recibe: id de mascota, id de veterinario, fecha/hora, servicio.
-- Devuelve (INOUT): el id de la cita creada.
-- Corre con privilegios del dueno (SECURITY DEFINER) porque rol_operativo
-- no tiene INSERT directo sobre cita: la agenda solo se toca con este
-- procedimiento y con sp_cancelar_cita.
-- ============================================================================
CREATE OR REPLACE PROCEDURE sp_agendar_cita(
    p_id_mascota     INT,
    p_id_veterinario INT,
    p_fecha_hora     TIMESTAMP,
    p_servicio       VARCHAR(50),
    INOUT p_id_cita  INT DEFAULT NULL
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_mascota_activa CHAR(1);
    v_vet_activo     CHAR(1);
    v_ocupado        INT;
BEGIN
    -- 1. Validar la mascota (regla: una mascota inactiva no tiene cita nueva).
    IF p_id_mascota IS NULL THEN
        RAISE EXCEPTION 'Debe indicar la mascota.'
            USING ERRCODE = '23502';
    END IF;

    SELECT activa INTO v_mascota_activa
      FROM mascota
     WHERE id_mascota = p_id_mascota;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'La mascota con id % no existe.', p_id_mascota
            USING ERRCODE = '23503';
    END IF;

    IF v_mascota_activa = 'N' THEN
        RAISE EXCEPTION 'La mascota % esta inactiva: no se le pueden agendar citas nuevas.',
            p_id_mascota
            USING ERRCODE = '23514';
    END IF;

    -- 2. Validar el veterinario.
    IF p_id_veterinario IS NULL THEN
        RAISE EXCEPTION 'Debe indicar el veterinario.'
            USING ERRCODE = '23502';
    END IF;

    SELECT activa INTO v_vet_activo
      FROM veterinario
     WHERE id_veterinario = p_id_veterinario;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'El veterinario con id % no existe.', p_id_veterinario
            USING ERRCODE = '23503';
    END IF;

    IF v_vet_activo = 'N' THEN
        RAISE EXCEPTION 'El veterinario % esta inactivo y no puede recibir citas.',
            p_id_veterinario
            USING ERRCODE = '23514';
    END IF;

    -- 3. La cita debe ser futura.
    IF p_fecha_hora IS NULL THEN
        RAISE EXCEPTION 'Debe indicar la fecha y hora de la cita.'
            USING ERRCODE = '23502';
    END IF;

    IF p_fecha_hora <= CURRENT_TIMESTAMP THEN
        RAISE EXCEPTION 'La cita debe programarse en el futuro (fecha recibida: %).',
            p_fecha_hora
            USING ERRCODE = '22007';
    END IF;

    -- 4. Validar el servicio (la tabla tambien tiene su CHECK).
    IF p_servicio IS NULL OR btrim(p_servicio) = ''
       OR p_servicio NOT IN ('Revision', 'Desparasitacion') THEN
        RAISE EXCEPTION 'Servicio no valido: "%". Use Revision o Desparasitacion.',
            COALESCE(p_servicio, '(nulo)')
            USING ERRCODE = '23514';
    END IF;

    -- 5. Evitar el choque de agenda del veterinario.
    SELECT 1 INTO v_ocupado
      FROM cita
     WHERE id_veterinario = p_id_veterinario
       AND fecha_hora = p_fecha_hora
       AND estado IN ('P', 'A')
       AND activa = 'S';

    IF FOUND THEN
        RAISE EXCEPTION 'El veterinario % ya tiene una cita vigente el %.',
            p_id_veterinario, p_fecha_hora
            USING ERRCODE = '23505';
    END IF;

    -- 6. Insertar la cita. El indice unico parcial ux_cita_agenda_vigente
    --    es la ultima defensa si dos recepcionistas agendan al mismo tiempo.
    BEGIN
        INSERT INTO cita (id_mascota, id_veterinario, fecha_hora, servicio, estado)
        VALUES (p_id_mascota, p_id_veterinario, p_fecha_hora, p_servicio, 'P')
        RETURNING id_cita INTO p_id_cita;
    EXCEPTION WHEN unique_violation THEN
        RAISE EXCEPTION 'El veterinario % acaba de recibir otra cita el %. Intente otra franja.',
            p_id_veterinario, p_fecha_hora
            USING ERRCODE = '23505';
    END;

    RAISE NOTICE 'Cita % agendada: mascota %, veterinario %, %.',
        p_id_cita, p_id_mascota, p_id_veterinario, p_fecha_hora;
END;
$$;

COMMENT ON PROCEDURE sp_agendar_cita(INT, INT, TIMESTAMP, VARCHAR, INT)
    IS 'Agenda una cita validando mascota activa, veterinario activo, fecha futura y agenda libre.';


-- ============================================================================
-- PROCEDIMIENTO 2 · sp_cancelar_cita
-- Que hace: cancela una cita pendiente y futura SIN borrarla (solo estado 'C').
--   * No se puede cancelar una cita inexistente, inactiva, ya cancelada,
--     ya atendida o cuya fecha ya paso.
--   * Deja el motivo en la auditoria (lo lee el disparador con set_config).
-- Recibe: id de la cita y motivo.
-- ============================================================================
CREATE OR REPLACE PROCEDURE sp_cancelar_cita(
    p_id_cita INT,
    p_motivo  VARCHAR(200) DEFAULT 'Sin motivo'
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_estado CHAR(1);
    v_activa CHAR(1);
    v_fecha  TIMESTAMP;
BEGIN
    IF p_id_cita IS NULL THEN
        RAISE EXCEPTION 'Debe indicar la cita a cancelar.'
            USING ERRCODE = '23502';
    END IF;

    -- Bloquear la fila mientras se decide: evita dos cancelaciones simultaneas.
    SELECT estado, activa, fecha_hora
      INTO v_estado, v_activa, v_fecha
      FROM cita
     WHERE id_cita = p_id_cita
       FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'La cita con id % no existe.', p_id_cita
            USING ERRCODE = '23503';
    END IF;

    IF v_activa = 'N' THEN
        RAISE EXCEPTION 'La cita % esta inactiva.', p_id_cita
            USING ERRCODE = '23514';
    END IF;

    IF v_estado = 'C' THEN
        RAISE EXCEPTION 'La cita % ya esta cancelada.', p_id_cita
            USING ERRCODE = '23514';
    END IF;

    IF v_estado = 'A' THEN
        RAISE EXCEPTION 'La cita % ya fue atendida y no se puede cancelar.', p_id_cita
            USING ERRCODE = '23514';
    END IF;

    IF v_fecha <= CURRENT_TIMESTAMP THEN
        RAISE EXCEPTION 'La cita % ya paso (%). Solo se cancelan citas futuras.',
            p_id_cita, v_fecha
            USING ERRCODE = '23514';
    END IF;

    IF p_motivo IS NULL OR btrim(p_motivo) = '' THEN
        p_motivo := 'Sin motivo';
    END IF;

    -- El motivo viaja al disparador de auditoria por una variable de sesion
    -- local a la transaccion. Asi se registra "quien, cuando y por que".
    PERFORM set_config('vetcare.motivo', p_motivo, true);

    UPDATE cita
       SET estado = 'C'
     WHERE id_cita = p_id_cita;

    PERFORM set_config('vetcare.motivo', '', true);

    RAISE NOTICE 'Cita % cancelada. Motivo: %.', p_id_cita, p_motivo;
END;
$$;

COMMENT ON PROCEDURE sp_cancelar_cita(INT, VARCHAR)
    IS 'Cancela una cita pendiente y futura cambiando estado a C; nunca borra la fila.';


-- ============================================================================
-- FUNCION 1 · fn_total_factura
-- Que hace: suma cantidad * precio_unitario de las lineas ACTIVAS de la factura.
-- Recibe: id de factura. Devuelve: DECIMAL(12,2).
-- Es STABLE porque solo lee y no cambia entre llamadas dentro de la misma
-- consulta. La usa el disparador de stock para mantener factura.total.
-- ============================================================================
CREATE OR REPLACE FUNCTION fn_total_factura(p_id_factura INT)
RETURNS DECIMAL(12,2)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_total DECIMAL(12,2);
BEGIN
    IF p_id_factura IS NULL THEN
        RAISE EXCEPTION 'Debe indicar la factura.'
            USING ERRCODE = '23502';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM factura WHERE id_factura = p_id_factura) THEN
        RAISE EXCEPTION 'La factura con id % no existe.', p_id_factura
            USING ERRCODE = '23503';
    END IF;

    SELECT COALESCE(SUM(cantidad * precio_unitario), 0)::DECIMAL(12,2)
      INTO v_total
      FROM detalle_factura
     WHERE id_factura = p_id_factura
       AND activa = 'S';

    RETURN v_total;
END;
$$;

COMMENT ON FUNCTION fn_total_factura(INT)
    IS 'Devuelve la suma de cantidad * precio_unitario de las lineas activas de la factura.';


-- ============================================================================
-- DISPARADOR 1 (obligatorio) · AUDITORIA
-- Que hace: registra en auditoria todo cambio sensible sobre insumo (precios)
-- y sobre cita (agendamientos, atenciones y cancelaciones).
-- Guarda: tabla, operacion, id del registro, usuario de sesion, fecha,
-- motivo (si lo hay) y los datos antes/despues en JSONB.
-- Es SECURITY DEFINER para que rol_operativo pueda cancelar sin tener
-- permiso de escritura sobre auditoria.
-- Nota: los cambios SOLO de stock no se auditan aqui; se reconstruyen con
-- detalle_factura. La regla pide auditar precios y cancelaciones.
-- ============================================================================
CREATE OR REPLACE FUNCTION fn_auditoria()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_id_registro INT;
    v_motivo      TEXT;
    v_descripcion TEXT;
    v_antes       JSONB;
    v_despues     JSONB;
    v_mascota     VARCHAR(30);
    v_dueno       VARCHAR(50);
    v_veterinario VARCHAR(50);
BEGIN
    -- El motivo lo deja sp_cancelar_cita en una variable local de transaccion.
    v_motivo := NULLIF(current_setting('vetcare.motivo', true), '');

    -- En insumo, un cambio que no toca el precio no es sensible para la regla.
    -- El IF anidado es necesario: en una cita, NEW no tiene el campo precio.
    IF TG_TABLE_NAME = 'insumo' AND TG_OP = 'UPDATE' THEN
        IF NEW.precio IS NOT DISTINCT FROM OLD.precio THEN
            RETURN NULL;
        END IF;
    END IF;

    -- Identificador del registro afectado (id_insumo, id_cita, ...).
    IF TG_OP = 'DELETE' THEN
        v_id_registro := (to_jsonb(OLD) ->> ('id_' || TG_TABLE_NAME))::INT;
        v_antes       := to_jsonb(OLD);
        v_despues     := NULL;
    ELSE
        v_id_registro := (to_jsonb(NEW) ->> ('id_' || TG_TABLE_NAME))::INT;
        v_antes       := CASE WHEN TG_OP = 'UPDATE' THEN to_jsonb(OLD) ELSE NULL END;
        v_despues     := to_jsonb(NEW);
    END IF;

    -- Descripcion legible segun la tabla y la operacion.
    IF TG_TABLE_NAME = 'insumo' THEN
        IF TG_OP = 'INSERT' THEN
            v_descripcion := format('Insumo "%s" creado con precio %s y stock %s.',
                                    NEW.nombre, NEW.precio, NEW.stock);
        ELSIF TG_OP = 'UPDATE' THEN
            v_descripcion := format('Cambio de precio del insumo "%s" (id %s): %s -> %s.',
                                    NEW.nombre, NEW.id_insumo, OLD.precio, NEW.precio);
        ELSE
            v_descripcion := format('Insumo "%s" (id %s) eliminado.',
                                    OLD.nombre, OLD.id_insumo);
        END IF;

    ELSIF TG_TABLE_NAME = 'cita' THEN
        -- Nombres para que la auditoria se lea sin hacer JOIN despues.
        -- En DELETE hay que mirar OLD: NEW no esta asignado en esa operacion.
        IF TG_OP = 'DELETE' THEN
            SELECT m.nombre, d.nombre, v.nombre
              INTO v_mascota, v_dueno, v_veterinario
              FROM mascota m
              JOIN dueno d ON d.id_dueno = m.id_dueno
              JOIN veterinario v ON v.id_veterinario = OLD.id_veterinario
             WHERE m.id_mascota = OLD.id_mascota;
        ELSE
            SELECT m.nombre, d.nombre, v.nombre
              INTO v_mascota, v_dueno, v_veterinario
              FROM mascota m
              JOIN dueno d ON d.id_dueno = m.id_dueno
              JOIN veterinario v ON v.id_veterinario = NEW.id_veterinario
             WHERE m.id_mascota = NEW.id_mascota;
        END IF;

        IF TG_OP = 'INSERT' THEN
            v_descripcion := format('Cita %s agendada: %s (dueno %s) con %s el %s, servicio %s.',
                                    NEW.id_cita, v_mascota, v_dueno, v_veterinario,
                                    NEW.fecha_hora, NEW.servicio);
        ELSIF TG_OP = 'UPDATE' AND NEW.estado = 'C' AND OLD.estado <> 'C' THEN
            v_descripcion := format('Cancelacion de la cita %s de %s (dueno %s) del %s. Motivo: %s.',
                                    NEW.id_cita, v_mascota, v_dueno, NEW.fecha_hora,
                                    COALESCE(v_motivo, 'No registrado'));
        ELSIF TG_OP = 'UPDATE' AND NEW.estado = 'A' AND OLD.estado = 'P' THEN
            v_descripcion := format('Cita %s de %s marcada como atendida.', NEW.id_cita, v_mascota);
        ELSIF TG_OP = 'UPDATE' THEN
            v_descripcion := format('Actualizacion de la cita %s de %s: estado %s -> %s, fecha %s -> %s.',
                                    NEW.id_cita, v_mascota, OLD.estado, NEW.estado,
                                    OLD.fecha_hora, NEW.fecha_hora);
        ELSE
            v_descripcion := format('Cita %s de %s eliminada.', OLD.id_cita, v_mascota);
        END IF;
    END IF;

    INSERT INTO auditoria (tabla, operacion, id_registro, usuario, motivo,
                           descripcion, datos_anteriores, datos_nuevos)
    VALUES (TG_TABLE_NAME, TG_OP, v_id_registro, session_user,
            CASE WHEN TG_TABLE_NAME = 'cita' THEN v_motivo ELSE NULL END,
            v_descripcion, v_antes, v_despues);

    RETURN NULL;  -- en un disparador AFTER el valor de retorno se ignora
END;
$$;

COMMENT ON FUNCTION fn_auditoria()
    IS 'Disparador de auditoria: guarda quien, cuando y que cambio en precios y citas.';

DROP TRIGGER IF EXISTS trg_auditoria_insumo ON insumo;
CREATE TRIGGER trg_auditoria_insumo
    AFTER INSERT OR UPDATE OR DELETE ON insumo
    FOR EACH ROW EXECUTE FUNCTION fn_auditoria();

DROP TRIGGER IF EXISTS trg_auditoria_cita ON cita;
CREATE TRIGGER trg_auditoria_cita
    AFTER INSERT OR UPDATE OR DELETE ON cita
    FOR EACH ROW EXECUTE FUNCTION fn_auditoria();


-- ============================================================================
-- DISPARADOR 2 (bono) · STOCK Y TOTAL DE FACTURA
-- Que hace, por cada linea de detalle_factura:
--   * Descuenta del stock del insumo las unidades vendidas.
--   * Si la linea se modifica o se inactiva, devuelve el stock anterior.
--   * Si se borra (no deberia), devuelve el stock.
--   * Si no alcanza el stock, lanza una excepcion y toda la operacion
--     se revierte: la factura no queda a medias.
--   * Recalcula factura.total con fn_total_factura.
-- Es SECURITY DEFINER porque rol_operativo factura pero no puede
-- actualizar insumo ni factura.total directamente.
-- ============================================================================
CREATE OR REPLACE FUNCTION fn_detalle_factura_stock()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_stock  INT;
    v_activa CHAR(1);
    v_nombre VARCHAR(50);
BEGIN
    -- 1. Devolver al inventario lo que consumia la linea anterior (si estaba activa).
    IF TG_OP IN ('UPDATE', 'DELETE') AND OLD.activa = 'S' THEN
        UPDATE insumo
           SET stock = stock + OLD.cantidad
         WHERE id_insumo = OLD.id_insumo;
    END IF;

    -- 2. Descontar lo que consume la linea nueva (si queda activa).
    IF TG_OP IN ('INSERT', 'UPDATE') AND NEW.activa = 'S' THEN
        SELECT stock, activa, nombre
          INTO v_stock, v_activa, v_nombre
          FROM insumo
         WHERE id_insumo = NEW.id_insumo
           FOR UPDATE;   -- bloquea la fila mientras se descuenta

        IF NOT FOUND THEN
            RAISE EXCEPTION 'El insumo con id % no existe.', NEW.id_insumo
                USING ERRCODE = '23503';
        END IF;

        IF v_activa = 'N' THEN
            RAISE EXCEPTION 'El insumo "%" esta inactivo y no se puede facturar.', v_nombre
                USING ERRCODE = '23514';
        END IF;

        IF v_stock < NEW.cantidad THEN
            RAISE EXCEPTION 'Stock insuficiente de "%": disponible %, solicitado %.',
                v_nombre, v_stock, NEW.cantidad
                USING ERRCODE = '23514';
        END IF;

        UPDATE insumo
           SET stock = stock - NEW.cantidad
         WHERE id_insumo = NEW.id_insumo;
    END IF;

    -- 3. Mantener el total de la factura igual a la suma de sus lineas.
    IF TG_OP = 'DELETE' THEN
        UPDATE factura
           SET total = fn_total_factura(OLD.id_factura)
         WHERE id_factura = OLD.id_factura;
    ELSE
        IF TG_OP = 'UPDATE' AND OLD.id_factura <> NEW.id_factura THEN
            UPDATE factura
               SET total = fn_total_factura(OLD.id_factura)
             WHERE id_factura = OLD.id_factura;
        END IF;

        UPDATE factura
           SET total = fn_total_factura(NEW.id_factura)
         WHERE id_factura = NEW.id_factura;
    END IF;

    RETURN NULL;  -- disparador AFTER
END;
$$;

COMMENT ON FUNCTION fn_detalle_factura_stock()
    IS 'Bono: controla el stock (nunca negativo) y mantiene factura.total sincronizado.';

DROP TRIGGER IF EXISTS trg_detalle_factura_stock ON detalle_factura;
CREATE TRIGGER trg_detalle_factura_stock
    AFTER INSERT OR UPDATE OR DELETE ON detalle_factura
    FOR EACH ROW EXECUTE FUNCTION fn_detalle_factura_stock();


-- ============================================================================
-- GRANT de los objetos recien creados (el 02 corre antes de que existan).
-- ============================================================================
GRANT EXECUTE ON ALL FUNCTIONS  IN SCHEMA public TO rol_admin, rol_operativo;
GRANT EXECUTE ON ALL PROCEDURES IN SCHEMA public TO rol_admin, rol_operativo;


-- ============================================================================
-- PRUEBAS · cada objeto con su caso de prueba.
-- Todo ocurre dentro de BEGIN ... ROLLBACK: se ve el resultado, pero al final
-- la base queda como estaba y las pruebas se pueden repetir.
-- Fecha de prueba: siempre relativa a hoy, para que nunca caiga en el pasado.
-- ============================================================================
BEGIN;

-- ----------------------------------------------------------------------------
-- PRUEBA 1 · sp_agendar_cita: caso exitoso.
-- Se agenda a Toby (mascota 4) con Ivan Ortiz (veterinario 3) dentro de 7 dias.
-- Resultado esperado: cita creada en estado 'P' y se devuelve su id.
-- ----------------------------------------------------------------------------
DO $$
DECLARE
    v_fecha TIMESTAMP := (CURRENT_DATE + 7) + TIME '11:00';
    v_id    INT;
    v_hallada INT;
BEGIN
    CALL sp_agendar_cita(4, 3, v_fecha, 'Revision', v_id);

    IF v_id IS NULL THEN
        RAISE EXCEPTION 'FALLO: el procedimiento no devolvio el id de la cita';
    END IF;

    SELECT id_cita INTO v_hallada
      FROM cita
     WHERE id_mascota = 4 AND fecha_hora = v_fecha AND estado = 'P';

    IF v_hallada IS DISTINCT FROM v_id THEN
        RAISE EXCEPTION 'FALLO: la cita % no quedo registrada', v_id;
    END IF;

    RAISE NOTICE 'PRUEBA 1 OK: cita % agendada para Toby con Ivan Ortiz el %', v_id, v_fecha;
END
$$;

-- ----------------------------------------------------------------------------
-- PRUEBA 2 · sp_agendar_cita: mascota inactiva (regla 1 del negocio).
-- Rocky (mascota 3) esta inactiva. Resultado esperado: error y ninguna cita.
-- ----------------------------------------------------------------------------
DO $$
DECLARE
    v_id        INT;
    v_rechazada BOOLEAN := FALSE;
    v_mensaje   TEXT;
BEGIN
    BEGIN
        CALL sp_agendar_cita(3, 1, (CURRENT_DATE + 7) + TIME '12:00', 'Revision', v_id);
    EXCEPTION WHEN OTHERS THEN
        v_rechazada := TRUE;
        v_mensaje   := SQLERRM;
    END;

    IF NOT v_rechazada THEN
        RAISE EXCEPTION 'FALLO: se permitio agendar una cita a una mascota inactiva';
    END IF;

    RAISE NOTICE 'PRUEBA 2 OK: mascota inactiva rechazada -> %', v_mensaje;
END
$$;

-- ----------------------------------------------------------------------------
-- PRUEBA 3 · sp_agendar_cita: choque de agenda.
-- Se repite la cita de la prueba 1 (mismo veterinario y misma hora).
-- Resultado esperado: error de agenda ocupada.
-- ----------------------------------------------------------------------------
DO $$
DECLARE
    v_id        INT;
    v_rechazada BOOLEAN := FALSE;
    v_mensaje   TEXT;
BEGIN
    BEGIN
        CALL sp_agendar_cita(4, 3, (CURRENT_DATE + 7) + TIME '11:00', 'Desparasitacion', v_id);
    EXCEPTION WHEN OTHERS THEN
        v_rechazada := TRUE;
        v_mensaje   := SQLERRM;
    END;

    IF NOT v_rechazada THEN
        RAISE EXCEPTION 'FALLO: se agendaron dos citas al mismo veterinario y hora';
    END IF;

    RAISE NOTICE 'PRUEBA 3 OK: choque de agenda rechazado -> %', v_mensaje;
END
$$;

-- ----------------------------------------------------------------------------
-- PRUEBA 4 · sp_cancelar_cita: caso exitoso + auditoria.
-- Se agenda una cita a Luna y se cancela con motivo.
-- Resultado esperado: estado 'C' (la fila sigue existiendo) y una fila de
-- auditoria con el motivo.
-- ----------------------------------------------------------------------------
DO $$
DECLARE
    v_id        INT;
    v_estado    CHAR(1);
    v_auditadas INT;
BEGIN
    CALL sp_agendar_cita(1, 4, (CURRENT_DATE + 8) + TIME '15:00', 'Desparasitacion', v_id);
    CALL sp_cancelar_cita(v_id, 'La duena reprograma el viaje');

    SELECT estado INTO v_estado FROM cita WHERE id_cita = v_id;

    IF v_estado <> 'C' THEN
        RAISE EXCEPTION 'FALLO: la cita quedo en estado % en vez de C', v_estado;
    END IF;

    SELECT count(*) INTO v_auditadas
      FROM auditoria
     WHERE tabla = 'cita'
       AND id_registro = v_id
       AND operacion = 'UPDATE'
       AND motivo = 'La duena reprograma el viaje';

    IF v_auditadas = 0 THEN
        RAISE EXCEPTION 'FALLO: la cancelacion no quedo auditada con su motivo';
    END IF;

    RAISE NOTICE 'PRUEBA 4 OK: cita % cancelada (no borrada) y auditada', v_id;
END
$$;

-- ----------------------------------------------------------------------------
-- PRUEBA 5 · sp_cancelar_cita: no se puede cancelar dos veces.
-- Resultado esperado: error "ya esta cancelada".
-- ----------------------------------------------------------------------------
DO $$
DECLARE
    v_id        INT;
    v_rechazada BOOLEAN := FALSE;
    v_mensaje   TEXT;
BEGIN
    SELECT MAX(id_cita) INTO v_id FROM cita WHERE estado = 'C';

    BEGIN
        CALL sp_cancelar_cita(v_id, 'Segundo intento');
    EXCEPTION WHEN OTHERS THEN
        v_rechazada := TRUE;
        v_mensaje   := SQLERRM;
    END;

    IF NOT v_rechazada THEN
        RAISE EXCEPTION 'FALLO: se cancelo dos veces la misma cita';
    END IF;

    RAISE NOTICE 'PRUEBA 5 OK: segunda cancelacion rechazada -> %', v_mensaje;
END
$$;

-- ----------------------------------------------------------------------------
-- PRUEBA 6 · disparador de auditoria: cambio de precio.
-- Resultado esperado: una fila en auditoria con el precio anterior y el nuevo.
-- ----------------------------------------------------------------------------
DO $$
DECLARE
    v_antes   DECIMAL(12,2);
    v_nuevo   DECIMAL(12,2);
    v_coincide BOOLEAN;
BEGIN
    SELECT precio INTO v_antes FROM insumo WHERE id_insumo = 1;
    v_nuevo := v_antes + 2000.00;

    UPDATE insumo SET precio = v_nuevo WHERE id_insumo = 1;

    SELECT EXISTS (
        SELECT 1
          FROM auditoria
         WHERE tabla = 'insumo'
           AND id_registro = 1
           AND operacion = 'UPDATE'
           AND (datos_anteriores ->> 'precio')::DECIMAL(12,2) = v_antes
           AND (datos_nuevos     ->> 'precio')::DECIMAL(12,2) = v_nuevo
    ) INTO v_coincide;

    IF NOT v_coincide THEN
        RAISE EXCEPTION 'FALLO: la auditoria no guardo el precio antes/despues';
    END IF;

    RAISE NOTICE 'PRUEBA 6 OK: precio auditado (% -> %)', v_antes, v_nuevo;
END
$$;

-- ----------------------------------------------------------------------------
-- PRUEBA 7 · fn_total_factura.
-- La factura 1 tiene 2x45000 + 1x28000 + 2x1500 = 121000.
-- Resultado esperado: 121000.00.
-- ----------------------------------------------------------------------------
DO $$
DECLARE
    v_calculado DECIMAL(12,2);
    v_sumado    DECIMAL(12,2);
BEGIN
    v_calculado := fn_total_factura(1);

    SELECT COALESCE(SUM(cantidad * precio_unitario), 0)
      INTO v_sumado
      FROM detalle_factura
     WHERE id_factura = 1 AND activa = 'S';

    IF v_calculado <> v_sumado OR v_calculado <> 121000.00 THEN
        RAISE EXCEPTION 'FALLO: total calculado %, esperado %', v_calculado, v_sumado;
    END IF;

    RAISE NOTICE 'PRUEBA 7 OK: fn_total_factura(1) = %', v_calculado;
END
$$;

-- ----------------------------------------------------------------------------
-- PRUEBA 8 (bono) · disparador de stock y total.
-- Se vende 2 unidades del insumo 3 (Alimento premium): el stock baja y el
-- total de la factura se recalcula. Luego se intenta vender 9999 unidades
-- del insumo 5: debe fallar y dejar el stock intacto (nada a medias).
-- ----------------------------------------------------------------------------
DO $$
DECLARE
    v_stock_ini   INT;
    v_stock_fin   INT;
    v_id_factura  INT;
    v_total       DECIMAL(12,2);
    v_rechazada   BOOLEAN := FALSE;
    v_mensaje     TEXT;
BEGIN
    SELECT stock INTO v_stock_ini FROM insumo WHERE id_insumo = 3;

    INSERT INTO factura (id_consulta, total)
    VALUES (2, 0)
    RETURNING id_factura INTO v_id_factura;

    INSERT INTO detalle_factura (id_factura, id_insumo, cantidad, precio_unitario)
    VALUES (v_id_factura, 3, 2, 65000.00);

    SELECT stock INTO v_stock_fin FROM insumo WHERE id_insumo = 3;

    IF v_stock_fin <> v_stock_ini - 2 THEN
        RAISE EXCEPTION 'FALLO: el stock no bajo (antes %, despues %)', v_stock_ini, v_stock_fin;
    END IF;

    SELECT total INTO v_total FROM factura WHERE id_factura = v_id_factura;

    IF v_total <> 130000.00 THEN
        RAISE EXCEPTION 'FALLO: el total de la factura quedo en %', v_total;
    END IF;

    -- Venta excesiva de otro insumo: el disparador debe impedir el stock negativo.
    BEGIN
        INSERT INTO detalle_factura (id_factura, id_insumo, cantidad, precio_unitario)
        VALUES (v_id_factura, 5, 9999, 32000.00);
    EXCEPTION WHEN OTHERS THEN
        v_rechazada := TRUE;
        v_mensaje   := SQLERRM;
    END;

    IF NOT v_rechazada THEN
        RAISE EXCEPTION 'FALLO: se permitio vender mas unidades de las disponibles';
    END IF;

    IF (SELECT stock FROM insumo WHERE id_insumo = 5) <> 7 THEN
        RAISE EXCEPTION 'FALLO: la venta rechazada altero el stock del insumo 5';
    END IF;

    RAISE NOTICE 'PRUEBA 8 OK: stock de insumo 3 % -> %, factura % total %, venta excesiva rechazada -> %',
        v_stock_ini, v_stock_fin, v_id_factura, v_total, v_mensaje;
END
$$;

-- ----------------------------------------------------------------------------
-- Evidencia de las pruebas (se muestra en pantalla y luego se revierte).
-- ----------------------------------------------------------------------------
SELECT id_cita, id_mascota, id_veterinario, fecha_hora, servicio, estado
  FROM cita
 ORDER BY id_cita DESC
 LIMIT 5;

SELECT id_auditoria, tabla, operacion, id_registro, usuario, motivo, descripcion
  FROM auditoria
 ORDER BY id_auditoria;

SELECT id_factura, id_consulta, total
  FROM factura
 ORDER BY id_factura;

SELECT id_insumo, nombre, stock
  FROM insumo
 ORDER BY id_insumo;

ROLLBACK;

-- Fin del archivo 03.
