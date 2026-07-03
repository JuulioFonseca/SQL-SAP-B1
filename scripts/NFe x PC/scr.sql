SELECT
    T0."DocNum" AS "DocNum",
    T0."Serial",
    T0."DocDate" AS "Data NF",
    T0."CardCode",
    T0."CardName",
    T0."BPLName",
    T1."WhsCode" AS "Depósito",
    T1."LineNum" AS "Linha NF",
    T1."ItemCode" AS "Item NF",
    T1."Dscription" AS "Descrição NF",
    T1."Quantity" AS "Qtde NF",
    CASE
        WHEN T1."BaseType" = 22 THEN 'NF baseada em Pedido (OPOR)'
        WHEN T1."BaseType" = 20 THEN 'NF baseada em Entrada (GRPO/OPDN)'
        ELSE 'Outro'
    END AS "Origem do Vínculo",
    T1."BaseType",
    T1."BaseEntry",
    T1."BaseLine",
    COALESCE(P0."DocNum", P0_VIA."DocNum") AS "Pedido Compra (DocNum)",
    COALESCE(P0."DocEntry", P0_VIA."DocEntry") AS "Pedido Compra (DocEntry)",
    COALESCE(P1."LineNum", P1_VIA."LineNum") AS "Linha Pedido",
    COALESCE(P1."ItemCode", P1_VIA."ItemCode") AS "Item Pedido",
    COALESCE(P1."Dscription", P1_VIA."Dscription") AS "Descrição Pedido",
    COALESCE(P1."Quantity", P1_VIA."Quantity") AS "Qtde Pedido",

    -- Situação de cancelamento (visão informativa)
    T0."CANCELED" AS "NF Cancelada",
    COALESCE(P0."CANCELED", P0_VIA."CANCELED") AS "Pedido Cancelado?",

    -- (Item NF x Item Pedido)
    CASE
        WHEN T1."ItemCode" = COALESCE(P1."ItemCode", P1_VIA."ItemCode") THEN 'OK'
        ELSE 'DIF'
    END AS "Comparação Item"

FROM OPCH T0
JOIN PCH1 T1
  ON T0."DocEntry" = T1."DocEntry"

-- =========================
-- BaseType = 22 NF foi criada diretamente a partir do Pedido de Compra

LEFT JOIN OPOR P0
  ON T1."BaseType" = 22
 AND T1."BaseEntry" = P0."DocEntry"

LEFT JOIN POR1 P1
  ON T1."BaseType" = 22
 AND T1."BaseEntry" = P1."DocEntry"
 AND T1."BaseLine"  = P1."LineNum"

-- =========================
-- BaseType = 20 NF foi criada a partir de uma Entrada de Mercadorias (GRPO)
-- PCH1 -> PDN1 -> POR1/OPOR

LEFT JOIN OPDN G0
  ON T1."BaseType" = 20
 AND T1."BaseEntry" = G0."DocEntry"

LEFT JOIN PDN1 G1
  ON T1."BaseType" = 20
 AND T1."BaseEntry" = G1."DocEntry"
 AND T1."BaseLine"  = G1."LineNum"

LEFT JOIN OPOR P0_VIA     -- Pedido via GRPO
  ON G1."BaseType" = 22
 AND G1."BaseEntry" = P0_VIA."DocEntry"

LEFT JOIN POR1 P1_VIA     -- Linha do pedido via GRPO
  ON G1."BaseType" = 22
 AND G1."BaseEntry" = P1_VIA."DocEntry"
 AND G1."BaseLine"  = P1_VIA."LineNum"

WHERE T0."DocDate" >= [%0]
  AND T0."DocDate" <= [%1]

ORDER BY
    T0."DocDate",
    T0."DocNum",
    T1."LineNum";
