// Bump this on every deploy that ships a user-visible change: MAJOR.MINOR.PATCH.
// - PATCH (1.0.0 -> 1.0.1): bug fixes, tweaks.
// - MINOR (1.0.1 -> 1.1.0): new features.
// - MAJOR (1.x -> 2.0.0): big overhauls / breaking changes to how the app works.
// Keep this in sync with CACHE_NAME in ../sw.js — both must change together so
// the "Actualizar" banner fires and the version shown in Ajustes / el pie de
// página always matches what's actually running.
export const APP_VERSION = '1.0.1';
