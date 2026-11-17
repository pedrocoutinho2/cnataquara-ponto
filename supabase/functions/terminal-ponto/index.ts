// =====================================================================
// POST /terminal-ponto
//
// Registro de ponto sem senha: o token do terminal autentica o aparelho, a
// identificacao 1:N no servidor diz quem e a pessoa. O descritor nunca
// decide nada no navegador, porque cliente e territorio do adversario.
//
// REGRA DE OURO, igual a da /registrar-ponto: esta funcao NUNCA recusa uma
// marcacao por rosto, rede ou localizacao. A Portaria 671/2021 probe o REP
// de restringir a marcacao do trabalhador. Quando o rosto nao bate, a
// resposta nao e "negado", e a lista da equipe para a pessoa se declarar. A
// marcacao entra igual, marcada para revisao e com evidencia guardada.
//
// v2 (2026-11-16, multi-unidade): a identificacao compara so com quem e do
// REP do terminal (identificar_face_rep), e quem se declara na lista precisa
// ser do mesmo REP. Um terminal de uma unidade nunca grava ponto de outra.
// =====================================================================

import { createClient } from "npm:@supabase/supabase-js@2";

// Similaridade minima do rosto, mesma calibragem da /registrar-ponto: o
// titular fica em 0,95+ e um terceiro abaixo de 0,90.
const LIMIAR_FACE = 0.92;
// Distancia minima para o segundo colocado. Sem isto, dois rostos parecidos
// acima do limiar sao decididos por ruido de iluminacao.
const LIMIAR_MARGEM = 0.05;
const LIMIAR_LIVENESS = 0.70;

const ORIGEM = Deno.env.get("ORIGEM_PWA") ?? "https://ponto.cnataquara.com.br";
const cors = {
  "Access-Control-Allow-Origin": ORIGEM,
  "Access-Control-Allow-Headers": "authorization, content-type, apikey, x-terminal-token",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

async function sha256hex(txt: string): Promise<string> {
  const buf = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(txt));
  return [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

function ipDaRequisicao(req: Request): string | null {
  const xff = req.headers.get("x-forwarded-for");
  return xff ? xff.split(",")[0].trim() : req.headers.get("cf-connecting-ip");
}

interface Trace { t: number; yaw: number; ear: number; area: number }

function traceCoerente(t: Trace[], acoes: string[]): boolean {
  if (t.length < 10) return false;
  const dur = t[t.length - 1].t - t[0].t;
  if (dur < 1200 || dur > 40000) return false;
  const yaw = t.map((p) => p.yaw);
  const amplitudeYaw = Math.max(...yaw) - Math.min(...yaw);
  if (acoes.some((a) => a.startsWith("virar")) && amplitudeYaw < 12) return false;
  const distintos = new Set(t.map((p) => `${p.yaw.toFixed(1)}|${p.ear.toFixed(3)}`));
  return distintos.size >= t.length * 0.6;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: cors });

  const admin = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    { auth: { persistSession: false } },
  );

  // ---- 1. O aparelho -------------------------------------------------
  const token = req.headers.get("x-terminal-token");
  const { data: terminal } = token
    ? await admin.schema("ponto").from("terminais")
        .select("id, rep_id, nome, ativo, revogado_em")
        .eq("token_hash", await sha256hex(token)).maybeSingle()
    : { data: null };

  if (!terminal?.ativo || terminal.revogado_em) {
    return Response.json(
      { erro: "Este aparelho não está autorizado a registrar ponto. Procure a coordenação." },
      { status: 403, headers: cors },
    );
  }

  const corpo = await req.json();
  const agora = new Date();
  const ip = ipDaRequisicao(req);

  // ---- 2. Vivacidade -------------------------------------------------
  let liveness_ok = false;
  let desafio_id: string | null = null;

  const { data: desafio } = await admin.schema("ponto").from("liveness_desafios")
    .select("id, acoes, expira_em, consumido_em, terminal_id")
    .eq("id", corpo.desafio_id).eq("nonce", corpo.nonce).maybeSingle();

  if (desafio && desafio.terminal_id === terminal.id && !desafio.consumido_em &&
      new Date(desafio.expira_em) > agora) {
    desafio_id = desafio.id;
    liveness_ok =
      JSON.stringify(desafio.acoes) === JSON.stringify(corpo.liveness?.acoes_cumpridas) &&
      (corpo.liveness?.confianca ?? 0) >= LIMIAR_LIVENESS &&
      traceCoerente(corpo.liveness?.trace ?? [], desafio.acoes);
    // o nonce queima na primeira tentativa, passe ou nao
    await admin.schema("ponto").from("liveness_desafios")
      .update({ consumido_em: agora.toISOString() }).eq("id", desafio.id);
  }

  // ---- 3. Quem e --------------------------------------------------
  let empregado_id: string | null = null;
  let face_similaridade = 0;
  let margem = 0;
  let face_ok = false;
  let declarado = false;

  if (Array.isArray(corpo.descritor_facial) && corpo.descritor_facial.length === 128) {
    const { data } = await admin.schema("ponto").rpc("identificar_face_rep", {
      p_descritor: `[${corpo.descritor_facial.join(",")}]`,
      p_rep_id: terminal.rep_id,
    });
    const achado = Array.isArray(data) ? data[0] : data;
    if (achado) {
      face_similaridade = Number(achado.similaridade ?? 0);
      margem = Number(achado.margem ?? 0);
      face_ok = face_similaridade >= LIMIAR_FACE && margem >= LIMIAR_MARGEM;
      if (face_ok) empregado_id = achado.empregado_id;
    }
  }

  // Nao reconheceu: a pessoa se declara e a marcacao entra pendente. Este e
  // o caminho que um impostor tentaria, entao ele sempre guarda evidencia e
  // sempre cai na fila da coordenacao, nunca em "nao_requer".
  if (!empregado_id && corpo.empregado_declarado) {
    empregado_id = corpo.empregado_declarado;
    declarado = true;
  }

  const listaDaEquipe = async () => {
    const { data: equipe } = await admin.schema("ponto").from("empregados")
      .select("id, nome").eq("rep_id", terminal.rep_id).eq("ativo", true).order("nome");
    return Response.json(
      {
        nao_reconhecido: true,
        equipe: equipe ?? [],
        recado: "Não reconheci o rosto. Escolha seu nome na lista: o ponto é registrado "
          + "do mesmo jeito e a coordenação confere depois.",
      },
      { status: 200, headers: cors },
    );
  };

  if (!empregado_id) return await listaDaEquipe();

  const { data: emp } = await admin.schema("ponto").from("empregados")
    .select("id, nome, cpf, rep_id, ativo").eq("id", empregado_id).maybeSingle();

  // Quem se declarou precisa ser da unidade do aparelho. Se nao for, volta a
  // lista certa em vez de gravar ponto na unidade errada.
  if (emp && emp.rep_id !== terminal.rep_id) return await listaDaEquipe();

  if (!emp?.ativo) {
    return Response.json(
      { erro: "Cadastro inativo. Procure a coordenação." },
      { status: 403, headers: cors },
    );
  }

  // ---- 4. Cerca e rede ------------------------------------------------
  const { data: cercas } = await admin.schema("ponto").from("cercas")
    .select("id, latitude, longitude, raio_m, acuracia_maxima_m, ips")
    .eq("rep_id", emp.rep_id).eq("ativa", true);

  let dentro_cerca = false, ip_autorizado = false;
  let distancia: number | null = null;
  let cerca_id: string | null = null;

  for (const c of cercas ?? []) {
    if (ip) {
      const { data: bate } = await admin.rpc("ip_em_faixas", { p_ip: ip, p_faixas: c.ips });
      if (bate) { ip_autorizado = true; cerca_id = c.id; }
    }
    if (corpo.geo && corpo.geo.acuracia_m <= c.acuracia_maxima_m) {
      const { data: d } = await admin.schema("ponto").rpc("distancia_m", {
        lat1: corpo.geo.latitude, lon1: corpo.geo.longitude,
        lat2: c.latitude, lon2: c.longitude,
      });
      const dist = Number(d);
      if (distancia === null || dist < distancia) { distancia = dist; cerca_id ??= c.id; }
      if (dist <= c.raio_m) { dentro_cerca = true; cerca_id = c.id; }
    }
  }

  // ---- 5. GRAVA (sempre) ----------------------------------------------
  const { data: registro, error: erroArp } = await admin.schema("ponto").from("arp")
    .insert({
      rep_id: emp.rep_id,
      tipo: "7",
      empregado_id: emp.id,
      cpf: emp.cpf,
      dh_marcacao: agora.toISOString(),   // hora do servidor, nunca do aparelho
      coletor: "browser",
      offline: false,
    })
    .select("id, nsr, hash, dh_marcacao").single();

  if (erroArp) {
    return Response.json(
      { erro: "A marcação não foi gravada. Tente de novo e avise a coordenação." },
      { status: 500, headers: cors },
    );
  }

  // ---- 6. Contexto e classificacao ------------------------------------
  // Sem passkey neste fluxo: o aparelho e compartilhado, entao o sinal que
  // sobraria seria do celular da escola, nao da pessoa. Ficam de pe rosto,
  // vivacidade e presenca. Declaracao manual nunca passa como confirmada.
  const essenciais = face_ok && liveness_ok && !declarado && (dentro_cerca || ip_autorizado);
  const sinais = [dentro_cerca || ip_autorizado, face_ok, liveness_ok].filter(Boolean).length;

  let evidencia: string | null = null;
  if (corpo.evidencia_b64 && !essenciais) {
    const caminho = `${emp.rep_id}/${registro.nsr}.jpg`;
    try {
      const bytes = Uint8Array.from(atob(corpo.evidencia_b64), (c) => c.charCodeAt(0));
      const { error } = await admin.storage.from("liveness").upload(caminho, bytes, {
        contentType: "image/jpeg", upsert: false,
      });
      if (!error) evidencia = caminho;
    } catch { /* bucket ausente nunca pode impedir a marcacao */ }
  }

  await admin.schema("ponto").from("marcacao_contexto").insert({
    arp_id: registro.id,
    rep_id: emp.rep_id,
    empregado_id: emp.id,
    latitude: corpo.geo?.latitude ?? null,
    longitude: corpo.geo?.longitude ?? null,
    acuracia_m: corpo.geo?.acuracia_m ?? null,
    distancia_cerca_m: distancia,
    dentro_cerca,
    cerca_id,
    ip,
    ip_autorizado,
    dispositivo_id: null,
    webauthn_ok: false,
    face_similaridade,
    face_ok,
    liveness_desafio_id: desafio_id,
    liveness_ok,
    liveness_evidencia: evidencia,
    sinais_ok: sinais,
    revisao: essenciais ? "nao_requer" : "pendente",
    observacao: declarado
      ? `Identidade declarada no terminal ${terminal.nome}, rosto não reconhecido `
        + `(similaridade ${face_similaridade.toFixed(3)}, margem ${margem.toFixed(3)}).`
      : `Identificado por rosto no terminal ${terminal.nome} `
        + `(similaridade ${face_similaridade.toFixed(3)}, margem ${margem.toFixed(3)}).`,
    user_agent: req.headers.get("user-agent"),
  });

  await admin.schema("ponto").from("terminais")
    .update({ ultimo_uso_em: agora.toISOString() }).eq("id", terminal.id);

  return Response.json(
    {
      nsr: registro.nsr,
      hash: registro.hash,
      marcado_em: registro.dh_marcacao,
      nome: emp.nome,
      cpf: emp.cpf,
      sinais_ok: sinais,
      declarado,
      em_revisao: !essenciais,
    },
    { headers: cors },
  );
});
