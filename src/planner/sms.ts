import { SmsStatus } from '../types';

// Gedeelde presentatie van de SMS-status (chip + dagweergave), zodat beide
// schermen dezelfde woorden en kleuren gebruiken.
export const SMS_LABELS: Record<SmsStatus, string> = {
  sent:    'Herinnering verstuurd',
  failed:  'Herinnering mislukt',
  sending: 'Vastgelopen — geclaimd, nooit bevestigd; er gaat geen bericht meer uit',
};

export const SMS_ICON_CLASS: Record<SmsStatus, string> = {
  sent:    'text-green-600',
  failed:  'text-red-600',
  sending: 'text-amber-500',
};

// 'YYYY-MM-DDTHH:MM:SS+00' → '12-08 18:03' in lokale tijd.
export function formatSentAt(iso: string | null): string {
  if (!iso) return '';
  const d = new Date(iso);
  const p = (n: number) => String(n).padStart(2, '0');
  return `${p(d.getDate())}-${p(d.getMonth() + 1)} ${p(d.getHours())}:${p(d.getMinutes())}`;
}
