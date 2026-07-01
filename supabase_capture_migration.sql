-- NOUS web-capture migration. Adds extension pairing + token tables + meet-session
-- lookup index so /v1/capture can append to the same atom for a recurring meetID.

-- ─── Pairing codes ──────────────────────────────────────────────────────
-- iOS app calls /v1/pair/start → inserts row. Extension calls /v1/pair/complete
-- w/ the 6-digit code → row consumed, token minted. 10-min expiry.
create table if not exists public.pairing_codes (
    code        text primary key,
    user_id     uuid not null,
    expires_at  timestamptz not null,
    consumed    boolean not null default false,
    created_at  timestamptz not null default now()
);
create index if not exists pairing_codes_user_idx on public.pairing_codes (user_id, expires_at desc);

-- ─── Long-lived extension tokens ────────────────────────────────────────
-- Minted after successful pairing. Extension stores token in chrome.storage.
-- Revocable from iOS Settings (future).
create table if not exists public.extension_tokens (
    token          text primary key,
    user_id        uuid not null,
    label          text,                          -- "Arc on MacBook" etc.
    created_at     timestamptz not null default now(),
    last_used_at   timestamptz,
    revoked_at     timestamptz
);
create index if not exists extension_tokens_user_idx on public.extension_tokens (user_id);

-- ─── Meet session index ─────────────────────────────────────────────────
-- When /v1/capture arrives w/ kind=meet + meetID, we need to find the existing
-- atom for that (user_id, meetID) pair fast. Use a functional expression index
-- on events.payload->source->>meetID for `created` events.
create index if not exists events_meet_atom_idx
    on public.events ((payload #>> '{source,meetID}'))
    where kind = 'created';

alter table public.pairing_codes   enable row level security;
alter table public.extension_tokens enable row level security;

drop policy if exists pairing_codes_all   on public.pairing_codes;
drop policy if exists extension_tokens_all on public.extension_tokens;

create policy pairing_codes_all    on public.pairing_codes    for all using (true) with check (true);
create policy extension_tokens_all on public.extension_tokens for all using (true) with check (true);

grant all on public.pairing_codes, public.extension_tokens to anon;
