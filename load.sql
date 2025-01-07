-- Estrutura e Configuração Completa para o Desafio DBA

-- Tabela tenant
CREATE TABLE tenant (
    id SERIAL PRIMARY KEY,
    name VARCHAR(100) NOT NULL,
    description VARCHAR(255)
);

-- Tabela person
CREATE TABLE person (
    id SERIAL PRIMARY KEY,
    name VARCHAR(100) NOT NULL,
    birth_date DATE,
    metadata JSONB
);

-- Tabela institution
CREATE TABLE institution (
    id SERIAL PRIMARY KEY,
    tenant_id INTEGER NOT NULL REFERENCES tenant(id) ON DELETE CASCADE,
    name VARCHAR(100) NOT NULL,
    location VARCHAR(100),
    details JSONB
);

-- Tabela course
CREATE TABLE course (
    id SERIAL PRIMARY KEY,
    tenant_id INTEGER NOT NULL REFERENCES tenant(id) ON DELETE CASCADE,
    institution_id INTEGER REFERENCES institution(id) ON DELETE SET NULL,
    name VARCHAR(100) NOT NULL,
    duration INTEGER,
    details JSONB
);

-- Tabela enrollment
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

-- Índice de unicidade para garantir integridade na tabela enrollment
CREATE UNIQUE INDEX idx_enrollment_unique 
ON enrollment (tenant_id, institution_id, person_id) WHERE deleted_at IS NULL;

-- Índices Essenciais
-- Para a tabela person
CREATE INDEX idx_person_metadata_gin ON person USING gin (metadata jsonb_path_ops);

-- Para a tabela enrollment
CREATE INDEX idx_enrollment_status ON enrollment (status) WHERE deleted_at IS NULL;
CREATE INDEX idx_enrollment_date ON enrollment (enrollment_date);

-- Consultas Otimizadas

-- Número de Matrículas por Curso
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

-- Listagem de Alunos por Curso
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

-- Exclusão Lógica Implementada com deleted_at

-- Particionamento da Tabela enrollment
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

-- Partição para o ano de 2024
CREATE TABLE enrollment_2024 PARTITION OF enrollment_base
FOR VALUES FROM ('2024-01-01') TO ('2025-01-01');
