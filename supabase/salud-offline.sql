alter table public.gujar_eventos add column movimiento_id uuid, add column usuario_auth_id uuid, add column capturado_en timestamptz;
create unique index gujar_eventos_movimiento_unique on public.gujar_eventos(movimiento_id);
create policy gujar_eventos_offline_owner on public.gujar_eventos as restrictive for insert to authenticated with check
 (movimiento_id is null or (usuario_auth_id=(select auth.uid()) and tipo in ('Vacunación','Tratamiento') and capturado_en is not null));
create table public.gujar_salud_offline_prueba(
 id bigint generated always as identity primary key, movimiento_id uuid not null unique,
 usuario_auth_id uuid not null default auth.uid(), animal_id bigint not null references public.gujar_animales(id),
 tipo text not null check(tipo in ('Vacunación','Tratamiento')), fecha date not null, finca text not null,
 producto text not null check(length(btrim(producto))>0), dosis text not null check(length(btrim(dosis))>0),
 via text, observaciones text, capturado_en timestamptz not null, creado_en timestamptz not null default now()
);
alter table public.gujar_salud_offline_prueba enable row level security;
revoke all on public.gujar_salud_offline_prueba from anon,authenticated;
grant select,insert on public.gujar_salud_offline_prueba to authenticated;
grant usage on sequence public.gujar_salud_offline_prueba_id_seq to authenticated;
create policy salud_prueba_select on public.gujar_salud_offline_prueba for select to authenticated
 using(usuario_auth_id=(select auth.uid()) and public.gujar_puede_ver_finca(finca));
create policy salud_prueba_insert on public.gujar_salud_offline_prueba for insert to authenticated
 with check(usuario_auth_id=(select auth.uid()) and public.gujar_puede_crear() and public.gujar_puede_ver_finca(finca)
 and exists(select 1 from public.gujar_animales a where a.id=gujar_salud_offline_prueba.animal_id and a.finca=gujar_salud_offline_prueba.finca and a.estado='Activo'));
create function public.gujar_sincronizar_salud(p_movimiento_id uuid,p_animal_id bigint,p_finca text,p_tipo text,p_fecha date,p_producto text,p_dosis text,p_via text,p_observaciones text,p_capturado_en timestamptz,p_prueba boolean)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare v jsonb; a public.gujar_animales; duplicado boolean;
begin
 if auth.uid() is null or not public.gujar_puede_crear() or not public.gujar_puede_ver_finca(p_finca) then raise exception 'No autorizado' using errcode='42501'; end if;
 if p_movimiento_id is null or p_fecha is null or p_capturado_en is null or p_prueba is null or p_tipo is null or p_tipo not in ('Vacunación','Tratamiento')
 or nullif(btrim(p_producto),'') is null or nullif(btrim(p_dosis),'') is null then raise exception 'Complete fecha, producto y dosis'; end if;
 perform pg_catalog.pg_advisory_xact_lock(p_animal_id);
 if p_prueba then select to_jsonb(e) into v from public.gujar_salud_offline_prueba e where movimiento_id=p_movimiento_id;
 else select to_jsonb(e) into v from public.gujar_eventos e where movimiento_id=p_movimiento_id; end if;
 if v is not null then
 if (v->>'usuario_auth_id')::uuid is distinct from auth.uid() or (v->>'animal_id')::bigint is distinct from p_animal_id
 or v->>'finca' is distinct from p_finca or v->>'tipo' is distinct from p_tipo or (v->>'fecha')::date is distinct from p_fecha
 or v->>'producto' is distinct from btrim(p_producto) or v->>'dosis' is distinct from btrim(p_dosis)
 or v->>'via' is distinct from p_via or v->>'observaciones' is distinct from p_observaciones
 or (v->>'capturado_en')::timestamptz is distinct from p_capturado_en then raise exception 'Identificador usado por otro movimiento'; end if;
 else
 select * into a from public.gujar_animales where id=p_animal_id;
 if a.id is null or a.estado<>'Activo' or a.finca is distinct from p_finca then raise exception 'El animal no está activo en la finca de captura. Revise el pendiente.'; end if;
 if p_prueba then select exists(select 1 from public.gujar_salud_offline_prueba e where e.usuario_auth_id=auth.uid() and e.animal_id=p_animal_id and e.tipo=p_tipo and e.fecha=p_fecha and lower(btrim(e.producto))=lower(btrim(p_producto)) and lower(btrim(e.dosis))=lower(btrim(p_dosis)) and e.via is not distinct from p_via) into duplicado;
 else select exists(select 1 from public.gujar_eventos e where e.animal_id=p_animal_id and e.tipo=p_tipo and e.fecha=p_fecha and lower(btrim(e.producto))=lower(btrim(p_producto)) and lower(btrim(e.dosis))=lower(btrim(p_dosis)) and e.via is not distinct from p_via) into duplicado; end if;
 if duplicado then raise exception 'Ya existe esta aplicación para el animal, fecha, producto y dosis. Revise el pendiente.'; end if;
 if p_prueba then
 insert into public.gujar_salud_offline_prueba(movimiento_id,animal_id,tipo,fecha,finca,producto,dosis,via,observaciones,capturado_en)
 values(p_movimiento_id,p_animal_id,p_tipo,p_fecha,p_finca,btrim(p_producto),btrim(p_dosis),p_via,p_observaciones,p_capturado_en) returning to_jsonb(gujar_salud_offline_prueba.*) into v;
 else
 insert into public.gujar_eventos(movimiento_id,usuario_auth_id,animal_id,tipo,fecha,finca,producto,dosis,via,observaciones,capturado_en)
 values(p_movimiento_id,auth.uid(),p_animal_id,p_tipo,p_fecha,p_finca,btrim(p_producto),btrim(p_dosis),p_via,p_observaciones,p_capturado_en) returning to_jsonb(gujar_eventos.*) into v;
 end if;
 end if;
 return jsonb_build_object('ok',true,'movimiento_id',v->>'movimiento_id','prueba',p_prueba,'evento',v,'sincronizado_en',v->>'creado_en');
end $$;
revoke all on function public.gujar_sincronizar_salud(uuid,bigint,text,text,date,text,text,text,text,timestamptz,boolean) from public,anon;
grant execute on function public.gujar_sincronizar_salud(uuid,bigint,text,text,date,text,text,text,text,timestamptz,boolean) to authenticated;