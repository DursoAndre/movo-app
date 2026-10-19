-- Catálogo de exercícios no banco (v162). Seguro rodar de novo.
create or replace function public.cat_norm(t text) returns text language sql immutable as $$
  select trim(regexp_replace(translate(lower(coalesce(t,'')),'áàâãäéèêëíìîïóòôõöúùûüç','aaaaaeeeeiiiiooooouuuuc'),'\s+',' ','g'))
$$;

create or replace function public.is_movo_admin() returns boolean language sql stable security definer set search_path=public as $$
  select public.movo_admin_uid(auth.uid()) -- quem é admin: admin_identidade.sql
$$;

create table if not exists public.catalogo_grupos (
  key text primary key, label text not null, kind text not null default 'muscular' check (kind in ('muscular','outro')),
  ordem int not null default 0, updated_at timestamptz not null default now());
create table if not exists public.catalogo_exercicios (
  id text primary key, nome text not null, grupo_key text not null references public.catalogo_grupos(key),
  series int, repeticoes text, descricao text not null default '', observacoes text not null default '', video_url text not null default '',
  ordem int not null default 0, ativo boolean not null default true,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now());
create table if not exists public.catalogo_sinonimos (
  id serial primary key, termos text[] not null, updated_at timestamptz not null default now());
create table if not exists public.catalogo_aliases (
  alias_norm text primary key, alias_nome text not null, exercicio_id text not null references public.catalogo_exercicios(id) on delete cascade,
  created_at timestamptz not null default now());
create table if not exists public.exercise_review (
  id bigserial primary key, nome_norm text not null, nome text not null, qtd int not null default 1, usuarios int not null default 1,
  status text not null default 'pendente' check (status in ('pendente','aprovado','reprovado')),
  acao text check (acao in ('alias','novo','ignorar')), proposta jsonb not null default '{}'::jsonb, motivo_ia text,
  comentario_admin text, qtd_na_decisao int, created_at timestamptz not null default now(), decidido_em timestamptz);
create unique index if not exists exercise_review_nome_pend on public.exercise_review(nome_norm) where status='pendente';
create index if not exists exercise_review_nome on public.exercise_review(nome_norm);

alter table public.catalogo_grupos enable row level security;
alter table public.catalogo_exercicios enable row level security;
alter table public.catalogo_sinonimos enable row level security;
alter table public.catalogo_aliases enable row level security;
alter table public.exercise_review enable row level security;
drop policy if exists cat_grupos_read on public.catalogo_grupos; create policy cat_grupos_read on public.catalogo_grupos for select to anon, authenticated using (true);
drop policy if exists cat_ex_read on public.catalogo_exercicios; create policy cat_ex_read on public.catalogo_exercicios for select to anon, authenticated using (ativo);
drop policy if exists cat_sin_read on public.catalogo_sinonimos; create policy cat_sin_read on public.catalogo_sinonimos for select to anon, authenticated using (true);
drop policy if exists cat_ali_read on public.catalogo_aliases; create policy cat_ali_read on public.catalogo_aliases for select to anon, authenticated using (true);
-- exercise_review: sem policy (só via RPC admin / service role)

create or replace function public.catalogo_versao() returns text language sql stable security definer set search_path=public as $$
  select md5(concat_ws('|',
    (select count(*)||coalesce(max(updated_at)::text,'') from catalogo_exercicios),
    (select count(*)||coalesce(max(updated_at)::text,'') from catalogo_grupos),
    (select count(*)||coalesce(max(updated_at)::text,'') from catalogo_sinonimos),
    (select count(*)||coalesce(max(created_at)::text,'') from catalogo_aliases)))
$$;

create or replace function public.catalogo_completo() returns jsonb language sql stable security definer set search_path=public as $$
  select jsonb_build_object(
    'versao', public.catalogo_versao(),
    'grupos', coalesce((select jsonb_agg(jsonb_build_object('key',key,'label',label,'kind',kind) order by ordem) from catalogo_grupos),'[]'::jsonb),
    'exercicios', coalesce((select jsonb_agg(jsonb_build_object('id',id,'nome',nome,'grupo_key',grupo_key,'series',series,'repeticoes',repeticoes,'descricao',descricao,'observacoes',observacoes,'video_url',video_url) order by ordem, nome) from catalogo_exercicios where ativo),'[]'::jsonb),
    'sinonimos', coalesce((select jsonb_agg(termos order by id) from catalogo_sinonimos),'[]'::jsonb),
    'aliases', coalesce((select jsonb_agg(jsonb_build_object('alias',alias_nome,'norm',alias_norm,'id',exercicio_id)) from catalogo_aliases),'[]'::jsonb))
$$;
grant execute on function public.catalogo_versao() to anon, authenticated;
grant execute on function public.catalogo_completo() to anon, authenticated;
revoke all on function public.is_movo_admin() from public, anon;
grant execute on function public.is_movo_admin() to authenticated;

insert into public.catalogo_grupos(key,label,kind,ordem)
select key,label,kind,ordem from jsonb_to_recordset($j$[{"key":"peito","label":"Peito","kind":"muscular","ordem":1},{"key":"costas","label":"Costas","kind":"muscular","ordem":2},{"key":"ombro","label":"Ombro","kind":"muscular","ordem":3},{"key":"biceps","label":"Bíceps","kind":"muscular","ordem":4},{"key":"triceps","label":"Tríceps","kind":"muscular","ordem":5},{"key":"quad","label":"Quadríceps","kind":"muscular","ordem":6},{"key":"posterior","label":"Posterior de coxa","kind":"muscular","ordem":7},{"key":"gluteoPant","label":"Glúteo & Panturrilha","kind":"muscular","ordem":8},{"key":"abdomen","label":"Abdômen","kind":"muscular","ordem":9},{"key":"cardio","label":"Cardio","kind":"outro","ordem":10},{"key":"mobilidade","label":"Mobilidade","kind":"outro","ordem":11}]$j$::jsonb) as t(key text,label text,kind text,ordem int)
on conflict (key) do nothing;

insert into public.catalogo_exercicios(id,nome,grupo_key,series,repeticoes,video_url,ordem)
select id,nome,grupo_key,series,repeticoes,video_url,ordem from jsonb_to_recordset($j$[{"id":"supino-reto-com-halteres","nome":"Supino reto com halteres","grupo_key":"peito","series":4,"repeticoes":"10-12","video_url":"https://www.youtube.com/watch?v=Cjh2fIMQHk0","ordem":1},{"id":"supino-inclinado-com-halteres","nome":"Supino inclinado com halteres","grupo_key":"peito","series":3,"repeticoes":"10-12","video_url":"https://www.youtube.com/watch?v=ZaNyRjpoki8","ordem":2},{"id":"crucifixo-no-cross-over","nome":"Crucifixo no cross-over","grupo_key":"peito","series":3,"repeticoes":"12-15","video_url":"https://www.youtube.com/watch?v=_hdQD_E3deE","ordem":3},{"id":"supino-reto-com-barra","nome":"Supino reto com barra","grupo_key":"peito","series":4,"repeticoes":"8-10","video_url":"https://www.youtube.com/watch?v=UHa9U-O09_U","ordem":4},{"id":"supino-declinado-com-halteres","nome":"Supino declinado com halteres","grupo_key":"peito","series":3,"repeticoes":"10-12","video_url":"https://www.youtube.com/watch?v=Pf1nDoqx_1A","ordem":5},{"id":"flexao-de-braco","nome":"Flexão de braço","grupo_key":"peito","series":3,"repeticoes":"Até a falha","video_url":"https://www.youtube.com/watch?v=0pkjOk0EiAk","ordem":6},{"id":"peck-deck-voador","nome":"Peck deck (voador)","grupo_key":"peito","series":3,"repeticoes":"12-15","video_url":"https://www.youtube.com/watch?v=fgXSA2-o0NM","ordem":7},{"id":"puxada-frente-na-polia","nome":"Puxada frente na polia","grupo_key":"costas","series":4,"repeticoes":"10-12","video_url":"https://www.youtube.com/watch?v=oF-RqXrkZHU","ordem":8},{"id":"remada-baixa-na-polia","nome":"Remada baixa na polia","grupo_key":"costas","series":3,"repeticoes":"10-12","video_url":"https://www.youtube.com/watch?v=6ml0iz19DPw","ordem":9},{"id":"remada-curvada-com-barra-ou-halteres","nome":"Remada curvada com barra ou halteres","grupo_key":"costas","series":3,"repeticoes":"10-12","video_url":"https://www.youtube.com/watch?v=e53vSzibkO0","ordem":10},{"id":"barra-fixa-pull-up","nome":"Barra fixa (pull-up)","grupo_key":"costas","series":3,"repeticoes":"Até a falha","video_url":"https://www.youtube.com/watch?v=hxIF6qwBr2M","ordem":11},{"id":"remada-unilateral-com-halteres","nome":"Remada unilateral com halteres","grupo_key":"costas","series":3,"repeticoes":"10-12","video_url":"https://www.youtube.com/watch?v=dFzUjzfih7k","ordem":12},{"id":"puxada-com-pegada-supinada","nome":"Puxada com pegada supinada","grupo_key":"costas","series":3,"repeticoes":"10-12","video_url":"https://www.youtube.com/watch?v=ZWlG30BZfEo","ordem":13},{"id":"remada-cavalinho-t-bar","nome":"Remada cavalinho (T-bar)","grupo_key":"costas","series":3,"repeticoes":"10-12","video_url":"https://www.youtube.com/watch?v=8pR3JoZ0iBU","ordem":14},{"id":"hiperextensao-lombar","nome":"Hiperextensão lombar","grupo_key":"costas","series":3,"repeticoes":"12-15","video_url":"https://www.youtube.com/watch?v=ivDB23Kcv-A","ordem":15},{"id":"retracao-escapular-remada-isometrica","nome":"Retração escapular (remada isométrica)","grupo_key":"costas","series":3,"repeticoes":"12-15","video_url":"https://www.youtube.com/watch?v=kJm_DqqRoL0","ordem":16},{"id":"desenvolvimento-com-halteres","nome":"Desenvolvimento com halteres","grupo_key":"ombro","series":3,"repeticoes":"10-12","video_url":"https://www.youtube.com/watch?v=DFXtzdXN_iY","ordem":17},{"id":"elevacao-lateral-com-halteres","nome":"Elevação lateral com halteres","grupo_key":"ombro","series":3,"repeticoes":"12-15","video_url":"https://www.youtube.com/watch?v=ot9nwSC1JnA","ordem":18},{"id":"elevacao-frontal-com-halteres","nome":"Elevação frontal com halteres","grupo_key":"ombro","series":3,"repeticoes":"12-15","video_url":"https://www.youtube.com/watch?v=GqZRmCow0rw","ordem":19},{"id":"desenvolvimento-militar-com-barra","nome":"Desenvolvimento militar com barra","grupo_key":"ombro","series":3,"repeticoes":"8-10","video_url":"https://www.youtube.com/watch?v=Y5xpE2K660s","ordem":20},{"id":"remada-alta","nome":"Remada alta","grupo_key":"ombro","series":3,"repeticoes":"10-12","video_url":"https://www.youtube.com/watch?v=U-KG4oahSLA","ordem":21},{"id":"face-pull-na-polia","nome":"Face pull na polia","grupo_key":"ombro","series":3,"repeticoes":"12-15","video_url":"https://www.youtube.com/watch?v=0Po47vvj9g4","ordem":22},{"id":"rotacao-externa-de-ombro-com-faixa-elastica","nome":"Rotação externa de ombro com faixa elástica","grupo_key":"ombro","series":3,"repeticoes":"15-20","video_url":"https://www.youtube.com/watch?v=IVR_xKHr7so","ordem":23},{"id":"elevacao-lateral-de-ombro-com-faixa-elastica","nome":"Elevação lateral de ombro com faixa elástica","grupo_key":"ombro","series":3,"repeticoes":"15","video_url":"https://www.youtube.com/watch?v=54H6OG-99EQ","ordem":24},{"id":"wall-slide-deslize-na-parede","nome":"Wall slide (deslize na parede)","grupo_key":"ombro","series":3,"repeticoes":"10-12","video_url":"https://www.youtube.com/watch?v=i_0zLUcE-zk","ordem":25},{"id":"rosca-direta-com-barra-ou-halteres","nome":"Rosca direta com barra ou halteres","grupo_key":"biceps","series":3,"repeticoes":"10-12","video_url":"https://www.youtube.com/watch?v=dc330H9yN3Y","ordem":26},{"id":"rosca-alternada-com-halteres","nome":"Rosca alternada com halteres","grupo_key":"biceps","series":3,"repeticoes":"10-12","video_url":"https://www.youtube.com/watch?v=LpM7dGNzMTo","ordem":27},{"id":"rosca-martelo","nome":"Rosca martelo","grupo_key":"biceps","series":3,"repeticoes":"10-12","video_url":"https://www.youtube.com/watch?v=vm0zV_WQerE","ordem":28},{"id":"rosca-scott-concentrada","nome":"Rosca Scott (concentrada)","grupo_key":"biceps","series":3,"repeticoes":"10-12","video_url":"https://www.youtube.com/watch?v=7ixqAPO6JvU","ordem":29},{"id":"triceps-na-polia-corda","nome":"Tríceps na polia (corda)","grupo_key":"triceps","series":3,"repeticoes":"12-15","video_url":"https://www.youtube.com/watch?v=-QGC1cL6ETE","ordem":30},{"id":"triceps-testa-com-barra-ou-halteres","nome":"Tríceps testa (com barra ou halteres)","grupo_key":"triceps","series":3,"repeticoes":"10-12","video_url":"https://www.youtube.com/watch?v=cIqScmVpqnc","ordem":31},{"id":"triceps-frances","nome":"Tríceps francês","grupo_key":"triceps","series":3,"repeticoes":"10-12","video_url":"https://www.youtube.com/watch?v=b_r_LW4HEcM","ordem":32},{"id":"mergulho-no-banco-dips","nome":"Mergulho no banco (dips)","grupo_key":"triceps","series":3,"repeticoes":"Até a falha","video_url":"https://www.youtube.com/watch?v=0326dy_-CzM","ordem":33},{"id":"agachamento-livre-ou-na-maquina","nome":"Agachamento livre ou na máquina","grupo_key":"quad","series":4,"repeticoes":"10-12","video_url":"https://www.youtube.com/watch?v=iGLzCCZr_Xw","ordem":34},{"id":"leg-press-45","nome":"Leg press 45°","grupo_key":"quad","series":3,"repeticoes":"10-12","video_url":"https://www.youtube.com/watch?v=DQ4-HXFlKXI","ordem":35},{"id":"cadeira-extensora","nome":"Cadeira extensora","grupo_key":"quad","series":3,"repeticoes":"12-15","video_url":"https://www.youtube.com/watch?v=u68RNdfZymA","ordem":36},{"id":"afundo-avanco-com-halteres","nome":"Afundo (avanço) com halteres","grupo_key":"quad","series":3,"repeticoes":"10-12 cada perna","video_url":"https://www.youtube.com/watch?v=rltJymhFtHg","ordem":37},{"id":"agachamento-bulgaro","nome":"Agachamento búlgaro","grupo_key":"quad","series":3,"repeticoes":"8-10 cada perna","video_url":"https://www.youtube.com/watch?v=Fmjj7wFJWRE","ordem":38},{"id":"agachamento-sumo","nome":"Agachamento sumô","grupo_key":"quad","series":3,"repeticoes":"10-12","video_url":"https://www.youtube.com/watch?v=vBA3vyOxJv0","ordem":39},{"id":"leg-press-unilateral","nome":"Leg press unilateral","grupo_key":"quad","series":3,"repeticoes":"10-12 cada perna","video_url":"https://www.youtube.com/watch?v=LbKwZIbVYZI","ordem":40},{"id":"extensao-de-joelho-sentado-isometria","nome":"Extensão de joelho sentado (isometria)","grupo_key":"quad","series":3,"repeticoes":"12-15 cada perna","video_url":"https://www.youtube.com/watch?v=Pv5L4V5EezM","ordem":41},{"id":"terminal-knee-extension-com-faixa","nome":"Terminal knee extension com faixa","grupo_key":"quad","series":3,"repeticoes":"15 cada perna","video_url":"https://www.youtube.com/watch?v=3d4pIE9iG04","ordem":42},{"id":"mesa-flexora","nome":"Mesa flexora","grupo_key":"posterior","series":3,"repeticoes":"12-15","video_url":"https://www.youtube.com/watch?v=IXg1PQ_5gmw","ordem":43},{"id":"stiff-com-halteres-ou-barra","nome":"Stiff com halteres ou barra","grupo_key":"posterior","series":3,"repeticoes":"10-12","video_url":"https://youtu.be/NP548KPEpMw","ordem":44},{"id":"elevacao-pelvica-hip-thrust","nome":"Elevação pélvica (hip thrust)","grupo_key":"posterior","series":3,"repeticoes":"10-12","video_url":"https://www.youtube.com/watch?v=pUdIL5x0fWg","ordem":45},{"id":"good-morning","nome":"Good morning","grupo_key":"posterior","series":3,"repeticoes":"10-12","video_url":"https://www.youtube.com/watch?v=YA-h3n9L4YU","ordem":46},{"id":"mesa-flexora-unilateral","nome":"Mesa flexora unilateral","grupo_key":"posterior","series":3,"repeticoes":"10-12 cada perna","video_url":"https://www.youtube.com/watch?v=Y1dQUd6OKHk","ordem":47},{"id":"cadeira-flexora-flexora-sentada","nome":"Cadeira flexora (flexora sentada)","grupo_key":"posterior","series":3,"repeticoes":"12-15","video_url":"","ordem":48},{"id":"cadeira-adutora","nome":"Cadeira adutora","grupo_key":"gluteoPant","series":2,"repeticoes":"15-20","video_url":"https://www.youtube.com/watch?v=XbhmXUYp8hs","ordem":49},{"id":"cadeira-abdutora","nome":"Cadeira abdutora","grupo_key":"gluteoPant","series":2,"repeticoes":"15-20","video_url":"https://www.youtube.com/watch?v=nabhYLtz8Gg","ordem":50},{"id":"panturrilha-em-pe","nome":"Panturrilha em pé","grupo_key":"gluteoPant","series":3,"repeticoes":"15-20","video_url":"https://www.youtube.com/watch?v=EILF4iyBxSQ","ordem":51},{"id":"gluteo-na-polia-coice","nome":"Glúteo na polia (coice)","grupo_key":"gluteoPant","series":3,"repeticoes":"12-15 cada perna","video_url":"https://www.youtube.com/watch?v=SqO-VUEak2M","ordem":52},{"id":"step-up","nome":"Step up","grupo_key":"gluteoPant","series":3,"repeticoes":"10-12 cada perna","video_url":"https://www.youtube.com/watch?v=5qjqDHOUh-A","ordem":53},{"id":"panturrilha-sentado","nome":"Panturrilha sentado","grupo_key":"gluteoPant","series":3,"repeticoes":"15-20","video_url":"https://www.youtube.com/watch?v=ar8nav0jGoE","ordem":54},{"id":"ponte-de-gluteo-glute-bridge","nome":"Ponte de glúteo (glute bridge)","grupo_key":"gluteoPant","series":3,"repeticoes":"15","video_url":"https://www.youtube.com/watch?v=1satDE63Bwc","ordem":55},{"id":"clamshell-concha-com-mini-band","nome":"Clamshell (concha) com mini band","grupo_key":"gluteoPant","series":3,"repeticoes":"15 cada lado","video_url":"https://www.youtube.com/watch?v=XgKzdYhJp1w","ordem":56},{"id":"prancha","nome":"Prancha","grupo_key":"abdomen","series":3,"repeticoes":"30-45s","video_url":"https://www.youtube.com/watch?v=ffHr8a6DRvU","ordem":57},{"id":"abdominal-na-polia-ou-maquina","nome":"Abdominal na polia ou máquina","grupo_key":"abdomen","series":3,"repeticoes":"15-20","video_url":"https://www.youtube.com/watch?v=zp6uK1aE1Lc","ordem":58},{"id":"abdominal-supra-crunch","nome":"Abdominal supra (crunch)","grupo_key":"abdomen","series":3,"repeticoes":"15-20","video_url":"https://www.youtube.com/watch?v=MKq4WH-eBAQ","ordem":59},{"id":"elevacao-de-pernas","nome":"Elevação de pernas","grupo_key":"abdomen","series":3,"repeticoes":"12-15","video_url":"https://www.youtube.com/watch?v=PBTChAcDnZ4","ordem":60},{"id":"prancha-lateral","nome":"Prancha lateral","grupo_key":"abdomen","series":3,"repeticoes":"20-30s cada lado","video_url":"https://www.youtube.com/watch?v=x2gzR9zzSCw","ordem":61},{"id":"abdominal-bicicleta","nome":"Abdominal bicicleta","grupo_key":"abdomen","series":3,"repeticoes":"15-20","video_url":"https://www.youtube.com/watch?v=OnQNhK0Ekgk","ordem":62},{"id":"esteira-caminhada-corrida","nome":"Esteira (caminhada/corrida)","grupo_key":"cardio","series":1,"repeticoes":"15-20 min","video_url":"https://www.youtube.com/watch?v=gC-eX9k2DIw","ordem":63},{"id":"bicicleta-ergometrica","nome":"Bicicleta ergométrica","grupo_key":"cardio","series":1,"repeticoes":"15-20 min","video_url":"https://www.youtube.com/watch?v=TY0f2mgR3GI","ordem":64},{"id":"eliptico","nome":"Elíptico","grupo_key":"cardio","series":1,"repeticoes":"15-20 min","video_url":"https://www.youtube.com/watch?v=Lf2u8UMvI68","ordem":65},{"id":"pular-corda","nome":"Pular corda","grupo_key":"cardio","series":3,"repeticoes":"1-2 min","video_url":"https://www.youtube.com/watch?v=_7cpagB7WUg","ordem":66},{"id":"remo-ergometro","nome":"Remo ergômetro","grupo_key":"cardio","series":1,"repeticoes":"10-15 min","video_url":"https://www.youtube.com/watch?v=A-35F9TR0OA","ordem":67},{"id":"hiit-em-circuito","nome":"HIIT em circuito","grupo_key":"cardio","series":4,"repeticoes":"30s forte / 30s leve","video_url":"https://www.youtube.com/watch?v=9v1hhlsGnJ4","ordem":68},{"id":"alongamento-de-posterior-de-coxa","nome":"Alongamento de posterior de coxa","grupo_key":"mobilidade","series":2,"repeticoes":"30s cada lado","video_url":"https://www.youtube.com/watch?v=GHb1xKvO3NY","ordem":69},{"id":"alongamento-de-peitoral","nome":"Alongamento de peitoral","grupo_key":"mobilidade","series":2,"repeticoes":"30s cada lado","video_url":"https://www.youtube.com/watch?v=u7AFpzWV2I8","ordem":70},{"id":"mobilidade-de-quadril-90-90","nome":"Mobilidade de quadril (90/90)","grupo_key":"mobilidade","series":2,"repeticoes":"8-10 cada lado","video_url":"https://www.youtube.com/watch?v=FM7-7-a0FLg","ordem":71},{"id":"gato-camelo-mobilidade-de-coluna","nome":"Gato-camelo (mobilidade de coluna)","grupo_key":"mobilidade","series":2,"repeticoes":"10-12","video_url":"https://www.youtube.com/watch?v=2of247Kt0tU","ordem":72},{"id":"alongamento-de-panturrilha","nome":"Alongamento de panturrilha","grupo_key":"mobilidade","series":2,"repeticoes":"30s cada lado","video_url":"https://www.youtube.com/watch?v=7SO6QzfBRaE","ordem":73},{"id":"rotacao-de-ombro-com-bastao","nome":"Rotação de ombro com bastão","grupo_key":"mobilidade","series":2,"repeticoes":"10-12","video_url":"https://www.youtube.com/watch?v=YW20zO__f_c","ordem":74},{"id":"mobilidade-de-tornozelo-dorsiflexao-na-parede","nome":"Mobilidade de tornozelo (dorsiflexão na parede)","grupo_key":"mobilidade","series":3,"repeticoes":"10 cada lado","video_url":"https://www.youtube.com/watch?v=_3dMj5JYqQw","ordem":75}]$j$::jsonb) as t(id text,nome text,grupo_key text,series int,repeticoes text,video_url text,ordem int)
on conflict (id) do nothing;

insert into public.catalogo_sinonimos(termos)
select array(select jsonb_array_elements_text(e)) from jsonb_array_elements($j$[["cadeira flexora","mesa flexora","flexora","leg curl"],["cadeira extensora","extensora","leg extension"],["leg press","leg 45","pressao de pernas"],["stiff","terra romeno","romanian"],["panturrilha","gemeos","calf"],["abdominal","crunch","abdomen"],["voador","peck deck","peitoral na maquina"],["puxada","pulley","puxador","lat pulldown"],["remada","row"],["rosca","biceps curl"],["triceps","pushdown"],["agachamento","squat"],["supino","bench press"],["elevacao pelvica","hip thrust","ponte de gluteo","glute bridge"],["abdutora","abducao"],["adutora","aducao"],["afundo","avanco","lunge"]]$j$::jsonb) e
where not exists (select 1 from public.catalogo_sinonimos);

-- Revisão do catálogo (v162)
create or replace function public.catalogo_candidatos() returns jsonb language sql stable security definer set search_path=public as $$
  with s as (
    select cat_norm(nome) n, min(nome) nome, count(*)::int qtd, count(distinct user_id)::int usuarios
    from exercise_suggestions group by 1),
  fora as (
    select s.* from s
    where s.n <> ''
      and not exists (select 1 from catalogo_exercicios e where cat_norm(e.nome) = s.n)
      and not exists (select 1 from catalogo_aliases a where a.alias_norm = s.n)
      and not exists (select 1 from exercise_review r where r.nome_norm = s.n and r.status = 'pendente')
      and not exists (select 1 from exercise_review r where r.nome_norm = s.n and r.status in ('aprovado','reprovado')
                      and (r.status = 'aprovado' or s.qtd < greatest(2, coalesce(r.qtd_na_decisao,1) * 2))))
  select jsonb_build_object(
    'candidatos', coalesce((select jsonb_agg(jsonb_build_object('nome_norm',n,'nome',nome,'qtd',qtd,'usuarios',usuarios) order by qtd desc) from fora),'[]'::jsonb),
    'comentarios', coalesce((select jsonb_agg(jsonb_build_object('nome',nome,'acao',acao,'comentario',comentario_admin) order by decidido_em desc) from (select * from exercise_review where status='reprovado' and comentario_admin is not null and comentario_admin <> '' order by decidido_em desc limit 20) c),'[]'::jsonb))
$$;
revoke all on function public.catalogo_candidatos() from public, anon, authenticated;

create or replace function public.admin_revisao_lista() returns jsonb language plpgsql stable security definer set search_path=public as $$
begin
  if not public.is_movo_admin() then raise exception 'forbidden'; end if;
  return jsonb_build_object(
    'pendentes', coalesce((select jsonb_agg(to_jsonb(r) order by r.qtd desc, r.created_at) from exercise_review r where r.status='pendente'),'[]'::jsonb),
    'decididos', coalesce((select jsonb_agg(to_jsonb(r) order by r.decidido_em desc) from (select * from exercise_review where status<>'pendente' order by decidido_em desc limit 40) r),'[]'::jsonb),
    'sem_revisao', (select count(*)::int from (select cat_norm(nome) n from exercise_suggestions group by 1) s
       where s.n <> '' and not exists (select 1 from catalogo_exercicios e where cat_norm(e.nome)=s.n)
       and not exists (select 1 from catalogo_aliases a where a.alias_norm=s.n)
       and not exists (select 1 from exercise_review r where r.nome_norm=s.n)));
end $$;
grant execute on function public.admin_revisao_lista() to authenticated;

create or replace function public.admin_revisao_decidir(p_id bigint, p_decisao text, p_comentario text default null, p_proposta jsonb default null)
returns jsonb language plpgsql security definer set search_path=public as $$
declare r exercise_review; pr jsonb; ex_id text; g text; nome_ex text;
begin
  if not public.is_movo_admin() then raise exception 'forbidden'; end if;
  select * into r from exercise_review where id = p_id and status = 'pendente';
  if not found then raise exception 'revisao nao encontrada'; end if;
  if p_decisao = 'reprovar' then
    update exercise_review set status='reprovado', comentario_admin=left(p_comentario,500), qtd_na_decisao=qtd, decidido_em=now() where id=p_id;
    return jsonb_build_object('ok', true);
  end if;
  if p_decisao <> 'aprovar' then raise exception 'decisao invalida'; end if;
  pr := coalesce(p_proposta, r.proposta);
  if coalesce(pr->>'acao', r.acao) = 'alias' then
    ex_id := pr->>'exercicio_id';
    if not exists (select 1 from catalogo_exercicios where id = ex_id) then raise exception 'exercicio inexistente'; end if;
  else
    nome_ex := trim(pr->>'nome');
    if coalesce(nome_ex,'') = '' then raise exception 'nome obrigatorio'; end if;
    ex_id := trim(both '-' from regexp_replace(cat_norm(nome_ex), '[^a-z0-9]+', '-', 'g'));
    g := pr->>'grupo_key';
    if coalesce(pr->>'grupo_novo','') <> '' then
      g := trim(both '-' from regexp_replace(cat_norm(pr->>'grupo_novo'), '[^a-z0-9]+', '-', 'g'));
      insert into catalogo_grupos(key,label,kind,ordem) values (g, pr->>'grupo_novo', 'muscular', (select coalesce(max(ordem),0)+1 from catalogo_grupos)) on conflict (key) do nothing;
    end if;
    if not exists (select 1 from catalogo_grupos where key = g) then raise exception 'grupo invalido'; end if;
    insert into catalogo_exercicios(id,nome,grupo_key,series,repeticoes,descricao,observacoes,video_url,ordem)
    values (ex_id, nome_ex, g, coalesce((pr->>'series')::int,3), coalesce(nullif(pr->>'repeticoes',''),'10-12'),
            coalesce(pr->>'descricao',''), coalesce(pr->>'observacoes',''), coalesce(pr->>'video_url',''),
            (select coalesce(max(ordem),0)+1 from catalogo_exercicios))
    on conflict (id) do nothing;
  end if;
  insert into catalogo_aliases(alias_norm, alias_nome, exercicio_id) values (r.nome_norm, r.nome, ex_id)
  on conflict (alias_norm) do update set exercicio_id = excluded.exercicio_id, alias_nome = excluded.alias_nome;
  update exercise_review set status='aprovado', comentario_admin=left(p_comentario,500), proposta=pr, decidido_em=now() where id=p_id;
  return jsonb_build_object('ok', true, 'exercicio_id', ex_id);
end $$;
grant execute on function public.admin_revisao_decidir(bigint, text, text, jsonb) to authenticated;
revoke all on function public.admin_revisao_lista() from public, anon;
revoke all on function public.admin_revisao_decidir(bigint, text, text, jsonb) from public, anon;

create or replace function public.admin_revisao_reavaliar(p_id bigint) returns jsonb language plpgsql security definer set search_path=public as $$
begin
  if not public.is_movo_admin() then raise exception 'forbidden'; end if;
  -- solta o nome da trava: a próxima revisão volta a considerar esse exercício
  update exercise_review set nome_norm = nome_norm || '#' || id where id = p_id and status = 'reprovado';
  return jsonb_build_object('ok', true);
end $$;
grant execute on function public.admin_revisao_reavaliar(bigint) to authenticated;
revoke all on function public.admin_revisao_reavaliar(bigint) from public, anon;
