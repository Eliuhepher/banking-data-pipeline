-- Clientes más rentables basado en historial transaccional
-- Optimizado: filtro sk_tiempo usa SORTKEY, JOIN sk_cliente usa DISTKEY
-- Parámetro: reemplazar :anio con el año deseado o EXTRACT(YEAR FROM SYSDATE)

WITH volumen_por_cliente_producto AS (
    SELECT
        c.sk_cliente,
        c.tipo_de_identificacion,
        c.numero_de_identificacion,
        c.nombres,
        c.ciudad,
        c.reporte_centrales_riesgo,
        c.monto_reporte_riesgo,
        p.tipo_de_producto,
        COUNT(f.sk_transaccion)       AS num_transacciones,
        SUM(f.monto_transaccion)      AS monto_total_producto,
        AVG(f.monto_transaccion)      AS monto_promedio
    FROM dw.fact_transacciones f
    JOIN dw.dim_cliente c
        ON f.sk_cliente = c.sk_cliente
        AND c.es_activo = TRUE
    JOIN dw.dim_producto p
        ON f.sk_producto = p.sk_producto
    JOIN dw.dim_tiempo t
        ON f.sk_tiempo = t.sk_tiempo
    WHERE t.anio = EXTRACT(YEAR FROM SYSDATE)
    GROUP BY 1, 2, 3, 4, 5, 6, 7, 8
),
metricas_cliente AS (
    SELECT
        sk_cliente,
        tipo_de_identificacion,
        numero_de_identificacion,
        nombres,
        ciudad,
        reporte_centrales_riesgo,
        monto_reporte_riesgo,
        COUNT(DISTINCT tipo_de_producto)         AS num_productos,
        SUM(num_transacciones)                   AS total_transacciones,
        SUM(monto_total_producto)                AS monto_total_cliente,
        AVG(monto_promedio)                      AS ticket_promedio,
        -- penaliza clientes con reporte en centrales de riesgo
        CASE
            WHEN reporte_centrales_riesgo = TRUE
            THEN SUM(monto_total_producto) * 0.7
            ELSE SUM(monto_total_producto)
        END                                      AS score_rentabilidad
    FROM volumen_por_cliente_producto
    GROUP BY 1, 2, 3, 4, 5, 6, 7
),
ranking AS (
    SELECT
        *,
        RANK() OVER (ORDER BY score_rentabilidad DESC) AS ranking_rentabilidad
    FROM metricas_cliente
)
SELECT
    ranking_rentabilidad,
    tipo_de_identificacion,
    numero_de_identificacion,
    nombres,
    ciudad,
    num_productos,
    total_transacciones,
    monto_total_cliente,
    ticket_promedio,
    score_rentabilidad,
    reporte_centrales_riesgo,
    monto_reporte_riesgo
FROM ranking
WHERE ranking_rentabilidad <= 100
ORDER BY ranking_rentabilidad;
