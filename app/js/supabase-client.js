// Loaded from the vendored UMD bundle (js/vendor/supabase.umd.js), which
// must be included via a <script> tag before this module runs.
import { SUPABASE_URL, SUPABASE_ANON_KEY } from './config.js';

const { createClient } = window.supabase;
export const supabase = createClient(SUPABASE_URL, SUPABASE_ANON_KEY);

export const CATEGORIES = {
  munecas: { label: 'Muñecas y Princesas', color: 'var(--accent-4)', icon: 'doll' },
  accion: { label: 'Acción y Superhéroes', color: 'var(--accent-5)', icon: 'shield' },
  vehiculos: { label: 'Vehículos y Pistas', color: 'var(--accent-6)', icon: 'car' },
  juegosmesa: { label: 'Juegos de Mesa', color: 'var(--accent-2)', icon: 'dice' },
  nerf: { label: 'Nerf y Aire Libre', color: 'var(--accent-3)', icon: 'blaster' },
  creativos: { label: 'Creativos y Sensorial', color: 'var(--accent-7)', icon: 'blob' },
};

export const fmt = new Intl.NumberFormat('es-MX', { style: 'currency', currency: 'MXN' });
