-- =====================================================================
-- HIFS 차량 등록 — Supabase(PostgreSQL) 스키마
-- 사용법: Supabase 대시보드 > SQL Editor > New query 에 전체 붙여넣고 Run
--         (여러 번 실행해도 기존 데이터는 지워지지 않습니다)
--
-- 보안 원칙
--  · 일반 방문자(anon)는 "등록(register_family 함수)"만 가능, 어떤 데이터도 읽을 수 없음
--  · 관리자 = admins 테이블에 등록된 계정으로 로그인했을 때만 조회/수정 가능
--      최고 관리자(super): 조회·등록·메모 + 삭제, CSV 업로드, 관리자 관리
--      일반 관리자(staff): 조회·등록·메모
-- =====================================================================

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------------
-- 1. 반 목록 (나중에 수정 → 여기 데이터만 바꾸면 화면 드롭다운에 반영)
--    목록이 있는 소속은 드롭다운, 없는 소속은 직접 입력
-- ---------------------------------------------------------------------
create table if not exists public.class_options (
  id          bigint generated always as identity primary key,
  affiliation text not null check (affiliation in ('HIFS 유치부','HIFS Global','HIFS English')),
  label       text not null,
  sort_order  int  not null default 0,
  is_active   boolean not null default true,
  unique (affiliation, label)
);

insert into public.class_options (affiliation, label, sort_order) values
  ('HIFS English', '월수금 1부', 1), ('HIFS English', '월수금 2부', 2),
  ('HIFS English', '화목 1부',   3), ('HIFS English', '화목 2부',   4)
on conflict (affiliation, label) do nothing;

-- ---------------------------------------------------------------------
-- 2. 가족 (형제자매 묶음) — 연락처·차량은 가족 단위로 공유
-- ---------------------------------------------------------------------
create table if not exists public.families (
  id          uuid primary key default gen_random_uuid(),
  source      text not null default 'self' check (source in ('self','admin','csv')),
  memo        text,                       -- 관리자 메모(특이사항)
  consent_at  timestamptz,                -- 개인정보 동의 시각
  created_at  timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- 3. 학생
-- ---------------------------------------------------------------------
create table if not exists public.students (
  id          uuid primary key default gen_random_uuid(),
  family_id   uuid not null references public.families(id) on delete cascade,
  affiliation text not null check (affiliation in ('HIFS 유치부','HIFS Global','HIFS English')),
  name_ko     text not null check (char_length(name_ko) between 1 and 50),
  name_en     text not null check (char_length(name_en) between 1 and 80),
  class_name  text not null check (char_length(class_name) between 1 and 50),
  created_at  timestamptz not null default now()
);
create index if not exists students_family_idx on public.students(family_id);
create index if not exists students_aff_idx    on public.students(affiliation, class_name);

-- ---------------------------------------------------------------------
-- 4. 학부모(보호자) 연락처
-- ---------------------------------------------------------------------
create table if not exists public.guardian_contacts (
  id          uuid primary key default gen_random_uuid(),
  family_id   uuid not null references public.families(id) on delete cascade,
  relation    text not null check (char_length(relation) between 1 and 20),  -- 부, 모, 할머니 ...
  phone       text not null check (phone ~ '^0[0-9]{1,2}-[0-9]{3,4}-[0-9]{4}$'),
  sort_order  int  not null default 0
);
create index if not exists contacts_family_idx on public.guardian_contacts(family_id);

-- ---------------------------------------------------------------------
-- 5. 교직원 · 외부강사 (관리자만 등록)
-- ---------------------------------------------------------------------
create table if not exists public.staff (
  id          uuid primary key default gen_random_uuid(),
  kind        text not null default 'staff' check (kind in ('staff','external')),  -- staff: 교직원 / external: 외부강사
  name_ko     text not null check (char_length(name_ko) between 1 and 50),
  name_en     text,
  department  text check (department is null or char_length(department) <= 50),  -- 부서 (선택)
  role        text,                                                          -- 담당
  phone       text not null check (phone ~ '^0[0-9]{1,2}-[0-9]{3,4}-[0-9]{4}$'),
  memo        text,
  source      text not null default 'admin' check (source in ('admin','csv')),
  created_at  timestamptz not null default now()
);
-- 예전에 만든 staff 표 보완: 구분(교직원/외부강사) 칸 추가, 부서는 선택 입력
alter table public.staff add column if not exists kind text not null default 'staff';
alter table public.staff drop constraint if exists staff_kind_check;
alter table public.staff add constraint staff_kind_check check (kind in ('staff','external'));
alter table public.staff alter column department drop not null;
alter table public.staff drop constraint if exists staff_department_check;
alter table public.staff add constraint staff_department_check check (department is null or char_length(department) <= 50);

-- ---------------------------------------------------------------------
-- 6. 차량 — 가족 또는 교직원 중 정확히 하나에 소속
-- ---------------------------------------------------------------------
create table if not exists public.vehicles (
  id               uuid primary key default gen_random_uuid(),
  family_id        uuid references public.families(id) on delete cascade,
  staff_id         uuid references public.staff(id)    on delete cascade,
  plate_number     text not null,                       -- 표시용 '123가 4567'
  plate_normalized text generated always as (regexp_replace(plate_number, '[[:space:]-]', '', 'g')) stored, -- 검색용 '123가4567'
  owner_label      text check (owner_label is null or char_length(owner_label) <= 50), -- '아빠 차'
  sort_order       int not null default 0,
  created_at       timestamptz not null default now(),
  check (num_nonnulls(family_id, staff_id) = 1),
  check (regexp_replace(plate_number, '[[:space:]-]', '', 'g') ~ '^([가-힣]{2})?[0-9]{2,3}[가-힣][0-9]{4}$')
);
create index if not exists vehicles_plate_idx  on public.vehicles(plate_normalized);
create index if not exists vehicles_family_idx on public.vehicles(family_id);
create index if not exists vehicles_staff_idx  on public.vehicles(staff_id);

-- ---------------------------------------------------------------------
-- 7. 관리자 목록 & 활동 기록
-- ---------------------------------------------------------------------
create table if not exists public.admins (
  user_id      uuid primary key references auth.users(id) on delete cascade,
  display_name text not null,
  role         text not null default 'staff' check (role in ('super','staff')),  -- super: 최고 관리자 / staff: 일반 관리자
  created_at   timestamptz not null default now()
);
-- 예전에 만든 admins 표에 권한 칸이 없으면 추가
alter table public.admins add column if not exists role text not null default 'staff';
alter table public.admins drop constraint if exists admins_role_check;
alter table public.admins add constraint admins_role_check check (role in ('super','staff'));

create table if not exists public.audit_logs (
  id          bigint generated always as identity primary key,
  user_id     uuid default auth.uid(),
  action      text not null,          -- search, csv_import ...
  detail      text,
  created_at  timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- 8. 관리자 판별 함수
--    로그인한 계정이 admins 에 있으면 true
-- ---------------------------------------------------------------------
create or replace function public.is_admin()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.admins where user_id = auth.uid());
$$;

-- 학생이 모두 삭제된 가족은 자동 삭제 (연락처·차량도 함께 삭제됨)
create or replace function public.delete_empty_family()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  delete from public.families f
   where f.id = old.family_id
     and not exists (select 1 from public.students s where s.family_id = old.family_id);
  return null;
end $$;
drop trigger if exists students_cleanup on public.students;
create trigger students_cleanup after delete on public.students
  for each row execute function public.delete_empty_family();

-- ---------------------------------------------------------------------
-- 9. 등록 함수 (학부모 공개 등록 + 관리자 등록 공용)
--    anon 은 테이블에 직접 쓸 수 없고 이 함수로만 등록 가능
-- ---------------------------------------------------------------------
create or replace function public.register_family(p jsonb)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_admin boolean := public.is_admin();
  v_fid   uuid;
  v_src   text;
  v_memo  text;
  r       jsonb;
  i       int;
begin
  if jsonb_typeof(p->'students') is distinct from 'array' or jsonb_array_length(p->'students') not between 1 and 6 then
    raise exception '학생 정보를 확인해 주세요.';
  end if;
  if jsonb_typeof(p->'contacts') is distinct from 'array' or jsonb_array_length(p->'contacts') not between 1 and 10 then
    raise exception '연락처를 1개 이상 입력해 주세요.';
  end if;
  if jsonb_typeof(p->'vehicles') is distinct from 'array' or jsonb_array_length(p->'vehicles') not between 1 and 10 then
    raise exception '차량 번호를 1대 이상 입력해 주세요.';
  end if;
  if not v_admin and coalesce((p->>'consent')::boolean, false) = false then
    raise exception '개인정보 수집·이용 동의가 필요합니다.';
  end if;

  if v_admin then
    v_src  := case when p->>'source' in ('admin','csv') then p->>'source' else 'admin' end;
    v_memo := nullif(btrim(p->>'memo'), '');
  else
    v_src := 'self'; v_memo := null;            -- 일반 방문자는 메모/출처 지정 불가
  end if;

  insert into public.families (source, memo, consent_at)
  values (v_src, v_memo, case when coalesce((p->>'consent')::boolean, false) then now() end)
  returning id into v_fid;

  for r in select value from jsonb_array_elements(p->'students') loop
    insert into public.students (family_id, affiliation, name_ko, name_en, class_name)
    values (v_fid, r->>'affiliation', btrim(r->>'nameKo'), btrim(r->>'nameEn'), btrim(r->>'className'));
  end loop;

  i := 0;
  for r in select value from jsonb_array_elements(p->'contacts') loop
    insert into public.guardian_contacts (family_id, relation, phone, sort_order)
    values (v_fid, coalesce(nullif(btrim(r->>'relation'), ''), '기타'), btrim(r->>'phone'), i);
    i := i + 1;
  end loop;

  i := 0;
  for r in select value from jsonb_array_elements(p->'vehicles') loop
    insert into public.vehicles (family_id, plate_number, owner_label, sort_order)
    values (v_fid, btrim(r->>'plate'), nullif(btrim(r->>'owner'), ''), i);
    i := i + 1;
  end loop;

  return v_fid;
end $$;

-- 교직원 · 외부강사 등록 (관리자 전용)
create or replace function public.add_staff(p jsonb)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_id uuid; r jsonb; i int := 0;
begin
  if not public.is_admin() then raise exception '권한이 없습니다.'; end if;
  if jsonb_typeof(p->'vehicles') is distinct from 'array' or jsonb_array_length(p->'vehicles') = 0 then
    raise exception '차량 번호를 1대 이상 입력해 주세요.';
  end if;

  insert into public.staff (kind, name_ko, name_en, department, role, phone, memo, source)
  values (case when p->>'kind' = 'external' then 'external' else 'staff' end, btrim(p->>'nameKo'), nullif(btrim(p->>'nameEn'), ''), nullif(btrim(p->>'dept'), ''), nullif(btrim(p->>'role'), ''),
          btrim(p->>'phone'), nullif(btrim(p->>'memo'), ''), case when p->>'source' = 'csv' then 'csv' else 'admin' end)
  returning id into v_id;

  for r in select value from jsonb_array_elements(p->'vehicles') loop
    insert into public.vehicles (staff_id, plate_number, owner_label, sort_order)
    values (v_id, btrim(r->>'plate'), nullif(btrim(r->>'owner'), ''), i);
    i := i + 1;
  end loop;
  return v_id;
end $$;

-- ---------------------------------------------------------------------
-- 10. 행 수준 보안(RLS) — 관리자만 읽기/수정
-- ---------------------------------------------------------------------
alter table public.class_options     enable row level security;
alter table public.families          enable row level security;
alter table public.students          enable row level security;
alter table public.guardian_contacts enable row level security;
alter table public.staff             enable row level security;
alter table public.vehicles          enable row level security;
alter table public.admins            enable row level security;
alter table public.audit_logs        enable row level security;

drop policy if exists class_read on public.class_options;
create policy class_read  on public.class_options for select to anon, authenticated using (is_active or public.is_admin());

drop policy if exists admins_self on public.admins;
create policy admins_self on public.admins for select to authenticated using (user_id = auth.uid());

drop policy if exists audit_insert on public.audit_logs;
create policy audit_insert on public.audit_logs for insert to authenticated with check (public.is_admin() and user_id = auth.uid());
drop policy if exists audit_read on public.audit_logs;
create policy audit_read   on public.audit_logs for select to authenticated using (public.is_admin());

-- 방문자(anon)는 반 목록 읽기 외에 테이블 접근 불가
revoke all on all tables in schema public from anon;
grant select on public.class_options to anon;

-- 함수 실행 권한
revoke execute on function public.register_family(jsonb), public.add_staff(jsonb), public.is_admin()
  from public, anon, authenticated;
grant execute on function public.register_family(jsonb) to anon, authenticated;
grant execute on function public.is_admin()             to anon, authenticated;
grant execute on function public.add_staff(jsonb)       to authenticated;

-- ---------------------------------------------------------------------
-- 11. 관리자 권한 (최고 관리자 / 일반 관리자)
-- ---------------------------------------------------------------------
-- 최고 관리자 판별
create or replace function public.is_super()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.admins where user_id = auth.uid() and role = 'super');
$$;

-- 데이터 권한: 보기·등록·메모 수정 = 모든 관리자 / 삭제 = 최고 관리자만
do $$
declare t text;
begin
  foreach t in array array['families','students','guardian_contacts','staff','vehicles'] loop
    execute format('drop policy if exists admin_all    on public.%I', t);
    execute format('drop policy if exists admin_read   on public.%I', t);
    execute format('drop policy if exists admin_insert on public.%I', t);
    execute format('drop policy if exists admin_update on public.%I', t);
    execute format('drop policy if exists super_delete on public.%I', t);
    execute format('create policy admin_read   on public.%I for select to authenticated using (public.is_admin())', t);
    execute format('create policy admin_insert on public.%I for insert to authenticated with check (public.is_admin())', t);
    execute format('create policy admin_update on public.%I for update to authenticated using (public.is_admin()) with check (public.is_admin())', t);
    execute format('create policy super_delete on public.%I for delete to authenticated using (public.is_super())', t);
  end loop;
end $$;

-- 반 목록 수정은 최고 관리자만
drop policy if exists class_admin on public.class_options;
create policy class_admin on public.class_options for all to authenticated using (public.is_super()) with check (public.is_super());

-- CSV 일괄 반영: 최고 관리자만
create or replace function public.admin_import(p jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare r jsonb; nf int := 0; ns int := 0;
begin
  if not public.is_super() then raise exception 'CSV 업로드는 최고 관리자만 할 수 있습니다.'; end if;
  for r in select value from jsonb_array_elements(coalesce(p->'families', '[]'::jsonb)) loop
    perform public.register_family(r || '{"source":"csv"}'::jsonb); nf := nf + 1;
  end loop;
  for r in select value from jsonb_array_elements(coalesce(p->'staff', '[]'::jsonb)) loop
    perform public.add_staff(r || '{"source":"csv"}'::jsonb); ns := ns + 1;
  end loop;
  insert into public.audit_logs (user_id, action, detail) values (auth.uid(), 'csv_import', format('가족 %s건, 교직원 %s건', nf, ns));
  return jsonb_build_object('families', nf, 'staff', ns);
end $$;

-- 관리자 목록 (최고 관리자만)
create or replace function public.list_admins()
returns table (user_id uuid, email text, display_name text, role text, created_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
begin
  if not public.is_super() then raise exception '최고 관리자만 볼 수 있습니다.'; end if;
  return query
    select a.user_id, u.email::text, a.display_name, a.role, a.created_at
      from public.admins a join auth.users u on u.id = a.user_id
     order by case a.role when 'super' then 0 else 1 end, a.created_at;
end $$;

-- 관리자 추가 / 권한 변경 (최고 관리자만, 계정은 Supabase Users 에 먼저 있어야 함)
create or replace function public.set_admin(p_email text, p_name text, p_role text)
returns void language plpgsql security definer set search_path = public as $$
declare v_uid uuid;
begin
  if not public.is_super() then raise exception '최고 관리자만 관리자를 지정할 수 있습니다.'; end if;
  if p_role not in ('super','staff') then raise exception '권한 값이 올바르지 않습니다.'; end if;
  select id into v_uid from auth.users where lower(email) = lower(btrim(p_email));
  if v_uid is null then
    raise exception '이 이메일로 만든 계정이 없습니다. Supabase > Authentication > Users 에서 먼저 계정을 만들어 주세요.';
  end if;
  insert into public.admins (user_id, display_name, role)
  values (v_uid, coalesce(nullif(btrim(p_name), ''), split_part(btrim(p_email), '@', 1)), p_role)
  on conflict (user_id) do update
    set display_name = coalesce(nullif(btrim(p_name), ''), public.admins.display_name),
        role = excluded.role;
  if not exists (select 1 from public.admins where role = 'super') then
    raise exception '최고 관리자는 최소 1명 있어야 합니다.';
  end if;
  insert into public.audit_logs (user_id, action, detail) values (auth.uid(), 'set_admin', format('%s → %s', p_email, p_role));
end $$;

-- 관리자에서 빼기 (계정 자체는 남음)
create or replace function public.remove_admin(p_user_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_super() then raise exception '최고 관리자만 관리자를 뺄 수 있습니다.'; end if;
  delete from public.admins where user_id = p_user_id;
  if not exists (select 1 from public.admins where role = 'super') then
    raise exception '최고 관리자는 최소 1명 있어야 합니다.';
  end if;
  insert into public.audit_logs (user_id, action, detail) values (auth.uid(), 'remove_admin', p_user_id::text);
end $$;

revoke execute on function public.is_super(), public.list_admins(), public.set_admin(text, text, text), public.remove_admin(uuid), public.admin_import(jsonb)
  from public, anon;
grant execute on function public.is_super()                      to authenticated;
grant execute on function public.list_admins()                   to authenticated;
grant execute on function public.set_admin(text, text, text)     to authenticated;
grant execute on function public.remove_admin(uuid)              to authenticated;
grant execute on function public.admin_import(jsonb)             to authenticated;

-- =====================================================================
-- 첫 최고 관리자 지정 (처음 한 번만, SQL Editor 에서 실행)
--  1) Authentication > Users > Add user 로 본인 계정 생성
--  2) 아래 이메일·이름만 바꿔 실행 → 이후 관리자 추가/권한 변경은 홈페이지 '관리자 관리' 탭에서
-- =====================================================================
-- insert into public.admins (user_id, display_name, role)
-- select id, '홍길동', 'super' from auth.users where email = 'teacher1@hifs.kr'
-- on conflict (user_id) do update set role = 'super';
