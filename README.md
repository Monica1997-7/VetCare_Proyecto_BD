# VetCare DB — Clínica Veterinaria «Huellitas»

Proyecto Integrador de **Bases de Datos II (FI303215)** — UNIAJC.
Base de datos en PostgreSQL para la Clínica Veterinaria «Huellitas»: modelo, seguridad, objetos programables y optimización. **No incluye aplicación**: solo SQL.

**Equipo:** Grupo 5 (Monica Daysure Ortiz Ossa, Anderson Guapacho Gaitán)

---

## 1. Requisitos

- PostgreSQL **14 o superior** (probado en PostgreSQL 18).
- Crear una base vacía antes de ejecutar los scripts:

```bash
createdb -U postgres bd_VetCare
```

## 2. Cómo ejecutar (en orden)

Los scripts están pensados para correr completos y en orden. Se pueden ejecutar desde psql o desde pgAdmin (Query Tool).

```bash
psql -U postgres -d bd_VetCare -v ON_ERROR_STOP=1 -f scripts/01_ddl.sql
psql -U postgres -d bd_VetCare -v ON_ERROR_STOP=1 -f scripts/02_roles_y_privilegios.sql
psql -U postgres -d bd_VetCare -v ON_ERROR_STOP=1 -f scripts/03_programables.sql
psql -U postgres -d bd_VetCare -v ON_ERROR_STOP=1 -f scripts/04_optimizacion.sql
```

> `ON_ERROR_STOP=1` hace que psql se detenga ante el primer error; es útil para las capturas.
> Los archivos no usan `\c`: se conecta uno directamente a `bd_VetCare` (así también funcionan en pgAdmin).
> El **01** se ejecuta una sola vez sobre una base nueva. Para reinstalar, descomentar el `DROP TABLE` del inicio del archivo.
> Los scripts **02, 03 y 04 se pueden volver a ejecutar** sin duplicar datos ni privilegios.

### Archivos

| Archivo | Contenido |
|---|---|
| `scripts/01_ddl.sql` | 8 tablas del caso + tabla `auditoria`, llaves, CHECK, índices y datos del elenco. |
| `scripts/02_roles_y_privilegios.sql` | Los 2 roles, `GRANT`/`REVOKE` y prueba real de privilegios. |
| `scripts/03_programables.sql` | 2 procedimientos, 1 función, 2 disparadores y sus casos de prueba. |
| `scripts/04_optimizacion.sql` | `EXPLAIN ANALYZE` antes/después con dataset temporal de 30.010 citas. |

---

## 3. Modelo

Orden de creación: `dueno`, `veterinario`, `insumo`, `mascota`, `cita`, `consulta`, `factura`, `detalle_factura`, más `auditoria` (tabla de apoyo).

Reglas de formato del curso aplicadas:

- Identificadores en minúscula, singular, sin tildes ni eñes (`dueno`, `mascota`, `detalle_factura`).
- Claves sustitutas `id_<entidad>` (`id_dueno`, `id_mascota`, …).
- Dinero `DECIMAL(12,2)`, fechas `TIMESTAMP`, teléfonos `VARCHAR(30)`.
- **Nada se borra:** todas las tablas tienen
  `activa CHAR(1) NOT NULL DEFAULT 'S' CHECK (activa IN ('S','N'))`.

### Las 3 reglas del negocio y dónde se cumplen

| Regla | Dónde se hace cumplir |
|---|---|
| Una mascota inactiva no puede tener cita nueva | `sp_agendar_cita` valida `mascota.activa`; además ningún rol tiene `INSERT` directo sobre `cita`, así que no hay forma de saltarse el procedimiento. |
| El stock de un insumo nunca queda negativo | `CHECK (stock >= 0)` + disparador `trg_detalle_factura_stock`, que lanza excepción y revierte la factura completa si no alcanza. |
| Todo cambio sensible queda auditado | Disparador de auditoría sobre `insumo` (precios) y `cita` (agendamientos, atenciones y cancelaciones), con usuario, fecha, motivo y datos antes/después en JSONB. |

### Datos del elenco

El `01_ddl.sql` siembra el elenco oficial del anexo del caso: **6 dueños, 8 mascotas** (Rocky y Kiara inactivas), **4 veterinarios** (Andres Vallejo, Diego Moreno, Ivan Ortiz, Jorge Pineda), **10 citas**, consultas, 5 insumos y 2 facturas de ejemplo.

> Nota: el anexo oficial escribe **`Firulais`** (no «Firulillo») y las especialidades **`Dermatologia` / `Cirugia`** sin tilde, porque así están sembradas en la base del curso. Los datos y los `WHERE` deben usar exactamente esos valores.

---

## 4. Seguridad: dos roles

| Rol | Para quién | Qué puede hacer |
|---|---|---|
| `rol_admin` | Dueño de la clínica / administrador | Leer, insertar y actualizar todo; cambiar precios y stock; leer la auditoría. **No borra** y no inserta citas a mano (usa el procedimiento). |
| `rol_operativo` | Recepción y veterinarios | Leer todo el modelo, registrar dueños/mascotas, consultas y facturas; agendar y cancelar con los procedimientos. **No** cambia precios ni stock, **no** lee la auditoría, **no** borra. |

Credenciales de ejemplo (cambiar en un ambiente real):

```text
rol_admin      / VetAdmin#2026
rol_operativo  / VetOper#2026
```

Prueba manual:

```bash
psql -U rol_operativo -d bd_VetCare
  SELECT * FROM cita LIMIT 5;                       -- funciona
  UPDATE insumo SET precio = 1 WHERE id_insumo = 1; -- ERROR: permiso denegado
  DELETE FROM cita WHERE id_cita = 1;               -- ERROR: permiso denegado
```

Decisiones de seguridad:

- `PUBLIC` no tiene privilegios sobre el esquema; solo los dos roles se conectan a la base.
- No existe `DELETE` ni `TRUNCATE` para ningún rol: la regla «nada se borra» también se cumple por privilegios.
- `auditoria` es de **solo-anexar** (`SELECT`/`INSERT` para el admin, nada para el operativo).
- Los procedimientos y disparadores usan `SECURITY DEFINER` con `SET search_path = public, pg_temp` para que el operativo pueda agendar/cancelar/facturar sin recibir permisos peligrosos.

---

## 5. Objetos programables y pruebas

Todos los casos de prueba están en `03_programables.sql`, dentro de `BEGIN … ROLLBACK`: muestran el resultado en pantalla pero **no ensucian la base** y se pueden repetir siempre.

| Objeto | Tipo | Caso de prueba | Resultado esperado |
|---|---|---|---|
| `sp_agendar_cita` | Procedimiento | Agendar a Toby con Ivan Ortiz en una franja libre. Luego intentar con Rocky (inactiva). | Cita creada para Toby. Rocky es rechazada con error: *"La mascota 3 esta inactiva..."* |
| `sp_cancelar_cita` | Procedimiento | Cancelar una cita pendiente con motivo. Luego intentar cancelarla de nuevo. | Estado `C`, la fila no se borra y queda auditada. La segunda vez da error: *"ya esta cancelada"*. |
| `fn_total_factura` | Función | `SELECT fn_total_factura(1);` | Retorna `121000.00`. |
| `trg_auditoria` | Disparador | Cambiar el precio de un insumo. | Fila en `auditoria` con precio anterior y nuevo (JSONB). |
| `trg_detalle_factura_stock` | Disparador | Intentar vender 9999 unidades del insumo 5 (que tiene 7). | Error: *"Stock insuficiente de Shampoo medicado: disponible 7, solicitado 9999"*. |

### Firma de las rutinas

```sql
-- Agenda una cita. El INOUT devuelve el id creado.
CALL sp_agendar_cita(4, 3, (CURRENT_DATE + 7) + TIME '11:00', 'Revision', NULL);
-- -> p_id_cita = 11 (el id depende de la base)

-- Cancela una cita (no la borra) y registra el motivo.
-- Usar el id que devolvió la llamada anterior.
CALL sp_cancelar_cita(11, 'La duena reprograma el viaje');

-- Suma las líneas activas de una factura.
SELECT fn_total_factura(1);   -- 121000.00
```

### Integración app ↔ BD (resumen para el informe)

| Rutina | Recibe | Devuelve | Ejemplo de llamada |
|---|---|---|---|
| `sp_agendar_cita` | id de mascota, id de veterinario, fecha/hora, servicio | id de la cita (`INOUT`) | `CALL sp_agendar_cita(4, 3, (CURRENT_DATE + 7) + TIME '11:00', 'Revision', NULL);` |
| `sp_cancelar_cita` | id de cita, motivo | nada (aviso `NOTICE`) | `CALL sp_cancelar_cita(11, 'Viaje de la duena');` |
| `fn_total_factura` | id de factura | total `DECIMAL(12,2)` | `SELECT fn_total_factura(1);` |

---

## 6. Optimización (`04_optimizacion.sql`)

El script genera un dataset **temporal** con el volumen de la Clase 7 (2.000 dueños, 5.008 mascotas, 16 veterinarios, 30.010 citas), mide, y revierte todo con `ROLLBACK`; al final deja creado el índice recomendado.

| Consulta | Antes | Después | Mejora |
|---|---|---|---|
| Citas de julio de 2026 | `Seq Scan` por `EXTRACT(...)`, 21.468 ms | `Index Only Scan` con rango `>= / <`, 4.639 ms | ~4,6× |
| Mascotas por dueño | subconsulta correlacionada (2.000 ejecuciones), 42.303 ms | `LEFT JOIN` + `GROUP BY`, 9.018 ms | ~4,7× |

La idea: una función sobre la columna (`EXTRACT`, `DATE_TRUNC`, `TO_CHAR`) impide usar el índice; un rango sargable sí lo permite. Y una subconsulta correlacionada se paga una vez por fila externa, mientras que el JOIN recorre cada tabla una sola vez.

---

## 7. Plan de respaldo y recuperación

No se ejecuta en la entrega (así lo pide el alcance); es el plan escrito.

- **Herramienta:** `pg_dump` en formato custom (`-Fc`), que permite restaurar con `pg_restore` y comprimir.
- **Frecuencia:** respaldo completo diario a las 20:30 (después del cierre de la clínica) y uno manual antes de cada despliegue o cambio de esquema.
- **Retención:** 7 diarios, 4 semanales y 12 mensuales.
- **Dos copias:** una en el disco del servidor y otra en almacenamiento externo (Drive/S3), siguiendo la regla 3-2-1 (3 copias, 2 medios, 1 fuera del sitio).

```bash
# Respaldo completo diario
pg_dump -U postgres -Fc -d bd_VetCare -f /respaldos/vetcare_$(date +%F).dump

# Respaldo de roles y privilegios (global)
pg_dumpall -U postgres -g -f /respaldos/roles_$(date +%F).sql

# Restauración en una base nueva (probar una vez al mes)
createdb -U postgres vetcare_restore
pg_restore -U postgres -d vetcare_restore --clean --if-exists /respaldos/vetcare_2026-11-20.dump
```

- **RPO (lo que se puede perder):** máximo 24 horas de operación.
- **RTO (tiempo de recuperación):** ~30 minutos con el dump diario y el servidor disponible.
- **Verificación:** restaurar el dump en `vetcare_restore` y correr `SELECT` de conteo sobre las 8 tablas; el respaldo solo se considera válido si la restauración funciona.

---

## 8. Notas de alcance

- **Seguridad:** solo 2 roles (`rol_admin`, `rol_operativo`).
- **Lógica:** 2 procedimientos y 1 función, cada uno con su prueba.
- **Disparadores:** 2 Disparadores: 1 obligatorio de auditoría (una sola función aplicada a `insumo` y `cita`) y 1 de bono (stock y total de factura).
- **Optimización:** 1 consulta obligatoria con `EXPLAIN` antes/después; la segunda es bono.
- **Sin código de aplicación:** solo SQL y este README.
- El alcance ajustado del 7 de noviembre no pide ejecutar el respaldo, solo el plan escrito.
