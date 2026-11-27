-- PDM GAMING: ví nạp tiền (chạy trong Supabase SQL Editor)
-- Số dư chỉ được cộng bởi hàm quản trị sau khi xác nhận đã nhận tiền thật.

create table if not exists public.wallet_balances (
  user_id uuid primary key references auth.users(id) on delete cascade,
  balance bigint not null default 0 check (balance >= 0),
  updated_at timestamptz not null default now()
);

create table if not exists public.wallet_topups (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  amount bigint not null check (amount >= 10000 and amount % 10000 = 0),
  transfer_note text not null unique,
  payment_proof_path text,
  status text not null default 'pending' check (status in ('pending','approved','rejected')),
  created_at timestamptz not null default now(),
  reviewed_at timestamptz
);

create table if not exists public.wallet_transactions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  type text not null check (type in ('topup')),
  amount bigint not null check (amount > 0),
  reference_id uuid not null unique references public.wallet_topups(id),
  created_at timestamptz not null default now()
);

alter table public.wallet_balances enable row level security;
alter table public.wallet_topups enable row level security;
alter table public.wallet_transactions enable row level security;

drop policy if exists "wallet read own or admin" on public.wallet_balances;
create policy "wallet read own or admin" on public.wallet_balances
for select to authenticated using (auth.uid() = user_id or public.is_admin());

drop policy if exists "topups read own or admin" on public.wallet_topups;
create policy "topups read own or admin" on public.wallet_topups
for select to authenticated using (auth.uid() = user_id or public.is_admin());

drop policy if exists "topups create own pending" on public.wallet_topups;
create policy "topups create own pending" on public.wallet_topups
for insert to authenticated with check (auth.uid() = user_id and status = 'pending' and payment_proof_path is null);

drop policy if exists "wallet transactions read own or admin" on public.wallet_transactions;
create policy "wallet transactions read own or admin" on public.wallet_transactions
for select to authenticated using (auth.uid() = user_id or public.is_admin());

create or replace function public.submit_wallet_topup_proof(p_transfer_note text, p_path text)
returns void language plpgsql security definer set search_path = public, auth as $$
begin
  if auth.uid() is null then raise exception 'Vui lòng đăng nhập'; end if;
  if p_path is null or length(p_path) > 500 then raise exception 'Đường dẫn ảnh không hợp lệ'; end if;
  update public.wallet_topups
     set payment_proof_path = p_path
   where transfer_note = p_transfer_note
     and user_id = auth.uid()
     and status = 'pending';
  if not found then raise exception 'Không tìm thấy yêu cầu nạp đang chờ'; end if;
end; $$;
revoke all on function public.submit_wallet_topup_proof(text,text) from public;
grant execute on function public.submit_wallet_topup_proof(text,text) to authenticated;

create or replace function public.admin_approve_wallet_topup(p_topup_id uuid)
returns void language plpgsql security definer set search_path = public, auth as $$
declare t public.wallet_topups%rowtype;
begin
  if not public.is_admin() then raise exception 'Không có quyền quản trị'; end if;
  select * into t from public.wallet_topups where id = p_topup_id for update;
  if not found then raise exception 'Không tìm thấy yêu cầu nạp'; end if;
  if t.status <> 'pending' then raise exception 'Yêu cầu này đã được xử lý'; end if;
  if t.payment_proof_path is null then raise exception 'Khách chưa gửi ảnh chuyển khoản'; end if;
  update public.wallet_topups set status='approved', reviewed_at=now() where id=t.id;
  insert into public.wallet_balances(user_id,balance,updated_at)
  values(t.user_id,t.amount,now())
  on conflict(user_id) do update set balance=public.wallet_balances.balance+excluded.balance, updated_at=now();
  insert into public.wallet_transactions(user_id,type,amount,reference_id)
  values(t.user_id,'topup',t.amount,t.id);
end; $$;
revoke all on function public.admin_approve_wallet_topup(uuid) from public;
grant execute on function public.admin_approve_wallet_topup(uuid) to authenticated;

create or replace function public.admin_reject_wallet_topup(p_topup_id uuid)
returns void language plpgsql security definer set search_path = public, auth as $$
begin
  if not public.is_admin() then raise exception 'Không có quyền quản trị'; end if;
  update public.wallet_topups set status='rejected', reviewed_at=now()
   where id=p_topup_id and status='pending';
  if not found then raise exception 'Không tìm thấy yêu cầu đang chờ'; end if;
end; $$;
revoke all on function public.admin_reject_wallet_topup(uuid) from public;
grant execute on function public.admin_reject_wallet_topup(uuid) to authenticated;


-- ============================================================
-- PDM GAMING ONE-TIME UPGRADE: PROFILE, SELLERS, SUPPORT, NOTICE,
-- WITHDRAWALS, SELLER COMMISSION, CUSTOMER MANAGEMENT
-- Run after the existing wallet migration, or run this complete
-- combined file from top to bottom.
-- ============================================================

-- Profile social/contact details and seller state.
alter table public.profiles add column if not exists facebook_link text;
alter table public.profiles add column if not exists zalo_contact text;
alter table public.profiles add column if not exists contact_phone text;
alter table public.profiles add column if not exists contact_email text;
alter table public.profiles add column if not exists seller_status text not null default 'none';

-- User-facing announcements and individual notifications.
create table if not exists public.site_announcements (
  id uuid primary key default gen_random_uuid(),
  title text not null,
  message text not null,
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);
create table if not exists public.user_notifications (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  title text not null,
  body text not null,
  is_read boolean not null default false,
  created_at timestamptz not null default now()
);

-- Customer support tickets.
create table if not exists public.support_tickets (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  subject text not null,
  message text not null,
  contact text,
  status text not null default 'open' check (status in ('open','answered','closed')),
  admin_reply text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- Seller onboarding applications and five-percent platform commission records.
create table if not exists public.seller_applications (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  contact_email text,
  display_name text not null,
  contact text not null,
  game text,
  description text,
  status text not null default 'pending' check (status in ('pending','approved','rejected')),
  created_at timestamptz not null default now(),
  reviewed_at timestamptz
);

-- Add seller ownership to marketplace products and seller accounting to orders.
alter table public.products add column if not exists seller_id uuid references auth.users(id) on delete set null;
alter table public.products add column if not exists status text default 'active';
alter table public.orders add column if not exists product_id bigint;
alter table public.orders add column if not exists seller_id uuid references auth.users(id) on delete set null;
alter table public.orders add column if not exists platform_fee bigint not null default 0;
alter table public.orders add column if not exists seller_amount bigint not null default 0;
alter table public.orders add column if not exists seller_credited_at timestamptz;

create table if not exists public.seller_earnings (
  id uuid primary key default gen_random_uuid(),
  order_id text not null unique,
  seller_id uuid not null references auth.users(id) on delete cascade,
  sale_amount bigint not null check (sale_amount >= 0),
  platform_fee bigint not null check (platform_fee >= 0),
  seller_amount bigint not null check (seller_amount >= 0),
  created_at timestamptz not null default now()
);

-- General wallet ledger, kept separate from legacy top-up transactions.
create table if not exists public.wallet_ledger (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  tx_type text not null,
  amount bigint not null check (amount <> 0),
  reference_id text,
  description text,
  created_at timestamptz not null default now()
);

-- Withdrawals reserve funds immediately; rejecting a request refunds them.
create table if not exists public.wallet_withdrawals (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  amount bigint not null check (amount >= 10000 and amount % 10000 = 0),
  bank_name text not null,
  account_name text not null,
  account_number text not null,
  status text not null default 'pending' check (status in ('pending','paid','rejected')),
  created_at timestamptz not null default now(),
  reviewed_at timestamptz
);

-- RLS for new tables.
alter table public.site_announcements enable row level security;
alter table public.user_notifications enable row level security;
alter table public.support_tickets enable row level security;
alter table public.seller_applications enable row level security;
alter table public.seller_earnings enable row level security;
alter table public.wallet_ledger enable row level security;
alter table public.wallet_withdrawals enable row level security;

-- Remove/recreate policies so this migration can be run more than once.
drop policy if exists "announcements public active read" on public.site_announcements;
create policy "announcements public active read" on public.site_announcements
for select to anon, authenticated using (is_active = true or public.is_admin());
drop policy if exists "announcements admin manage" on public.site_announcements;
create policy "announcements admin manage" on public.site_announcements
for all to authenticated using (public.is_admin()) with check (public.is_admin());

drop policy if exists "notifications owner admin read" on public.user_notifications;
create policy "notifications owner admin read" on public.user_notifications
for select to authenticated using (auth.uid() = user_id or public.is_admin());
drop policy if exists "notifications owner mark read" on public.user_notifications;
create policy "notifications owner mark read" on public.user_notifications
for update to authenticated using (auth.uid() = user_id) with check (auth.uid() = user_id);
drop policy if exists "notifications admin insert" on public.user_notifications;
create policy "notifications admin insert" on public.user_notifications
for insert to authenticated with check (public.is_admin());

drop policy if exists "support owner admin read" on public.support_tickets;
create policy "support owner admin read" on public.support_tickets
for select to authenticated using (auth.uid() = user_id or public.is_admin());
drop policy if exists "support owner create" on public.support_tickets;
create policy "support owner create" on public.support_tickets
for insert to authenticated with check (auth.uid() = user_id and status = 'open');
drop policy if exists "support admin update" on public.support_tickets;
create policy "support admin update" on public.support_tickets
for update to authenticated using (public.is_admin()) with check (public.is_admin());

drop policy if exists "seller applications owner admin read" on public.seller_applications;
create policy "seller applications owner admin read" on public.seller_applications
for select to authenticated using (auth.uid() = user_id or public.is_admin());
drop policy if exists "seller applications owner insert" on public.seller_applications;
create policy "seller applications owner insert" on public.seller_applications
for insert to authenticated with check (auth.uid() = user_id and status = 'pending');
drop policy if exists "seller applications admin update" on public.seller_applications;
create policy "seller applications admin update" on public.seller_applications
for update to authenticated using (public.is_admin()) with check (public.is_admin());

drop policy if exists "seller earnings owner admin read" on public.seller_earnings;
create policy "seller earnings owner admin read" on public.seller_earnings
for select to authenticated using (auth.uid() = seller_id or public.is_admin());
drop policy if exists "wallet ledger owner admin read" on public.wallet_ledger;
create policy "wallet ledger owner admin read" on public.wallet_ledger
for select to authenticated using (auth.uid() = user_id or public.is_admin());
drop policy if exists "withdrawals owner admin read" on public.wallet_withdrawals;
create policy "withdrawals owner admin read" on public.wallet_withdrawals
for select to authenticated using (auth.uid() = user_id or public.is_admin());

-- Customer directory: user can read/update own profile; admins can read all profiles.
drop policy if exists "profiles admin read directory" on public.profiles;
create policy "profiles admin read directory" on public.profiles
for select to authenticated using (public.is_admin());

-- Allow approved sellers to submit their own listings for review.
drop policy if exists "approved seller insert product listing" on public.products;
create policy "approved seller insert product listing" on public.products
for insert to authenticated with check (
  auth.uid() = seller_id and status = 'pending' and
  exists (select 1 from public.profiles p where p.auth_user_id = auth.uid() and p.seller_status = 'approved')
);
drop policy if exists "approved seller update own pending listing" on public.products;
create policy "approved seller update own pending listing" on public.products
for update to authenticated using (
  auth.uid() = seller_id and status = 'pending' and
  exists (select 1 from public.profiles p where p.auth_user_id = auth.uid() and p.seller_status = 'approved')
) with check (auth.uid() = seller_id);
drop policy if exists "admin review marketplace listings" on public.products;
create policy "admin review marketplace listings" on public.products
for update to authenticated using (public.is_admin()) with check (public.is_admin());

-- Seller registration review RPC.
create or replace function public.admin_review_seller_application(p_application_id uuid, p_action text)
returns void language plpgsql security definer set search_path = public, auth as $$
declare a public.seller_applications%rowtype;
begin
  if not public.is_admin() then raise exception 'Không có quyền quản trị'; end if;
  if p_action not in ('approve','reject') then raise exception 'Thao tác không hợp lệ'; end if;
  select * into a from public.seller_applications where id=p_application_id for update;
  if not found then raise exception 'Không tìm thấy đăng ký người bán'; end if;
  if a.status <> 'pending' then raise exception 'Đăng ký đã được xử lý'; end if;
  update public.seller_applications set status=case when p_action='approve' then 'approved' else 'rejected' end, reviewed_at=now() where id=a.id;
  update public.profiles set seller_status=case when p_action='approve' then 'approved' else 'rejected' end where auth_user_id=a.user_id;
end; $$;
revoke all on function public.admin_review_seller_application(uuid,text) from public;
grant execute on function public.admin_review_seller_application(uuid,text) to authenticated;

-- Atomic withdrawal request: deduct available balance before saving the request.
create or replace function public.request_wallet_withdrawal(p_amount bigint,p_bank_name text,p_account_name text,p_account_number text)
returns uuid language plpgsql security definer set search_path = public, auth as $$
declare uid uuid:=auth.uid(); wid uuid;
begin
  if uid is null then raise exception 'Vui lòng đăng nhập'; end if;
  if p_amount < 10000 or p_amount % 10000 <> 0 then raise exception 'Số tiền rút phải từ 10.000đ và theo bội số 10.000đ'; end if;
  if coalesce(length(trim(p_bank_name)),0)<2 or coalesce(length(trim(p_account_name)),0)<2 or coalesce(length(trim(p_account_number)),0)<5 then raise exception 'Thông tin nhận tiền không hợp lệ'; end if;
  update public.wallet_balances set balance=balance-p_amount,updated_at=now() where user_id=uid and balance>=p_amount;
  if not found then raise exception 'Số dư không đủ'; end if;
  insert into public.wallet_withdrawals(user_id,amount,bank_name,account_name,account_number)
  values(uid,p_amount,trim(p_bank_name),trim(p_account_name),trim(p_account_number)) returning id into wid;
  insert into public.wallet_ledger(user_id,tx_type,amount,reference_id,description)
  values(uid,'withdraw_request',-p_amount,wid::text,'Tạm giữ tiền cho yêu cầu rút ví');
  return wid;
end; $$;
revoke all on function public.request_wallet_withdrawal(bigint,text,text,text) from public;
grant execute on function public.request_wallet_withdrawal(bigint,text,text,text) to authenticated;

create or replace function public.admin_process_wallet_withdrawal(p_withdrawal_id uuid,p_status text)
returns void language plpgsql security definer set search_path = public, auth as $$
declare w public.wallet_withdrawals%rowtype;
begin
  if not public.is_admin() then raise exception 'Không có quyền quản trị'; end if;
  if p_status not in ('paid','rejected') then raise exception 'Trạng thái không hợp lệ'; end if;
  select * into w from public.wallet_withdrawals where id=p_withdrawal_id for update;
  if not found or w.status <> 'pending' then raise exception 'Yêu cầu không tồn tại hoặc đã xử lý'; end if;
  update public.wallet_withdrawals set status=p_status,reviewed_at=now() where id=w.id;
  if p_status='rejected' then
    insert into public.wallet_balances(user_id,balance,updated_at) values(w.user_id,w.amount,now())
    on conflict(user_id) do update set balance=public.wallet_balances.balance+excluded.balance,updated_at=now();
    insert into public.wallet_ledger(user_id,tx_type,amount,reference_id,description)
    values(w.user_id,'withdraw_refund',w.amount,w.id::text,'Hoàn tiền do yêu cầu rút bị từ chối');
  end if;
end; $$;
revoke all on function public.admin_process_wallet_withdrawal(uuid,text) from public;
grant execute on function public.admin_process_wallet_withdrawal(uuid,text) to authenticated;

-- 5% platform fee, 95% seller proceeds, credited once when the order is completed.
create or replace function public.credit_seller_after_order_completed()
returns trigger language plpgsql security definer set search_path = public, auth as $$
declare fee bigint; net bigint; inserted_id uuid;
begin
  if new.status='completed' and old.status is distinct from 'completed' and new.seller_id is not null then
    fee := floor(coalesce(new.amount,0)::numeric * 0.05)::bigint;
    net := greatest(coalesce(new.amount,0)::bigint - fee,0);
    update public.orders set platform_fee=fee,seller_amount=net,seller_credited_at=now() where id=new.id;
    insert into public.seller_earnings(order_id,seller_id,sale_amount,platform_fee,seller_amount)
    values(new.id::text,new.seller_id,coalesce(new.amount,0)::bigint,fee,net)
    on conflict(order_id) do nothing returning id into inserted_id;
    if inserted_id is not null then
      insert into public.wallet_balances(user_id,balance,updated_at) values(new.seller_id,net,now())
      on conflict(user_id) do update set balance=public.wallet_balances.balance+excluded.balance,updated_at=now();
      insert into public.wallet_ledger(user_id,tx_type,amount,reference_id,description)
      values(new.seller_id,'seller_sale',net,new.id::text,'Tiền bán tài khoản sau khi trừ phí nền tảng 5%');
    end if;
  end if;
  return new;
end; $$;
drop trigger if exists trg_credit_seller_after_order_completed on public.orders;
create trigger trg_credit_seller_after_order_completed
after update of status on public.orders
for each row execute function public.credit_seller_after_order_completed();

-- Indexes for account dashboards/admin screens.
create index if not exists idx_support_tickets_user_created on public.support_tickets(user_id,created_at desc);
create index if not exists idx_seller_apps_status_created on public.seller_applications(status,created_at desc);
create index if not exists idx_wallet_withdrawals_user_created on public.wallet_withdrawals(user_id,created_at desc);
create index if not exists idx_orders_seller_created on public.orders(seller_id,created_at desc);
create index if not exists idx_products_seller on public.products(seller_id);
