// Every "today" / "this week" / "this month" boundary, and every
// timestamp shown to someone, must be anchored to the store's own
// timezone (Mexico City) — never to whatever timezone a vendedor's
// phone happens to be set to. Mexico stopped observing daylight saving
// time in most of the country (CDMX included) in 2022, but we still go
// through Intl/IANA instead of hardcoding a fixed UTC-6 offset, so this
// keeps working correctly if that ever changes again.
export const STORE_TIMEZONE = 'America/Mexico_City';

const partsFormatter = new Intl.DateTimeFormat('en-US', {
  timeZone: STORE_TIMEZONE,
  hourCycle: 'h23',
  year: 'numeric', month: '2-digit', day: '2-digit',
  hour: '2-digit', minute: '2-digit', second: '2-digit',
});

function storeParts(date) {
  const parts = Object.fromEntries(partsFormatter.formatToParts(date).map(p => [p.type, p.value]));
  return {
    year: Number(parts.year), month: Number(parts.month), day: Number(parts.day),
    hour: Number(parts.hour), minute: Number(parts.minute), second: Number(parts.second),
  };
}

// Converts a store-local wall-clock date/time into the real UTC instant it
// corresponds to — correctly accounts for Mexico City's offset without
// hardcoding it.
export function storeDateTimeToUtc(year, month, day, hour = 0, minute = 0, second = 0) {
  const utcGuess = Date.UTC(year, month - 1, day, hour, minute, second);
  const p = storeParts(new Date(utcGuess));
  const asUtcIfStoreTzWereUtc = Date.UTC(p.year, p.month - 1, p.day, p.hour, p.minute, p.second);
  const offsetMs = asUtcIfStoreTzWereUtc - utcGuess;
  return new Date(utcGuess - offsetMs);
}

// 'YYYY-MM-DD' calendar date in the store's timezone for a given instant —
// the key to use whenever two timestamps need to be compared for
// same-day-in-the-store equality (e.g. "sold today").
export function storeDateKey(date = new Date()) {
  const p = storeParts(date);
  return `${p.year}-${String(p.month).padStart(2, '0')}-${String(p.day).padStart(2, '0')}`;
}

// Start of "today" (00:00:00 store time) as a real UTC instant — the
// boundary to use in Supabase .gte('created_at', ...) queries.
export function storeStartOfDayUtc(date = new Date()) {
  const p = storeParts(date);
  return storeDateTimeToUtc(p.year, p.month, p.day);
}

// Start of the week (Monday 00:00 store time) containing `date`, as a real
// UTC instant.
export function storeStartOfWeekUtc(date = new Date()) {
  const p = storeParts(date);
  // Weekday of the store-local calendar date, computed without involving
  // the browser's own timezone.
  const wallClockDay = new Date(Date.UTC(p.year, p.month - 1, p.day)).getUTCDay(); // 0=domingo..6=sábado
  const diff = wallClockDay === 0 ? -6 : 1 - wallClockDay;
  const monday = new Date(Date.UTC(p.year, p.month - 1, p.day + diff));
  return storeDateTimeToUtc(monday.getUTCFullYear(), monday.getUTCMonth() + 1, monday.getUTCDate());
}

// Start of the current month (1st, 00:00 store time) as a real UTC instant.
export function storeStartOfMonthUtc(date = new Date()) {
  const p = storeParts(date);
  return storeDateTimeToUtc(p.year, p.month, 1);
}

// A date-only value (like a `due_date` column, which carries no time or
// timezone of its own) represented as UTC midnight — the only safe,
// zoneless way to store/compare a bare calendar date in a JS Date without
// its displayed day shifting depending on the device's own timezone.
// Always format/compare these with timeZone: 'UTC', never the device's
// local zone or STORE_TIMEZONE.
export function dateOnlyToUtcMidnight(dateStr) {
  const [y, m, d] = String(dateStr).split('-').map(Number);
  return new Date(Date.UTC(y, m - 1, d));
}

// Today's calendar date in the store's timezone, as the same UTC-midnight
// shape as dateOnlyToUtcMidnight — safe to compare against it directly
// (e.g. for "is this layaway due today / overdue").
export function storeTodayAsUtcMidnight(date = new Date()) {
  const p = storeParts(date);
  return new Date(Date.UTC(p.year, p.month - 1, p.day));
}

// Converts a plain 'YYYY-MM-DD' input (e.g. from a <input type="date">
// range filter) into the real UTC instant for the start or end of that
// calendar day in the store's timezone.
export function storeDayRangeUtc(dateStr) {
  const [y, m, d] = String(dateStr).split('-').map(Number);
  const startUtc = storeDateTimeToUtc(y, m, d, 0, 0, 0);
  const nextDayStartUtc = storeDateTimeToUtc(y, m, d + 1, 0, 0, 0);
  return { startUtc, endUtc: new Date(nextDayStartUtc.getTime() - 1) };
}
