import { ShiftType, TransportMode } from '../types';

// Vier onderscheidbare kleuren per diensttype (met legenda in het overzicht).
export interface TypeStyle {
  label: string;
  bg: string;
  border: string;
  text: string;
  swatch: string; // volle kleur voor de legenda
}

export const TYPE_STYLES: Record<ShiftType, TypeStyle> = {
  regular: {
    label: 'Regulier',
    bg: 'bg-blue-100', border: 'border-blue-400', text: 'text-blue-800', swatch: 'bg-blue-500',
  },
  institution: {
    label: 'Instelling',
    bg: 'bg-purple-100', border: 'border-purple-500', text: 'text-purple-800', swatch: 'bg-purple-500',
  },
  other_transport: {
    label: 'Overig transport',
    bg: 'bg-amber-100', border: 'border-amber-500', text: 'text-amber-800', swatch: 'bg-amber-500',
  },
  urgent: {
    label: 'Spoed',
    bg: 'bg-red-100', border: 'border-red-500', text: 'text-red-800', swatch: 'bg-red-500',
  },
};

export const SHIFT_TYPES: ShiftType[] = ['regular', 'institution', 'other_transport', 'urgent'];

export const TRANSPORT_LABELS: Record<TransportMode, string> = {
  bike: 'Fiets',
  car: 'Auto',
};

export const WEEKDAY_LABELS = ['Ma', 'Di', 'Wo', 'Do', 'Vr', 'Za', 'Zo'];
export const WEEKDAY_LABELS_LONG = [
  'Maandag', 'Dinsdag', 'Woensdag', 'Donderdag', 'Vrijdag', 'Zaterdag', 'Zondag',
];
