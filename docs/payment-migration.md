# Payment Service — Safe Database Migration

Usá migración manual si `payments`, `refunds` o `webhook_events` ya tienen datos. **No confíes en `AutoMigrate` para agregar `NOT NULL` o índices únicos sobre filas existentes.**

## Problema

GORM `AutoMigrate` puede crear columnas o constraints que fallan cuando la tabla ya existe con datos viejos:

- una columna nueva con `NOT NULL` rompe si las filas actuales quedan en `NULL`
- un índice `UNIQUE` falla si todavía no hiciste backfill consistente
- una app arrancando con migración parcial puede quedar entre schemas

## Patrón seguro

Hacé siempre este orden:

1. **Agregar columna nullable**
2. **Backfill** de filas existentes
3. **Verificar** que no queden `NULL` o duplicados
4. **Agregar `NOT NULL`**
5. **Agregar índice/constraint `UNIQUE`**

## Ejemplo — `payments.idempotency_key`

```sql
-- 1) Add nullable column
ALTER TABLE payments ADD COLUMN idempotency_key VARCHAR(255);

-- 2) Backfill existing rows
UPDATE payments
SET idempotency_key = CONCAT('payment-', id)
WHERE idempotency_key IS NULL;

-- 3) Verify
SELECT COUNT(*)
FROM payments
WHERE idempotency_key IS NULL;

-- 4) Add NOT NULL
ALTER TABLE payments
ALTER COLUMN idempotency_key SET NOT NULL;

-- 5) Add unique index
CREATE UNIQUE INDEX CONCURRENTLY idx_payments_idempotency_key
ON payments (idempotency_key);
```

## Ejemplo — `payments.payment_id`

```sql
-- 1) Add nullable column
ALTER TABLE payments ADD COLUMN payment_id VARCHAR(255);

-- 2) Backfill existing rows
UPDATE payments
SET payment_id = CONCAT('payment-', id)
WHERE payment_id IS NULL;

-- 3) Verify
SELECT COUNT(*)
FROM payments
WHERE payment_id IS NULL;

-- 4) Add NOT NULL
ALTER TABLE payments
ALTER COLUMN payment_id SET NOT NULL;

-- 5) Add unique index
CREATE UNIQUE INDEX CONCURRENTLY idx_payments_payment_id
ON payments (payment_id);
```

## Ejemplo — nuevas columnas auditables en `webhook_events`

Columnas como `processed_at`, `error_message`, `attempt_count`, `last_error` o similares se pueden agregar nullable/default sin riesgo alto:

```sql
ALTER TABLE webhook_events ADD COLUMN processed_at TIMESTAMPTZ NULL;
ALTER TABLE webhook_events ADD COLUMN error_message TEXT NULL;
ALTER TABLE webhook_events ADD COLUMN attempt_count INTEGER NOT NULL DEFAULT 0;
```

## Nuevos status

Agregar un status nuevo como `preference_failed` **no requiere migración** si la columna `status` ya es texto/string. Solo verificá que:

- el código soporte la transición
- los dashboards/reportes no asuman un set cerrado viejo

## Checklist antes de producción

- [ ] Backup de base o snapshot previo
- [ ] Probar la migración en staging/copia de producción
- [ ] Ejecutar backfill antes de `NOT NULL`
- [ ] Verificar que no queden `NULL`
- [ ] Verificar que no haya duplicados antes del `UNIQUE`
- [ ] Crear índices con `CONCURRENTLY` en producción
- [ ] Desplegar app compatible con schema viejo y nuevo si el rollout no es atómico

## Qué evitar

- No agregar `NOT NULL` directo sobre tablas con datos
- No asumir que `AutoMigrate` resuelve backfills
- No crear índices únicos antes de limpiar duplicados
- No mezclar cambio de schema + deploy irreversible sin plan de rollback
