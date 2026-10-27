-- Atomic, retry-safe saving of transactions.
-- Run once in Supabase → SQL Editor.
--
-- Every save/edit/delete from the app carries an op_id. The function records the op_id,
-- writes the transaction and adjusts account balances / savings goals in ONE database
-- transaction. If the same op_id arrives again (retry on a slow network), nothing is applied twice.

create table if not exists public.transaction_ops (
    op_id uuid primary key,
    user_id uuid not null default auth.uid(),
    created_at timestamptz not null default now()
);

alter table public.transaction_ops enable row level security;

drop policy if exists "own transaction ops" on public.transaction_ops;
create policy "own transaction ops" on public.transaction_ops
    for all using (user_id = auth.uid()) with check (user_id = auth.uid());

create or replace function public.apply_transaction_op(
    p_op_id uuid,
    p_action text,               -- 'insert' | 'update' | 'delete'
    p_tx_id text,                -- id of the transaction for update/delete
    p_tx jsonb,                  -- transaction fields for insert/update
    p_balance_deltas jsonb,      -- { "<account id>": delta, ... }
    p_goal_deltas jsonb          -- { "<savings goal id>": delta, ... }
) returns text
language plpgsql
security invoker
as $$
declare
    r public.transactions;
    k text;
    v numeric;
begin
    insert into public.transaction_ops (op_id) values (p_op_id) on conflict (op_id) do nothing;
    if not found then
        return 'duplicate';
    end if;

    r := jsonb_populate_record(null::public.transactions, coalesce(p_tx, '{}'::jsonb));

    if p_action = 'insert' then
        insert into public.transactions (user_id, transaction_date, transaction_type, amount, wallet_id, to_wallet_id,
            category_id, transaction_note, is_installment, installment_total_months, installment_current_month)
        values (auth.uid(), r.transaction_date, r.transaction_type, r.amount, r.wallet_id, r.to_wallet_id,
            r.category_id, r.transaction_note, r.is_installment, r.installment_total_months, r.installment_current_month);
    elsif p_action = 'update' then
        update public.transactions set
            transaction_date = r.transaction_date,
            transaction_type = r.transaction_type,
            amount = r.amount,
            wallet_id = r.wallet_id,
            to_wallet_id = r.to_wallet_id,
            category_id = r.category_id,
            transaction_note = r.transaction_note,
            is_installment = r.is_installment,
            installment_total_months = r.installment_total_months,
            installment_current_month = r.installment_current_month
        where id::text = p_tx_id and user_id = auth.uid();
        if not found then raise exception 'ไม่พบรายการที่ต้องการแก้ไข'; end if;
    elsif p_action = 'delete' then
        delete from public.transactions where id::text = p_tx_id and user_id = auth.uid();
        if not found then raise exception 'ไม่พบรายการที่ต้องการลบ'; end if;
    else
        raise exception 'unknown action %', p_action;
    end if;

    -- Balances change relative to what is in the database now, never from a stale copy in the browser.
    for k, v in select key, value::numeric from jsonb_each_text(coalesce(p_balance_deltas, '{}'::jsonb)) loop
        update public.accounts set balance = round(balance + v, 2)
        where id::text = k and user_id = auth.uid();
        if not found then raise exception 'ไม่พบบัญชี %', k; end if;
    end loop;

    for k, v in select key, value::numeric from jsonb_each_text(coalesce(p_goal_deltas, '{}'::jsonb)) loop
        update public.savings_goals set current_amount = round(coalesce(current_amount, 0) + v, 2)
        where id::text = k and user_id = auth.uid();
        if not found then raise exception 'ไม่พบเป้าหมายเงินออม %', k; end if;
    end loop;

    return 'ok';
end;
$$;
