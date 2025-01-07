# Documentação do Desafio DBA - Maior Plataforma de Educação do Brasil

Este documento detalha a solução desenvolvida para o desafio DBA, que envolve a estruturação de um banco de dados multi-tenant no PostgreSQL. O objetivo é garantir integridade, otimização de consultas, escalabilidade e boas práticas.

OBS: Existe várias formas de le dar com estrutura multi-tenant em banco de dados, nos ultimos anos passei por empresas como Gran (antigo Gran cursos) e DOT Digital Group do segmento educacional, e as formas mais adotadas são:
- Todos os dados em uma mesma estrutura de banco de dados e/ou
- Uma base de dados por cliente que é a que eu mais sugiro.

---

## Estrutura das Tabelas

### 1. **Tabela `tenant`**
Representa diferentes clientes que utilizam o sistema.

```sql
CREATE TABLE tenant (
    id SERIAL PRIMARY KEY,
    name VARCHAR(100) NOT NULL,
    description VARCHAR(255)
);
```
- **Chave Primária**: `id`
- Garantia de unicidade para identificação dos tenants.
- OBS: Estamos usando serial, poderia ser bigserial e até mesmo uuid, todavia esse é mais lento.

### 2. **Tabela `person`**
Contém informações sobre indivíduos.

```sql
CREATE TABLE person (
    id SERIAL PRIMARY KEY,
    name VARCHAR(100) NOT NULL,
    birth_date DATE,
    metadata JSONB
);
```
- **Chave Primária**: `id`
- O campo `metadata` utiliza o tipo JSONB para armazenar dados flexíveis.
- Interessante o uso do jsonb em questão, pois os dados são armazenados em um formato binário otimizado, todavia o formato json é mais rápido para inserir dados, pois o PostgreSQL não realiza processamento extra no momento da gravação.

### 3. **Tabela `institution`**
Armazena informações de instituições associadas aos tenants.

```sql
CREATE TABLE institution (
    id SERIAL PRIMARY KEY,
    tenant_id INTEGER NOT NULL REFERENCES tenant(id) ON DELETE CASCADE,
    name VARCHAR(100) NOT NULL,
    location VARCHAR(100),
    details JSONB
);
```
- **Referência Estrangeira**: `tenant_id` associada a `tenant(id)`.
- **Regra de Exclusão**: `ON DELETE CASCADE` para garantir consistência.

### 4. **Tabela `course`**
Contém informações sobre cursos oferecidos pelas instituições.

```sql
CREATE TABLE course (
    id SERIAL PRIMARY KEY,
    tenant_id INTEGER NOT NULL REFERENCES tenant(id) ON DELETE CASCADE,
    institution_id INTEGER REFERENCES institution(id) ON DELETE SET NULL,
    name VARCHAR(100) NOT NULL,
    duration INTEGER,
    details JSONB
);
```
- **Referência Estrangeira**: `tenant_id` e `institution_id`.
- **Regra de Exclusão**: `ON DELETE SET NULL` para evitar perda de dados.

### 5. **Tabela `enrollment`**
Registra matrículas associadas a tenants, instituições e cursos.

```sql
CREATE TABLE enrollment (
    id SERIAL PRIMARY KEY,
    tenant_id INTEGER NOT NULL REFERENCES tenant(id) ON DELETE CASCADE,
    institution_id INTEGER REFERENCES institution(id) ON DELETE SET NULL,
    person_id INTEGER NOT NULL REFERENCES person(id) ON DELETE CASCADE,
    course_id INTEGER NOT NULL REFERENCES course(id) ON DELETE CASCADE,
    enrollment_date DATE NOT NULL,
    status VARCHAR(20) NOT NULL,
    deleted_at TIMESTAMP NULL
);
```
- **Índice de Unicidade**:

```sql
CREATE UNIQUE INDEX idx_enrollment_unique
ON enrollment (tenant_id, institution_id, person_id) WHERE deleted_at IS NULL;
```
- **Exclusão Lógica**: Implementada com o campo `deleted_at`. Como podemos ver se o valor for NULL, o registro está ativo.
- OBS: Entidades financeiras e alguns outros ramos não utilizam mais exclusão lógica, ultimamente tende-se implementado bancos de dados ledge, todavia vai do contexto do produto.

---

## Índices Essenciais

### 1. **Tabela `person`**
Acelerar buscas no campo `metadata`:
```sql
CREATE INDEX idx_person_metadata_gin ON person USING gin (metadata jsonb_path_ops);
```
- OBS: Gin é uma função de INDICE ideal para buscas em tabelas grandes e suporta operadores específicos (@>, ?, dentre outros) com alta eficiência.

### 2. **Tabela `enrollment`**
Otimização de buscas condicionais:
```sql
CREATE INDEX idx_enrollment_status ON enrollment (status) WHERE deleted_at IS NULL;
CREATE INDEX idx_enrollment_date ON enrollment (enrollment_date);
```

---

## Consultas Otimizadas

### 1. **Número de Matrículas por Curso**
Retorna o total de matrículas para cada curso filtrando por tenant e instituição:

```sql
SELECT
    c.name AS course_name,
    COUNT(e.id) AS total_enrollments
FROM
    enrollment e
JOIN
    course c ON e.course_id = c.id
WHERE
    e.tenant_id = $1 AND e.institution_id = $2 AND e.deleted_at IS NULL
GROUP BY
    c.name;
```

### 2. **Listagem de Alunos por Curso**
Lista todos os alunos de um curso em um tenant e instituição específicos:

```sql
SELECT
    p.id AS person_id,
    p.name AS person_name,
    p.metadata,
    e.enrollment_date,
    e.status
FROM
    enrollment e
JOIN
    person p ON e.person_id = p.id
WHERE
    e.course_id = $1 AND e.tenant_id = $2 AND e.institution_id = $3 AND e.deleted_at IS NULL;
```

---

## Exclusão Lógica

A exclusão lógica é implementada com o campo `deleted_at`. Todas as consultas devem filtrar registros onde `deleted_at IS NULL` para garantir que apenas dados ativos sejam considerados.

---

## Particionamento da Tabela `enrollment`

Para melhorar o desempenho em consultas e gestão de dados históricos, a tabela foi particionada por intervalo de datas.

### ! **Sugestão de Indice**

Para minimizar o impacto no desempenho, criei o índice considerando apenas registros ativos. Porém, deve-se pensar no mesmo indice para as PARTIÇÕES.

```sql
CREATE INDEX idx_active_enrollment
ON enrollment (tenant_id, institution_id, person_id)
WHERE deleted_at IS NULL;
```

### ! **O que eu faria a mais**

Criaria trigger para garantir que apenas o campo deleted_at seja atualizado, prevenindo exclusões físicas acidentais.

```sql
CREATE OR REPLACE FUNCTION prevent_physical_delete()
RETURNS TRIGGER AS $$
BEGIN
    IF (TG_OP = 'DELETE') THEN
        RAISE EXCEPTION 'Use logical deletion instead.';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER prevent_delete_trigger
BEFORE DELETE ON enrollment
FOR EACH ROW
EXECUTE FUNCTION prevent_physical_delete();
```

Se necessarário criaria uma política de expurgo para remover fisicamente registros muito antigos, a exemplo.

```sql
DELETE FROM enrollment
WHERE deleted_at < CURRENT_DATE - INTERVAL '1 year';
```

### Nova Definição da Tabela

```sql
CREATE TABLE enrollment_base (
    id SERIAL PRIMARY KEY,
    tenant_id INTEGER NOT NULL,
    institution_id INTEGER,
    person_id INTEGER NOT NULL,
    course_id INTEGER NOT NULL,
    enrollment_date DATE NOT NULL,
    status VARCHAR(20) NOT NULL,
    deleted_at TIMESTAMP NULL
) PARTITION BY RANGE (enrollment_date);

CREATE TABLE enrollment_2024 PARTITION OF enrollment_base
FOR VALUES FROM ('2024-01-01') TO ('2025-01-01');
```

**OBS:**
- O particionamento por `enrollment_date` facilita a exclusão de dados antigos e melhora o desempenho em consultas por intervalo de datas.

---

## Melhorias e Sugestões

1. **Tabelas Materializadas:**
   Considere criar tabelas materializadas para relatórios frequentes, otimizando desempenho.

2. **Triggers para Auditoria:**
   Configure triggers para registrar alterações em tabelas críticas.

3. **Documentação:**
   Mantenha uma documentação detalhada sobre índices e particionamento para facilitar manutenções futuras.

---

## Como Executar

1. Clone o repositório:
   ```bash
   git clone <URL_DO_REPOSITORIO>
   ```
2. Execute o script SQL em um ambiente PostgreSQL:
   ```bash
   psql -U <usuario> -d <banco> -f script.sql
   ```
3. Ajuste os parâmetros nas consultas conforme necessário.

---

## Licença

Este projeto segue a licença MIT. Sinta-se à vontade para modificar e reutilizar conforme necessário.

