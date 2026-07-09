
create or replace function public.prevent_role_self_escalation()
returns trigger
language plpgsql
as $$
begin
  if new.role <> old.role
     and not public.is_admin()
     and not (
       auth.uid() is null
       and not exists (select 1 from public.users where role = 'admin')
     )
  then
    raise exception 'Only an admin can change a user role.';
  end if;

  return new;
end;
$$;

