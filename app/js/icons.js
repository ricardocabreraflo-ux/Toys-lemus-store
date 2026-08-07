export const ICONS = {
  doll: '<circle cx="12" cy="7.5" r="4" stroke-width="1.8"/><path d="M8 6.2c0-2 1.6-3.4 2.6-3.4M16 6.2c0-2-1.6-3.4-2.6-3.4" stroke-width="1.8" stroke-linecap="round"/><path d="M7 21v-4.6c0-1 .4-2 1.1-2.7l1.4-1.4M17 21v-4.6c0-1-.4-2-1.1-2.7l-1.4-1.4" stroke-width="1.8" stroke-linecap="round"/><path d="M9.5 12.3h5" stroke-width="1.8" stroke-linecap="round"/>',
  shield: '<path d="M12 3l7 3v5.2c0 4.6-3 7.8-7 9.8-4-2-7-5.2-7-9.8V6l7-3z" stroke-width="1.8" stroke-linejoin="round"/><path d="M9 12l2 2 4-4" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"/>',
  car: '<path d="M4 16V12l2-4h6.5l3 4H20v4" stroke-width="1.8" stroke-linejoin="round"/><path d="M4 16h16" stroke-width="1.8"/><circle cx="8" cy="16.5" r="1.8" stroke-width="1.8"/><circle cx="17" cy="16.5" r="1.8" stroke-width="1.8"/><path d="M10.5 8v4" stroke-width="1.8"/>',
  dice: '<rect x="4" y="4" width="16" height="16" rx="4" stroke-width="1.8"/><circle cx="8.3" cy="8.3" r="1.15" fill="currentColor" stroke="none"/><circle cx="15.7" cy="8.3" r="1.15" fill="currentColor" stroke="none"/><circle cx="12" cy="12" r="1.15" fill="currentColor" stroke="none"/><circle cx="8.3" cy="15.7" r="1.15" fill="currentColor" stroke="none"/><circle cx="15.7" cy="15.7" r="1.15" fill="currentColor" stroke="none"/>',
  blaster: '<path d="M3 13.5l8-2.2 8-3.3 2 2-3.2 2.7-2.8 6.8-3.3-1.2-1-2.6-2.9-.9z" stroke-width="1.8" stroke-linejoin="round"/><circle cx="17.5" cy="6.5" r="1.6" stroke-width="1.8"/>',
  blob: '<path d="M12 3c3 0 5 2.4 5.6 5 .5 2-.2 3.3.9 4.7 1.4 1.8.6 4.3-1.7 5.3-2.7 1.2-4.9-.4-7-.4-2.5 0-5 1-6.7-1-1.5-1.8-.9-4 .2-5.6C4.3 9 4.4 6.8 6 5.2 7.5 3.7 9.7 3 12 3z" stroke-width="1.8" stroke-linejoin="round"/><circle cx="12" cy="12.5" r="1.6" fill="currentColor" stroke="none"/>',
};

export function iconSvg(key, extra) {
  return '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-linecap="round" ' + (extra || '') + '>' + (ICONS[key] || ICONS.doll) + '</svg>';
}
