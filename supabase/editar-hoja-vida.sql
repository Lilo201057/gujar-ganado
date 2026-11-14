create or replace function public.gujar_proteger_edicion_hoja_vida()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  if row(new.sexo,new.color,new.senas,new.observaciones,new.raza)
     is distinct from row(old.sexo,old.color,old.senas,old.observaciones,old.raza)
     and current_user in ('authenticated','anon')
     and (public.gujar_mi_usuario()).rol is distinct from 'Administrador' then
    raise exception 'Solo un administrador puede editar los datos de la hoja de vida.' using errcode='42501';
  end if;
  return new;
end;
$$;
create trigger gujar_proteger_edicion_hoja_vida
before update on public.gujar_animales
for each row execute function public.gujar_proteger_edicion_hoja_vida();
