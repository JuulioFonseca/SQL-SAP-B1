-- SELECT 1 FROM OPCH T0 WHERE T0."DocDate" >= '[%1]'
-- SELECT 1 FROM OPCH T0 WHERE T0."DocDate" <= '[%2]'

WITH NFs_Corretas AS (
    SELECT DISTINCT
        A."DocEntry" AS "DocEntry_Correta",
        A."BaseEntry",
        A."ItemCode",
        A_Head."DocDate"
    FROM PCH1 A
    INNER JOIN OPCH A_Head ON A."DocEntry" = A_Head."DocEntry"
    INNER JOIN IPF1 DI ON A."DocEntry" = DI."BaseEntry" AND DI."BaseType" = '18'
    WHERE A."BaseType" IN (20, 22) AND A_Head."CANCELED" = 'N'
),

NFs_Divergentes_Bruto AS (
    -- Mapeia as NFs abandonadas (Sem DI) que passaram por OITR
    SELECT DISTINCT
        B."DocEntry" AS "DocEntry_Errada",
        B_Head."Serial" AS "Serial_Errado",
        B."BaseEntry",
        B."ItemCode",
        B_Head."DocDate"
    FROM PCH1 B
    INNER JOIN OPCH B_Head ON B."DocEntry" = B_Head."DocEntry"
    INNER JOIN JDT1 J ON B_Head."TransId" = J."TransId"
    INNER JOIN ITR1 I ON J."TransId" = I."TransId" AND J."Line_ID" = I."TransRowId"
    LEFT JOIN IPF1 DI ON B."DocEntry" = DI."BaseEntry" AND DI."BaseType" = '18'
    WHERE B."BaseType" IN (20, 22) 
      AND B_Head."CANCELED" = 'N'
      AND DI."DocEntry" IS NULL
),

Mapeamento_Unico AS (
    SELECT 
        Erradas."DocEntry_Errada",
        Erradas."Serial_Errado",
        Corretas."DocEntry_Correta",
        ROW_NUMBER() OVER(
            PARTITION BY Erradas."DocEntry_Errada" 
            ORDER BY ABS(DAYS_BETWEEN(Erradas."DocDate", Corretas."DocDate")) ASC, Corretas."DocEntry_Correta" DESC
        ) as "Rn"
    FROM NFs_Divergentes_Bruto Erradas
    INNER JOIN NFs_Corretas Corretas 
        ON Erradas."BaseEntry" = Corretas."BaseEntry" 
       AND Erradas."ItemCode" = Corretas."ItemCode"
),

NFs_Divergentes AS (
    SELECT 
        "DocEntry_Correta",
        STRING_AGG(TO_VARCHAR("Serial_Errado"), ', ') AS "NFs_Divergentes"
    FROM Mapeamento_Unico
    WHERE "Rn" = 1
    GROUP BY "DocEntry_Correta"
),

DadosBrutos AS (
    SELECT DISTINCT
        'NFe' AS "Tipo",
        T4."DocNum" AS "Nº de documento",
        T4."Serial" AS "Nº de série",
        T4."Model" AS "Model",
        CASE
            WHEN T4."Model" = '39' THEN 'NF-e'
            ELSE T3."NfmDescrip"
        END "Modelo da NF",
        
        T_Item."ItemCode" AS "Nº do item",
        T_Item."Dscription" AS "Descrição",
        
        T4."BPLName" AS "Filial",
        T4."CardCode" AS "Código do fornecedor",
        T4."CardName" AS "Nome do fornecedor",
        T4."DocDate" AS "Data",
        T4."DocTotal" AS "Valor total NF",

        T0."DocNum" AS "Doc DI",
        T0."DocDate" AS "Data DI",
        T1."TtlExpndLC" AS "Val Custos Alocados", 
        T0."DocTotal" AS "Total DI",

        T2."DocNum" AS "Nº CT-e",
        T2."DocTotal" AS "Total CT-e",

        CASE WHEN ND."NFs_Divergentes" IS NOT NULL THEN 'Sim' ELSE 'Não' END AS "Divergente?",
        ND."NFs_Divergentes" AS "NF Divergente (OITR)"

    FROM OPCH T4
    INNER JOIN PCH1 T_Item ON T4."DocEntry" = T_Item."DocEntry"
    INNER JOIN (
        SELECT "DocEntry", "BaseEntry", "BaseType", SUM("TtlExpndLC") AS "TtlExpndLC" 
        FROM IPF1 
        GROUP BY "DocEntry", "BaseEntry", "BaseType"
    ) T1 ON T1."BaseEntry" = T4."DocEntry" AND T1."BaseType" = '18'
    INNER JOIN OIPF T0 ON T1."DocEntry" = T0."DocEntry"
    INNER JOIN ONFM T3 ON T4."Model" = T3."AbsEntry"
    LEFT JOIN (
        SELECT 
            "DocNum", "Serial", "CardName", "DocDate", "DocTotal", "Model", "CANCELED",
            RTRIM(LTRIM("NumAtCard", '0')) AS "NumAtCard_Limpo",
            ROW_NUMBER() OVER(PARTITION BY RTRIM(LTRIM("NumAtCard", '0')) ORDER BY "DocDate" DESC, "DocEntry" DESC) AS "Rn"
        FROM OPCH
        WHERE "Model" IN ('44', '45') AND "CANCELED" = 'N'
    ) T2 ON LTRIM(SUBSTRING_REGEXPR('[0-9]+' IN T0."JdtMemo" OCCURRENCE 1), '0') = T2."NumAtCard_Limpo"
        AND T2."Rn" = 1
        AND T2."DocDate" BETWEEN ADD_DAYS(T0."DocDate", -15) AND ADD_DAYS(T0."DocDate", 90)
        
    LEFT JOIN NFs_Divergentes ND ON T4."DocEntry" = ND."DocEntry_Correta"

    WHERE T4."CANCELED" = 'N' 
      AND T0."Canceled" = 'N'
      AND T_Item."ItemCode" LIKE 'MP%'
      AND T4."DocDate" BETWEEN '[%1]' AND '[%2]'

    UNION ALL


    -- RECEBIMENTOS DE MERCADORIA (PD)
    SELECT DISTINCT
        'PD' AS "Tipo",
        T5."DocNum" AS "Nº de documento",
        T5."Serial" AS "Nº de série",
        T5."Model" AS "Model",
        CASE
            WHEN T5."Model" = '39' THEN 'NF-e'
            ELSE T3."NfmDescrip"
        END "Modelo da NF",

        T_Item."ItemCode" AS "Nº do item",
        T_Item."Dscription" AS "Descrição",

        T5."BPLName" AS "Filial",
        T5."CardCode" AS "Código do fornecedor",
        T5."CardName" AS "Nome do fornecedor",
        T5."DocDate" AS "Data",
        T5."DocTotal" AS "Valor total NF",

        T0."DocNum" AS "Doc DI",
        T0."DocDate" AS "Data DI",
        T1."TtlExpndLC" AS "Val Custos Alocados", 
        T0."DocTotal" AS "Total DI",

        T2."DocNum" AS "Nº CT-e",
        T2."DocTotal" AS "Total CT-e",

        'Não' AS "Divergente?",
        CAST(NULL AS VARCHAR) AS "NF Divergente (OITR)"

    FROM OPDN T5
    INNER JOIN PDN1 T_Item ON T5."DocEntry" = T_Item."DocEntry"
    INNER JOIN (
        SELECT "DocEntry", "BaseEntry", "BaseType", SUM("TtlExpndLC") AS "TtlExpndLC" 
        FROM IPF1 
        GROUP BY "DocEntry", "BaseEntry", "BaseType"
    ) T1 ON T1."BaseEntry" = T5."DocEntry" AND T1."BaseType" = '20'
    INNER JOIN OIPF T0 ON T1."DocEntry" = T0."DocEntry"
    INNER JOIN ONFM T3 ON T5."Model" = T3."AbsEntry"
    LEFT JOIN (
        SELECT 
            "DocNum", "Serial", "CardName", "DocDate", "DocTotal", "Model", "CANCELED",
            RTRIM(LTRIM("NumAtCard", '0')) AS "NumAtCard_Limpo",
            ROW_NUMBER() OVER(PARTITION BY RTRIM(LTRIM("NumAtCard", '0')) ORDER BY "DocDate" DESC, "DocEntry" DESC) AS "Rn"
        FROM OPCH
        WHERE "Model" IN ('44', '45') AND "CANCELED" = 'N'
    ) T2 ON LTRIM(SUBSTRING_REGEXPR('[0-9]+' IN T0."JdtMemo" OCCURRENCE 1), '0') = T2."NumAtCard_Limpo"
        AND T2."Rn" = 1
        AND T2."DocDate" BETWEEN ADD_DAYS(T0."DocDate", -15) AND ADD_DAYS(T0."DocDate", 90)

    WHERE T5."CANCELED" = 'N' 
      AND T0."Canceled" = 'N'
      AND T_Item."ItemCode" LIKE 'MP%'
      AND T5."DocDate" BETWEEN '[%1]' AND '[%2]'
)

SELECT 
    "Tipo",
    "Nº de documento",
    "Nº de série",
    "Model",
    "Modelo da NF",
    "Nº do item",
    "Descrição",
    "Filial",
    "Código do fornecedor",
    "Nome do fornecedor",
    "Data",
    "Valor total NF",
    
    STRING_AGG(TO_VARCHAR("Doc DI"), ', ') AS "DIs Vinculadas",
    MAX("Total DI") AS "Total DI (Maior)",
    
    STRING_AGG(TO_VARCHAR("Nº CT-e"), ', ') AS "CT-es Vinculados",
    MAX("Total CT-e") AS "Total CT-e (Maior)",

    "Divergente?",
    "NF Divergente (OITR)"

FROM DadosBrutos
GROUP BY 
    "Tipo", "Nº de documento", "Nº de série", "Model", "Modelo da NF",
    "Nº do item", "Descrição", "Filial", "Código do fornecedor", 
    "Nome do fornecedor", "Data", "Valor total NF",
    "Divergente?", "NF Divergente (OITR)"
ORDER BY "Nº de documento", "Nº do item";
