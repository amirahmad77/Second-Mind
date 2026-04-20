-- NOUS v1 schema. Single-user (no auth). pgvector 768-dim (Gemini embedding-001).
-- Run in Supabase SQL editor on project ssibcqwsaycnlzlxzked.

create extension if not exists vector;

-- Event-sourced ledger. Append-only.
create table if not exists public.events (
    id          uuid primary key,
    atom_id     uuid not null,
    user_id     uuid not null,
    kind        text not null,
    payload     jsonb not null default '{}'::jsonb,
    created_at  timestamptz not null default now()
);
create index if not exists events_atom_idx       on public.events (atom_id, created_at);
create index if not exists events_user_time_idx  on public.events (user_id, created_at desc);

-- Per-atom embedding. Upsert target.
create table if not exists public.embeddings (
    atom_id     uuid primary key,
    user_id     uuid not null,
    dim         int  not null,
    vector      vector(768) not null,
    updated_at  timestamptz not null default now()
);
create index if not exists embeddings_user_idx   on public.embeddings (user_id);
-- IVFFlat cosine. Build after some data lands (~>1k rows) for best recall.
create index if not exists embeddings_vec_idx
    on public.embeddings using ivfflat (vector vector_cosine_ops) with (lists = 100);

-- Semantic search with exponential time decay.
-- score = (1 - cosine_distance) * exp(-lambda * age_days)
create or replace function public.semantic_search(
    user_id        uuid,
    query_vector   vector(768),
    match_count    int    default 20,
    decay_lambda   float8 default 0.14
)
returns table (
    atom_id  uuid,
    score    float8,
    snippet  text
)
language sql stable
as $$
    with latest_content as (
        select distinct on (e.atom_id)
            e.atom_id,
            coalesce(
                e.payload->>'refinedContent',
                e.payload->>'content'
            ) as content
        from public.events e
        where e.user_id = semantic_search.user_id
          and e.kind in ('created','updatedRaw','refined')
          and coalesce(e.payload->>'refinedContent', e.payload->>'content') is not null
        order by e.atom_id, e.created_at desc
    ),
    not_deleted as (
        select atom_id
        from public.events
        where user_id = semantic_search.user_id
        group by atom_id
        having bool_or(kind = 'deleted') = false
    )
    select
        em.atom_id,
        ( (1.0 - (em.vector <=> semantic_search.query_vector))
          * exp( - semantic_search.decay_lambda
                 * extract(epoch from (now() - em.updated_at)) / 86400.0 )
        )::float8 as score,
        left(lc.content, 240) as snippet
    from public.embeddings em
    join not_deleted nd on nd.atom_id = em.atom_id
    left join latest_content lc on lc.atom_id = em.atom_id
    where em.user_id = semantic_search.user_id
    order by score desc
    limit semantic_search.match_count;
$$;

-- Single-user v1: permissive RLS so anon key can read/write own rows.
-- Tighten when auth lands.
alter table public.events      enable row level security;
alter table public.embeddings  enable row level security;

drop policy if exists events_anon_all      on public.events;
drop policy if exists embeddings_anon_all  on public.embeddings;

create policy events_anon_all     on public.events     for all using (true) with check (true);
create policy embeddings_anon_all on public.embeddings for all using (true) with check (true);

grant usage on schema public to anon;
grant all on public.events, public.embeddings to anon;
grant execute on function public.semantic_search(uuid, vector, int, float8) to anon;
