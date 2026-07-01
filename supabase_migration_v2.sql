-- NOUS v2 backend migration. Run AFTER v1.
-- Changes:
--   1. Add full-text search column (tsvector, generated) on derived `atom_view`.
--   2. Materialize backlink count per atom from `linked` events.
--   3. Replace semantic_search RPC with PRD formula:
--        S_final = S_vec * exp(-lambda_per_year * t_years)
--        Override (S_final = S_vec) if exact keyword hit OR backlinks > 3.
--   4. Add a separate RPC for backend-side enriched queries
--      (returns atom payload + score + match reason).

-- ─── 1. Atom-projection view ─────────────────────────────────────────────
-- Folds events into the latest snapshot per atom (current text + tags + type
-- + soft-delete flag + backlink count). Cheap to query, no triggers needed.

create or replace view public.atom_view as
with latest_text as (
    select distinct on (e.atom_id)
        e.atom_id,
        e.user_id,
        coalesce(e.payload->>'refinedContent', e.payload->>'content') as content,
        e.payload->>'content' as raw_content,
        e.payload->>'refinedContent' as refined_content
    from public.events e
    where e.user_id is not null
      and e.kind in ('created','updatedRaw','refined')
      and coalesce(e.payload->>'refinedContent', e.payload->>'content') is not null
    order by e.atom_id, e.created_at desc
),
latest_type as (
    select distinct on (e.atom_id)
        e.atom_id,
        coalesce(e.payload->>'type', 'thought') as atom_type
    from public.events e
    where e.kind in ('created','typeChanged')
      and e.payload ? 'type'
    order by e.atom_id, e.created_at desc
),
created_at_per_atom as (
    select atom_id, min(created_at) as created_at
    from public.events
    where kind = 'created'
    group by atom_id
),
soft_deleted as (
    select atom_id
    from public.events
    where kind = 'deleted'
    group by atom_id
),
backlink_counts as (
    -- count incoming "linked" events targeting each atom
    select (e.payload->>'linkTargetID')::uuid as atom_id,
           count(*)::int                       as inbound_links
    from public.events e
    where e.kind = 'linked'
      and (e.payload->>'linkTargetID') is not null
    group by (e.payload->>'linkTargetID')::uuid
),
tag_agg as (
    -- last `tagged` event per atom wins
    select distinct on (e.atom_id)
        e.atom_id,
        coalesce(
            array(select jsonb_array_elements_text(e.payload->'tags')),
            ARRAY[]::text[]
        ) as tags
    from public.events e
    where e.kind = 'tagged'
    order by e.atom_id, e.created_at desc
)
select
    lt.atom_id,
    lt.user_id,
    lt.content,
    lt.raw_content,
    lt.refined_content,
    coalesce(ty.atom_type, 'thought') as atom_type,
    cap.created_at,
    coalesce(bl.inbound_links, 0) as inbound_links,
    coalesce(t.tags, ARRAY[]::text[]) as tags,
    (sd.atom_id is not null) as is_deleted,
    to_tsvector('english', lt.content) as content_tsv
from latest_text lt
left join latest_type ty       on ty.atom_id = lt.atom_id
left join created_at_per_atom cap on cap.atom_id = lt.atom_id
left join backlink_counts bl   on bl.atom_id = lt.atom_id
left join tag_agg t            on t.atom_id  = lt.atom_id
left join soft_deleted sd      on sd.atom_id = lt.atom_id;

-- ─── 2. PRD-correct semantic_search RPC ──────────────────────────────────
-- Formula:
--   S_final = S_vec * exp(-lambda_per_year * t_years)
--   Override (S_final = S_vec) when:
--     a) exact keyword/FTS match against query_text, OR
--     b) inbound_links > 3
--
-- lambda default = ln(1/0.9) / 0.5 ≈ 0.21072 → ~10% decay per 6 months.

drop function if exists public.semantic_search(uuid, vector, int, float8);

create or replace function public.semantic_search(
    user_id            uuid,
    query_vector       vector(768),
    query_text         text     default null,
    match_count        int      default 20,
    decay_lambda_year  float8   default 0.21072,
    backlink_threshold int      default 3
)
returns table (
    atom_id        uuid,
    score          float8,
    raw_score      float8,
    decayed        boolean,
    inbound_links  int,
    snippet        text,
    atom_type      text,
    created_at     timestamptz
)
language sql stable
as $$
    with q as (
        select
            case
                when query_text is null or length(trim(query_text)) = 0 then null
                else plainto_tsquery('english', query_text)
            end as ts_q
    ),
    candidates as (
        select
            em.atom_id,
            em.vector,
            em.updated_at,
            av.content,
            av.atom_type,
            av.created_at,
            av.inbound_links,
            av.content_tsv
        from public.embeddings em
        join public.atom_view av on av.atom_id = em.atom_id
        where em.user_id = semantic_search.user_id
          and av.is_deleted = false
    ),
    scored as (
        select
            c.atom_id,
            (1.0 - (c.vector <=> semantic_search.query_vector))::float8 as raw_score,
            extract(epoch from (now() - c.created_at)) / 31557600.0     as t_years, -- 365.25 d
            c.inbound_links,
            c.content,
            c.atom_type,
            c.created_at,
            (
                (q.ts_q is not null and c.content_tsv @@ q.ts_q)
                or c.inbound_links > semantic_search.backlink_threshold
            ) as no_decay
        from candidates c, q
    )
    select
        s.atom_id,
        case
            when s.no_decay then s.raw_score
            else s.raw_score * exp(- semantic_search.decay_lambda_year * s.t_years)
        end as score,
        s.raw_score,
        (not s.no_decay) as decayed,
        s.inbound_links,
        left(s.content, 240) as snippet,
        s.atom_type,
        s.created_at
    from scored s
    order by score desc
    limit semantic_search.match_count;
$$;

-- ─── 3. Backend-only RPC: returns FULL content (not just snippet)
-- Used by FastAPI /synthesize for retrieval-augmented generation.

create or replace function public.semantic_search_full(
    user_id            uuid,
    query_vector       vector(768),
    query_text         text     default null,
    match_count        int      default 12,
    decay_lambda_year  float8   default 0.21072,
    backlink_threshold int      default 3
)
returns table (
    atom_id        uuid,
    score          float8,
    raw_score      float8,
    decayed        boolean,
    inbound_links  int,
    content        text,
    atom_type      text,
    created_at     timestamptz,
    tags           text[]
)
language sql stable
as $$
    with q as (
        select
            case
                when query_text is null or length(trim(query_text)) = 0 then null
                else plainto_tsquery('english', query_text)
            end as ts_q
    ),
    candidates as (
        select em.atom_id, em.vector, em.updated_at,
               av.content, av.atom_type, av.created_at,
               av.inbound_links, av.content_tsv, av.tags
        from public.embeddings em
        join public.atom_view av on av.atom_id = em.atom_id
        where em.user_id = semantic_search_full.user_id
          and av.is_deleted = false
    ),
    scored as (
        select
            c.atom_id,
            (1.0 - (c.vector <=> semantic_search_full.query_vector))::float8 as raw_score,
            extract(epoch from (now() - c.created_at)) / 31557600.0 as t_years,
            c.inbound_links, c.content, c.atom_type, c.created_at, c.tags,
            ((q.ts_q is not null and c.content_tsv @@ q.ts_q)
             or c.inbound_links > semantic_search_full.backlink_threshold) as no_decay
        from candidates c, q
    )
    select
        s.atom_id,
        case when s.no_decay then s.raw_score
             else s.raw_score * exp(- semantic_search_full.decay_lambda_year * s.t_years)
        end as score,
        s.raw_score,
        (not s.no_decay) as decayed,
        s.inbound_links,
        s.content,
        s.atom_type,
        s.created_at,
        s.tags
    from scored s
    order by score desc
    limit semantic_search_full.match_count;
$$;

-- ─── 4. Recent atoms RPC for pushback scan ───────────────────────────────
create or replace function public.recent_atoms(
    user_id      uuid,
    limit_count  int default 40,
    since_days   int default 30
)
returns table (
    atom_id     uuid,
    content     text,
    atom_type   text,
    created_at  timestamptz,
    tags        text[]
)
language sql stable
as $$
    select av.atom_id, av.content, av.atom_type, av.created_at, av.tags
    from public.atom_view av
    where av.user_id = recent_atoms.user_id
      and av.is_deleted = false
      and av.created_at >= now() - (recent_atoms.since_days || ' days')::interval
    order by av.created_at desc
    limit recent_atoms.limit_count;
$$;

-- ─── 5. Grants ───────────────────────────────────────────────────────────
grant execute on function public.semantic_search(uuid, vector, text, int, float8, int) to anon;
grant execute on function public.semantic_search_full(uuid, vector, text, int, float8, int) to anon;
grant execute on function public.recent_atoms(uuid, int, int) to anon;
grant select on public.atom_view to anon;
