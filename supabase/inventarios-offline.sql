create table public.gujar_inventarios_offline(
 movimiento_id uuid primary key, usuario_auth_id uuid not null default auth.uid(),
 finca text not null, fecha date not null, prueba boolean not null,
 base_ids bigint[] not null, contados_ids bigint[] not null, observaciones text,
 capturado_en timestamptz not null, cerrado_en timestamptz not null,
 sincronizado_en timestamptz not null default now(),
 grupo_id bigint unique references public.gujar_grupos(id),
 check(contados_ids <@ base_ids),
 check((prueba and grupo_id is null) or not prueba)
);
alter table public.gujar_inventarios_offline enable row level security;
revoke all on public.gujar_inventarios_offline from anon,authenticated;
grant select,insert on public.gujar_inventarios_offline to authenticated;
create policy inventarios_select on public.gujar_inventarios_offline for select to authenticated using
(public.gujar_puede_ver_finca(finca) and (not prueba or usuario_auth_id=(select auth.uid())));
create policy inventarios_insert on public.gujar_inventarios_offline for insert to authenticated with check
(usuario_auth_id=(select auth.uid()) and public.gujar_puede_crear() and public.gujar_puede_ver_finca(finca));
create function public.gujar_sincronizar_inventario(
 p_movimiento_id uuid,p_finca text,p_fecha date,p_prueba boolean,p_base_ids bigint[],p_contados_ids bigint[],
 p_observaciones text,p_capturado_en timestamptz,p_cerrado_en timestamptz)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare r public.gujar_inventarios_offline; b bigint[]; c bigint[]; gid bigint;
begin
 if auth.uid() is null or not public.gujar_puede_crear() or not public.gujar_puede_ver_finca(p_finca) then raise exception 'No autorizado' using errcode='42501'; end if;
 if p_movimiento_id is null or p_fecha is null or p_prueba is null or p_base_ids is null or p_contados_ids is null or p_capturado_en is null or p_cerrado_en is null or p_cerrado_en<p_capturado_en then raise exception 'Inventario incompleto'; end if;
 if cardinality(p_base_ids)>10000 or cardinality(p_contados_ids)>10000 or array_position(p_base_ids,null) is not null or array_position(p_contados_ids,null) is not null then raise exception 'Listado de animales inválido'; end if;
 select coalesce(array_agg(distinct x order by x),'{}'::bigint[]) into b from unnest(p_base_ids) x;
 select coalesce(array_agg(distinct x order by x),'{}'::bigint[]) into c from unnest(p_contados_ids) x;
 if cardinality(b)<>cardinality(p_base_ids) or cardinality(c)<>cardinality(p_contados_ids) or not(c <@ b) then raise exception 'Hay animales repetidos o fuera del inventario inicial'; end if;
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(p_movimiento_id::text,17));
 select * into r from public.gujar_inventarios_offline where movimiento_id=p_movimiento_id;
 if r.movimiento_id is not null then
 if r.usuario_auth_id is distinct from auth.uid() or r.finca is distinct from p_finca or r.fecha is distinct from p_fecha or r.prueba is distinct from p_prueba
 or r.base_ids is distinct from b or r.contados_ids is distinct from c or r.observaciones is distinct from p_observaciones
 or r.capturado_en is distinct from p_capturado_en or r.cerrado_en is distinct from p_cerrado_en then raise exception 'Identificador usado por otro inventario'; end if;
 else
 if exists(select 1 from unnest(b) as baseline(animal_id) where not exists(select 1 from public.gujar_animales a where a.id=baseline.animal_id and a.finca=p_finca and a.estado='Activo')) then
 raise exception 'Cambió la finca o el estado de un animal del inventario inicial. El conteo permanece pendiente para revisión.'; end if;
 if not p_prueba then
 insert into public.gujar_grupos(tipo,fecha,finca,titulo,origen,origen_sesion_id,cantidad_animales,observaciones)
 values('Inventario',p_fecha,p_finca,'Inventario físico','GUJAR Offline',p_movimiento_id::text,cardinality(c),
 'Activos al iniciar: '||cardinality(b)||' · Contados: '||cardinality(c)||' · No encontrados: '||(cardinality(b)-cardinality(c))) returning id into gid;
 insert into public.gujar_eventos(animal_id,tipo,fecha,finca,observaciones,grupo_id)
 select id,'Inventario',p_fecha,p_finca,coalesce(p_observaciones,'Conteo físico'),gid from unnest(c) id;
 end if;
 insert into public.gujar_inventarios_offline(movimiento_id,finca,fecha,prueba,base_ids,contados_ids,observaciones,capturado_en,cerrado_en,grupo_id)
 values(p_movimiento_id,p_finca,p_fecha,p_prueba,b,c,p_observaciones,p_capturado_en,p_cerrado_en,gid) returning * into r;
 end if;
 return jsonb_build_object('ok',true,'movimiento_id',r.movimiento_id,'prueba',r.prueba,'inventario',to_jsonb(r),
 'grupo',(select to_jsonb(g) from public.gujar_grupos g where g.id=r.grupo_id),
 'eventos',coalesce((select jsonb_agg(to_jsonb(e)) from public.gujar_eventos e where e.grupo_id=r.grupo_id),'[]'::jsonb));
end $$;
revoke all on function public.gujar_sincronizar_inventario(uuid,text,date,boolean,bigint[],bigint[],text,timestamptz,timestamptz) from public,anon;
grant execute on function public.gujar_sincronizar_inventario(uuid,text,date,boolean,bigint[],bigint[],text,timestamptz,timestamptz) to authenticated;