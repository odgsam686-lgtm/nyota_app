create table if not exists public.transcode_jobs (
  id uuid primary key default gen_random_uuid(),
  bucket text not null,
  object_name text not null,
  status text not null default 'pending',
  attempts int not null default 0,
  error text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists transcode_jobs_status_created_at_idx
  on public.transcode_jobs (status, created_at);

create unique index if not exists transcode_jobs_bucket_object_unique
  on public.transcode_jobs (bucket, object_name);

create or replace function public.set_transcode_jobs_updated_at()
returns trigger as $$
begin
  new.updated_at = now();
  return new;
end;
$$ language plpgsql;

drop trigger if exists trg_transcode_jobs_updated_at on public.transcode_jobs;
create trigger trg_transcode_jobs_updated_at
before update on public.transcode_jobs
for each row execute procedure public.set_transcode_jobs_updated_at();
