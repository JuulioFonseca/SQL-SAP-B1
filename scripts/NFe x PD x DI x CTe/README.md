# NFe x PD x DI x CT-e — Script de Conciliação (SAP Business One / HANA)

Script SQL (HANA) desenvolvido para **cruzar e conciliar** os documentos fiscais e logísticos de uma operação de importação dentro do SAP Business One:

- **NFe** (Notas Fiscais de Entrada — tabela `OPCH`, Compras)
- **PD** (Recebimento de Mercadoria — tabela `OPDN`)
- **DI** (Declaração de Importação / Despesas de Importação — tabela `OIPF`)
- **CT-e** (Conhecimento de Transporte Eletrônico — também mapeado via `OPCH`, como um documento de frete)

O objetivo é responder, para cada item de cada NFe/PD de matéria-prima (`MP%`): *"Essa nota está com a DI corretamente vinculada? Existe um CT-e de frete associado? Existe alguma NF divergente que ficou 'perdida' no meio do processo (estornada/ajustada via lançamento contábil manual)?"*

Este documento explica o script **bloco a bloco**, para servir de referência para manutenção futura.

---

## Sumário

1. [Visão geral da arquitetura do script](#1-visão-geral-da-arquitetura-do-script)
2. [Parâmetros de filtro (linhas de comentário no topo)](#2-parâmetros-de-filtro)
3. [CTE 1 — `NFs_Corretas`](#3-cte-1--nfs_corretas)
4. [CTE 2 — `NFs_Divergentes_Bruto`](#4-cte-2--nfs_divergentes_bruto)
5. [CTE 3 — `Mapeamento_Unico`](#5-cte-3--mapeamento_unico)
6. [CTE 4 — `NFs_Divergentes`](#6-cte-4--nfs_divergentes)
7. [CTE 5 — `DadosBrutos` (bloco NFe)](#7-cte-5--dadosbrutos-bloco-nfe)
8. [CTE 5 — `DadosBrutos` (bloco PD)](#8-cte-5--dadosbrutos-bloco-pd)
9. [SELECT final — agregação e apresentação](#9-select-final--agregação-e-apresentação)
10. [Glossário de tabelas SAP B1 utilizadas](#10-glossário-de-tabelas-sap-b1-utilizadas)
11. [Regras de negócio resumidas](#11-regras-de-negócio-resumidas)
12. [Possíveis pontos de atenção / manutenção](#12-possíveis-pontos-de-atenção--manutenção)

---

## 1. Visão geral da arquitetura do script

O script é organizado em **CTEs encadeadas** (`WITH ... AS (...)`), cada uma resolvendo um problema específico, até chegar ao resultado final:

```
NFs_Corretas ────────────┐
                          ├──▶ Mapeamento_Unico ──▶ NFs_Divergentes ──┐
NFs_Divergentes_Bruto ────┘                                          │
                                                                      ▼
                                                    OPCH/OPDN + IPF1 + OIPF + CT-e  ──▶ DadosBrutos
                                                                      │
                                                                      ▼
                                                              SELECT final (GROUP BY)
```

Em resumo:
- As **4 primeiras CTEs** existem só para identificar **notas fiscais "órfãs"**: NFs que deveriam ter uma DI vinculada, mas não têm porque foram corrigidas/estornadas via lançamento contábil manual (`OITR`/`JDT1`), e mapeá-las para a NF "correta" que efetivamente recebeu a DI.
- A **CTE `DadosBrutos`** faz o trabalho pesado: junta NFe (ou PD) + Item + Despesas de Importação (`IPF1`) + DI (`OIPF`) + CT-e, linha a linha.
- O **SELECT final** agrupa tudo por documento/item e concatena DIs e CT-es múltiplos em uma única célula.

---

## 2. Parâmetros de filtro

```sql
-- SELECT 1 FROM OPCH T0 WHERE T0."DocDate" >= '[%1]'
-- SELECT 1 FROM OPCH T0 WHERE T0."DocDate" <= '[%2]'
```

Essas duas linhas são **comentários especiais do SAP Business One** (Query Manager / Query Print Layout). Elas não são executadas como SQL — servem apenas para que o SAP reconheça que o script possui dois parâmetros de data (`%1` e `%2`) e exiba a tela de seleção de período (Data Início / Data Fim) antes de rodar a consulta.

Os parâmetros reais são usados mais abaixo, nas cláusulas:

```sql
T4."DocDate" BETWEEN '[%1]' AND '[%2]'   -- filtro de data no bloco NFe
T5."DocDate" BETWEEN '[%1]' AND '[%2]'   -- filtro de data no bloco PD
```

---

## 3. CTE 1 — `NFs_Corretas`

```sql
NFs_Corretas AS (
    SELECT DISTINCT
        A."DocEntry" AS "DocEntry_Correta",
        A."BaseEntry",
        A."ItemCode",
        A_Head."DocDate"
    FROM PCH1 A
    INNER JOIN OPCH A_Head ON A."DocEntry" = A_Head."DocEntry"
    INNER JOIN IPF1 DI ON A."DocEntry" = DI."BaseEntry" AND DI."BaseType" = '18'
    WHERE A."BaseType" IN (20, 22) AND A_Head."CANCELED" = 'N'
)
```

**Objetivo:** listar todas as linhas de NF de Compras (`PCH1`) que:
- Têm como origem (`BaseType`) um Recebimento de Mercadoria (`20`) ou outro tipo de base equivalente (`22`);
- **Possuem** uma Despesa de Importação vinculada (`IPF1.BaseType = '18'`, ou seja, a DI foi alocada contra essa NF);
- Pertencem a um documento não cancelado (`CANCELED = 'N'`).

Ou seja: esta CTE responde "quais NFs estão **corretas**, no sentido de já terem recebido o rateio da DI?". O campo `BaseEntry` + `ItemCode` é a chave usada mais adiante para casar com o recebimento de origem.

---

## 4. CTE 2 — `NFs_Divergentes_Bruto`

```sql
NFs_Divergentes_Bruto AS (
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
)
```

**Objetivo:** encontrar as NFs "abandonadas" — aquelas que **não** têm DI vinculada (`DI."DocEntry" IS NULL`, resultado do `LEFT JOIN`), mas que tiveram alguma movimentação/reclassificação contábil manual via **Reconciliação Interna** (`OITR`/`ITR1`), identificada através do lançamento contábil (`JDT1`) associado ao documento.

Em outras palavras: são NFs que o time fiscal/contábil "resolveu" via um ajuste manual de reconciliação em vez de vincular a DI diretamente no documento. Isso indica que provavelmente **outra NF** (a "correta") absorveu o custo da DI no lugar dela.

- `JDT1` = linhas de lançamentos contábeis (Journal Entry Rows), usado aqui só como ponte para achar quais NFs passaram por reconciliação.
- `ITR1` = linhas de Reconciliação Interna (Internal Transfer Reconciliation), que é o processo usado no SAP para "casar" partidas contábeis em aberto.

---

## 5. CTE 3 — `Mapeamento_Unico`

```sql
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
)
```

**Objetivo:** cruzar cada NF "errada" (sem DI) com a(s) NF(s) "corretas" (com DI) que compartilham o **mesmo recebimento de origem** (`BaseEntry`) e o **mesmo item** (`ItemCode`) — ou seja, candidatas a serem a nota que efetivamente absorveu a DI daquele mesmo recebimento/item.

Como pode haver **mais de uma** NF correta candidata para a mesma NF errada, o script usa `ROW_NUMBER()` para escolher **uma única** correspondência por NF errada, priorizando:
1. A menor diferença de dias entre a data da NF errada e a data da NF correta (`ABS(DAYS_BETWEEN(...))` — a mais próxima temporalmente é a mais provável de ser a substituta real);
2. Em caso de empate, a NF correta com o maior `DocEntry` (a mais recente lançada no sistema).

O resultado (`"Rn" = 1`) será filtrado na próxima CTE.

---

## 6. CTE 4 — `NFs_Divergentes`

```sql
NFs_Divergentes AS (
    SELECT 
        "DocEntry_Correta",
        STRING_AGG(TO_VARCHAR("Serial_Errado"), ', ') AS "NFs_Divergentes"
    FROM Mapeamento_Unico
    WHERE "Rn" = 1
    GROUP BY "DocEntry_Correta"
)
```

**Objetivo:** para cada NF correta (`DocEntry_Correta`), agregar (concatenar em texto, separado por vírgula) o(s) número(s) de série das NFs erradas que foram mapeadas para ela (`STRING_AGG`). Isso permite que uma única NF correta carregue a informação de **todas** as NFs divergentes que ela "substituiu".

Esse resultado será usado no bloco `DadosBrutos` (via `LEFT JOIN`) para preencher as colunas **"Divergente?"** e **"NF Divergente (OITR)"**.

---

## 7. CTE 5 — `DadosBrutos` (bloco NFe)

Esta é a CTE principal, e está dividida em duas metades unidas por `UNION ALL`: uma para **NFe (Compras)** e outra para **PD (Recebimento de Mercadoria)**. Vamos ao primeiro bloco:

```sql
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
```

Explicando cada junção:

| Alias | Tabela | Papel |
|---|---|---|
| `T4` | `OPCH` (cabeçalho) | A própria Nota Fiscal de Entrada (Compras) |
| `T_Item` | `PCH1` (linhas) | Os itens da NF — filtro `LIKE 'MP%'` restringe a matérias-primas |
| `T1` | subquery sobre `IPF1` | Soma das despesas de importação (`TtlExpndLC`) alocadas à NF, agrupada por documento de DI (`DocEntry`), NF de destino (`BaseEntry`) e tipo (`BaseType = '18'` = alocação em NF de Compras) |
| `T0` | `OIPF` (cabeçalho da DI) | O documento de Despesas de Importação em si — traz `DocNum`, `DocDate`, `DocTotal` e `JdtMemo` (memo do lançamento contábil, usado para achar o CT-e) |
| `T3` | `ONFM` | Tabela de modelos de nota fiscal — usada para traduzir o código do `Model` da NF em uma descrição textual |
| `T2` | subquery sobre `OPCH` | Busca o **CT-e** (documentos com `Model IN ('44','45')`, que são os modelos fiscais de Conhecimento de Transporte) cujo número (`NumAtCard`, "número do documento do parceiro") aparece dentro do texto do memo da DI (`JdtMemo`) |
| `ND` | `NFs_Divergentes` (CTE) | Traz a informação de quais NFs erradas foram absorvidas por esta NF correta |

### Detalhe importante: como o CT-e é localizado (`T2`)

Como o SAP B1 não tem um campo estruturado que ligue diretamente a DI ao CT-e, o script usa uma técnica de **extração de texto via regex**:

```sql
LTRIM(SUBSTRING_REGEXPR('[0-9]+' IN T0."JdtMemo" OCCURRENCE 1), '0')
```

Isso extrai a **primeira sequência numérica** encontrada no campo `JdtMemo` (o "memo" do lançamento contábil da DI, onde geralmente o número do CT-e foi digitado manualmente) e remove zeros à esquerda. Esse número é comparado com o `NumAtCard` (limpo da mesma forma) dos documentos `OPCH` do tipo CT-e.

Como pode haver mais de um CT-e com o mesmo `NumAtCard_Limpo` ao longo do tempo (numeração pode se repetir entre fornecedores/anos), o script usa:
- `ROW_NUMBER() OVER (PARTITION BY NumAtCard_Limpo ORDER BY DocDate DESC, DocEntry DESC)` para pegar sempre o **mais recente**;
- Uma janela de datas de segurança: `T2."DocDate" BETWEEN ADD_DAYS(T0."DocDate", -15) AND ADD_DAYS(T0."DocDate", 90)` — o CT-e precisa estar datado entre 15 dias antes e 90 dias depois da DI, para evitar falso-positivo de casamento por número repetido em períodos muito distantes.

### Colunas calculadas

```sql
CASE
    WHEN T4."Model" = '39' THEN 'NF-e'
    ELSE T3."NfmDescrip"
END "Modelo da NF"
```
Se o modelo da nota for `39` (padrão nacional de NF-e), força o texto `'NF-e'`; caso contrário usa a descrição cadastrada em `ONFM`.

```sql
CASE WHEN ND."NFs_Divergentes" IS NOT NULL THEN 'Sim' ELSE 'Não' END AS "Divergente?"
```
Marca a linha como divergente se esta NF "correta" tiver absorvido alguma NF "errada" (via CTEs 1–4).

### Filtros (`WHERE`)

- `T4."CANCELED" = 'N'` e `T0."Canceled" = 'N'`: ignora NF e DI cancelados;
- `T_Item."ItemCode" LIKE 'MP%'`: restringe a itens cujo código começa com `MP` (Matéria-Prima);
- `T4."DocDate" BETWEEN '[%1]' AND '[%2]'`: aplica o filtro de período informado pelo usuário.

> **Observação:** como todos os `JOIN`s até `T0` (DI) são `INNER JOIN`, este bloco só traz **NFe que já têm DI vinculada**. NFs sem DI (as "divergentes") não aparecem aqui como linha própria — elas só aparecem *referenciadas* na coluna "NF Divergente (OITR)" da NF que efetivamente recebeu a DI.

---

## 8. CTE 5 — `DadosBrutos` (bloco PD)

```sql
UNION ALL

SELECT DISTINCT
    'PD' AS "Tipo",
    ...
FROM OPDN T5
INNER JOIN PDN1 T_Item ON T5."DocEntry" = T_Item."DocEntry"
INNER JOIN (...) T1 ON T1."BaseEntry" = T5."DocEntry" AND T1."BaseType" = '20'
INNER JOIN OIPF T0 ON T1."DocEntry" = T0."DocEntry"
INNER JOIN ONFM T3 ON T5."Model" = T3."AbsEntry"
LEFT JOIN (...) T2 ON ...
WHERE T5."CANCELED" = 'N' 
  AND T0."Canceled" = 'N'
  AND T_Item."ItemCode" LIKE 'MP%'
  AND T5."DocDate" BETWEEN '[%1]' AND '[%2]'
```

Estrutura **idêntica** ao bloco anterior, mas trocando a origem:

- `T5` = `OPDN` (cabeçalho do **Recebimento de Mercadoria**, "PD" — Purchase Delivery) em vez de `OPCH`;
- `T_Item` = `PDN1` (linhas do PD) em vez de `PCH1`;
- O vínculo com `IPF1` usa `T1."BaseType" = '20'` (código de tipo de base para Recebimento de Mercadoria, em vez de `'18'`/NF);
- As colunas `"Divergente?"` e `"NF Divergente (OITR)"` são fixadas em `'Não'` / `NULL`, pois a lógica de divergência (CTEs 1–4) foi construída especificamente em cima de NFs de Compras (`PCH1`/`OPCH`), não de PDs.

Ou seja, este bloco serve para trazer, lado a lado com a NFe, o **documento de recebimento físico da mercadoria**, permitindo comparar se o recebimento também está corretamente amarrado à mesma DI/CT-e.

---

## 9. SELECT final — agregação e apresentação

```sql
SELECT 
    "Tipo", "Nº de documento", "Nº de série", "Model", "Modelo da NF",
    "Nº do item", "Descrição", "Filial", "Código do fornecedor", 
    "Nome do fornecedor", "Data", "Valor total NF",
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
```

**Por que agrupar de novo, se `DadosBrutos` já usa `DISTINCT`?**

Porque uma mesma NF/item pode estar vinculada a **múltiplas DIs** e/ou **múltiplos CT-es** (por exemplo, quando a carga foi importada em mais de um desembaraço, ou o frete foi fracionado em mais de um CT-e). O `DadosBrutos` traz **uma linha por combinação** de NF + Item + DI + CT-e; o `SELECT` final agrupa por NF + Item e:

- Concatena todos os números de DI em uma única célula (`STRING_AGG` → coluna **"DIs Vinculadas"**);
- Concatena todos os números de CT-e em uma única célula (`STRING_AGG` → coluna **"CT-es Vinculados"**);
- Traz o maior valor total de DI e de CT-e encontrados (`MAX`) como referência de conferência de valores (`"Total DI (Maior)"` e `"Total CT-e (Maior)"`).

O resultado final é **uma linha por NF/PD + item**, com todas as DIs e CT-es relacionados agregados em texto, pronta para exportação/análise em Excel ou Power BI.

---

## 10. Glossário de tabelas SAP B1 utilizadas

| Tabela | Nome / Função no SAP B1 |
|---|---|
| `OPCH` | Cabeçalho de Nota Fiscal de Entrada (Compras) / também usada para localizar CT-e (Model 44/45) |
| `PCH1` | Linhas (itens) da Nota Fiscal de Entrada |
| `OPDN` | Cabeçalho de Recebimento de Mercadoria (Purchase Delivery Notes) |
| `PDN1` | Linhas (itens) do Recebimento de Mercadoria |
| `OIPF` | Cabeçalho de Despesas de Importação (DI) |
| `IPF1` | Linhas de alocação de Despesas de Importação (rateio por documento base) |
| `ONFM` | Cadastro de Modelos de Nota Fiscal |
| `JDT1` | Linhas de Lançamento Contábil (Journal Entry Rows) |
| `ITR1` | Linhas de Reconciliação Interna (Internal Reconciliation) |

---

## 11. Regras de negócio resumidas

1. Uma NF de Compras (ou PD) só entra no relatório se tiver uma **DI vinculada** (`INNER JOIN` com `IPF1`/`OIPF`) e o item for **matéria-prima** (`ItemCode LIKE 'MP%'`).
2. O **CT-e** é associado por **inferência textual**: extrai o primeiro número presente no memo do lançamento contábil da DI e casa com o `NumAtCard` de um documento de transporte (`Model 44/45`) dentro de uma janela de datas de -15 a +90 dias.
3. Uma NF é considerada **divergente** quando existe outra NF (mesmo `BaseEntry`/recebimento + mesmo item) que **não** possui DI vinculada, mas que passou por um ajuste de **Reconciliação Interna** — indicando que o valor da DI foi, na prática, redirecionado/corrigido para a NF que aparece no relatório.
4. Cada NF/PD + item pode aparecer com **múltiplas DIs** e **múltiplos CT-es**, todos concatenados na mesma linha final.
5. O relatório sempre traz duas visões lado a lado (via `UNION ALL`): a **Nota Fiscal (NFe)** e o **Recebimento físico (PD)**, permitindo comparar as duas pontas do processo de importação.

---

## 12. Possíveis pontos de atenção / manutenção

- **Dependência do texto livre `JdtMemo`:** a associação ao CT-e depende de um número ter sido digitado manualmente no memo do lançamento contábil da DI. Se o padrão de preenchimento mudar (ex.: texto sem número, ou múltiplos números), o `SUBSTRING_REGEXPR(... OCCURRENCE 1)` pode capturar o número errado.
- **Códigos de `BaseType` fixos** (`'18'`, `'20'`, `'22'`): são específicos da configuração deste ambiente SAP B1. Caso a empresa altere a parametrização de tipos de documento base, esses valores precisam ser revisados.
- **Filtro `ItemCode LIKE 'MP%'`:** restringe o relatório a um prefixo específico de código de item. Se a nomenclatura de itens mudar, este filtro deve ser atualizado.
- **Janela de casamento do CT-e (-15/+90 dias):** é uma heurística; puede exigir ajuste caso os prazos reais entre emissão de DI e emissão de CT-e variem para além desse intervalo.
- **Performance:** por unir múltiplas subqueries agregadas (`IPF1` somado duas vezes) e usar `SUBSTRING_REGEXPR`/`ROW_NUMBER()` sobre `OPCH`, o script pode ficar pesado em bases muito grandes — vale revisar índices em `PCH1."DocEntry"`, `IPF1."BaseEntry"/"BaseType"` e `OPCH."Model"/"CANCELED"` se a performance cair.

---

## Como usar

1. Importe o script no **SAP Business One → Query Manager** (ou rode diretamente no HANA Studio/DBeaver conectado à base SAP).
2. Ao executar via SAP B1, será solicitado o preenchimento de **Data Início** (`%1`) e **Data Fim** (`%2`).
3. O resultado pode ser exportado para Excel diretamente pelo SAP B1, ou consumido via Power Query/Power BI apontando para a mesma query.
