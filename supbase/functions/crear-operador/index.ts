// Edge Function: crear-operador
// Crea un usuario operador (solo puede llamarla un operador admin activo).
import { createClient } from 'npm:@supabase/supabase-js@2';

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json' } });

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  if (req.method !== 'POST') return json({ error: 'Método no permitido' }, 405);

  try {
    const url = Deno.env.get('SUPABASE_URL')!;
    const service = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
    const admin = createClient(url, service, { auth: { persistSession: false, autoRefreshToken: false } });

    // 1. ¿Quién llama?
    const token = (req.headers.get('Authorization') || '').replace(/^Bearer\s+/i, '');
    if (!token) return json({ error: 'No autenticado' }, 401);
    const { data: who, error: eWho } = await admin.auth.getUser(token);
    if (eWho || !who?.user) return json({ error: 'Sesión inválida. Volvé a ingresar.' }, 401);

    // 2. ¿Es admin activo?
    const { data: op } = await admin.from('operadores').select('rol, activo').eq('id', who.user.id).maybeSingle();
    if (!op || !op.activo || op.rol !== 'admin') return json({ error: 'Solo un admin puede crear operadores.' }, 403);

    // 3. Datos
    const body = await req.json().catch(() => ({}));
    const email = String(body.email || '').trim().toLowerCase();
    const nombre = String(body.nombre || '').trim();
    const rol = body.rol === 'admin' ? 'admin' : 'operador';
    const password = String(body.password || '');
    if (!nombre) return json({ error: 'Falta el nombre.' }, 400);
    if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) return json({ error: 'El email no es válido.' }, 400);
    if (password.length < 8) return json({ error: 'La contraseña temporal es muy corta.' }, 400);

    // 4. Crear usuario (confirmado, sin mail)
    const { data: cu, error: eCu } = await admin.auth.admin.createUser({
      email, password, email_confirm: true, user_metadata: { tipo: 'operador', nombre },
    });
    if (eCu || !cu?.user) {
      const m = eCu?.message || 'No se pudo crear el usuario.';
      return json({ error: /already|registered|exists/i.test(m) ? 'Ya existe un usuario con ese email.' : m }, 400);
    }

    // 5. Alta en operadores
    const { error: eIns } = await admin.from('operadores').insert({ id: cu.user.id, nombre, rol, email });
    if (eIns) {
      await admin.auth.admin.deleteUser(cu.user.id);
      return json({ error: eIns.message }, 400);
    }

    return json({ ok: true, id: cu.user.id });
  } catch (e) {
    return json({ error: String((e as Error)?.message || e) }, 500);
  }
});
